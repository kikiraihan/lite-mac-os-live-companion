package app

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Saluran real-time ke aplikasi Mac: GET /api/app/ws (WebSocket, token perangkat di header Authorization).
// Server hanya mendorong kabar; aplikasi tetap mengirim lewat HTTP biasa. Bentuk kabar (JSON):
//
//	{"type":"hello",   "unread":[{"friend_id":…,"friend_name":…,"count":3}]}   saat tersambung
//	{"type":"message", "friend_id":…, "friend_name":…, "message":{…}}   pesan baru (masuk / dari Mac lain milik sendiri)
//	{"type":"read",    "friend_id":…}                                   percakapan sudah dibaca (di Mac mana pun)
//	{"type":"nudge"}                                                    ada sapaan → aplikasi sinkron sekarang
//	{"type":"presence","friend_id":…, "online":true}                    teman membuka / menutup Temu di Mac-nya
//
// "hello" juga membawa "online_friends": [id teman yang sedang online]. Online = minimal satu Mac milik
// akun itu tersambung ke saluran ini (web tidak dihitung) dan pemiliknya tidak menyembunyikan statusnya
// (users.hide_presence, diatur di web › Akun atau Pengaturan aplikasi Mac). Kabar offline ditunda liveGrace supaya Mac yang
// hanya menyambung ulang (bangun dari tidur, ganti Wi-Fi) tidak membuat statusnya berkedip.
//
// Hub disimpan di memori: cukup untuk satu proses server (seperti deploy saat ini).

const (
	livePing     = 25 * time.Second
	liveRecheck  = 5 * time.Minute // token / akun dicek ulang secara berkala
	livePerUser  = 20
	liveSendSize = 32
	liveGrace    = 20 * time.Second // jeda sebelum teman diberi kabar "offline"
)

type liveConn struct {
	user, device string
	send         chan []byte
	done         chan struct{}
	once         sync.Once
}

func (c *liveConn) close() { c.once.Do(func() { close(c.done) }) }

type hub struct {
	mu    sync.Mutex
	users map[string]map[*liveConn]struct{}
	grace time.Duration // = liveGrace; tes memperpendeknya
}

func newHub() *hub { return &hub{users: map[string]map[*liveConn]struct{}{}, grace: liveGrace} }

// add mendaftarkan koneksi; first = ini Mac pertama user yang tersambung (baru saja online)
func (h *hub) add(c *liveConn) (ok, first bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	set := h.users[c.user]
	if len(set) >= livePerUser {
		return false, false
	}
	if set == nil {
		set = map[*liveConn]struct{}{}
		h.users[c.user] = set
		first = true
	}
	set[c] = struct{}{}
	return true, first
}

// remove melepas koneksi; last = tidak ada lagi Mac user yang tersambung
func (h *hub) remove(c *liveConn) (last bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if set := h.users[c.user]; set != nil {
		delete(set, c)
		if len(set) == 0 {
			delete(h.users, c.user)
			return true
		}
	}
	return false
}

// online: apakah minimal satu Mac milik user sedang tersambung
func (h *hub) online(user string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.users[user]) > 0
}

// publish mengirim kabar ke semua Mac milik user. Koneksi yang antreannya penuh diputus
// (aplikasi menyambung ulang lalu mengambil data terbaru).
func (h *hub) publish(user string, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.users[user] {
		select {
		case c.send <- b:
		default:
			c.close()
		}
	}
}

// dropDevice / dropUser: putuskan saluran saat token dicabut atau akun dinonaktifkan.
func (h *hub) dropDevice(device string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, set := range h.users {
		for c := range set {
			if c.device == device {
				c.close()
			}
		}
	}
}

func (h *hub) dropUser(user string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.users[user] {
		c.close()
	}
}

// friendRef: satu teman aktif + apakah ia menyembunyikan status online-nya
type friendRef struct {
	id     string
	hidden bool
}

// friends: semua teman aktif milik user (untuk kabar kehadiran)
func (s *Server) friends(ctx context.Context, user string) ([]friendRef, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT u.id, u.hide_presence FROM friendships f
		JOIN users u ON u.id = CASE WHEN f.user_a=$1 THEN f.user_b ELSE f.user_a END
		WHERE (f.user_a=$1 OR f.user_b=$1) AND u.disabled_at IS NULL`, user)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []friendRef
	for rows.Next() {
		var f friendRef
		if err := rows.Scan(&f.id, &f.hidden); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// seenOnline: status online user seperti yang boleh dilihat temannya
func (s *Server) seenOnline(user string, hidden bool) bool { return !hidden && s.live.online(user) }

// announcePresence memberi tahu Mac teman-teman bahwa user online / offline.
// Hanya teman yang menerima kabar ini (sama seperti pet dan pesan). Status yang disembunyikan tidak
// diumumkan (teman tetap melihatnya offline).
func (s *Server) announcePresence(user string, online bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var hidden bool
	if err := s.DB.QueryRowContext(ctx, `SELECT hide_presence FROM users WHERE id=$1`, user).Scan(&hidden); err != nil || hidden {
		return
	}
	s.broadcastPresence(ctx, user, online)
}

// broadcastPresence mengirim kabar online / offline user ke semua Mac temannya (tanpa memeriksa hide_presence)
func (s *Server) broadcastPresence(ctx context.Context, user string, online bool) {
	fs, err := s.friends(ctx, user)
	if err != nil {
		log.Printf("live: presence %v", err)
		return
	}
	for _, f := range fs {
		s.live.publish(f.id, map[string]any{"type": "presence", "friend_id": user, "online": online})
	}
}

// setHidePresence menyimpan pilihan "sembunyikan status online-ku" dan langsung memberi tahu teman
// kalau statusnya yang terlihat berubah (sedang online → tampak offline, atau sebaliknya).
func (s *Server) setHidePresence(ctx context.Context, user string, hide bool) error {
	var was bool
	err := s.DB.QueryRowContext(ctx, `UPDATE users u SET hide_presence=$2 FROM users old
		WHERE u.id=$1 AND old.id=u.id RETURNING old.hide_presence`, user, hide).Scan(&was)
	if err != nil {
		return err
	}
	if was != hide && s.live.online(user) {
		go func() {
			bctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			s.broadcastPresence(bctx, user, !hide)
		}()
	}
	return nil
}

func (s *Server) appLive(w http.ResponseWriter, r *http.Request) error {
	p := who(r)
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		return nil // Accept sudah menulis respons galat
	}
	ws.SetReadLimit(1 << 10) // aplikasi tidak mengirim apa-apa lewat saluran ini
	lc := &liveConn{user: p.UserID, device: p.DeviceID, send: make(chan []byte, liveSendSize), done: make(chan struct{})}
	ok, first := s.live.add(lc)
	if !ok {
		ws.Close(websocket.StatusTryAgainLater, "terlalu banyak koneksi")
		return nil
	}
	if first {
		go s.announcePresence(p.UserID, true)
	}
	defer func() {
		if !s.live.remove(lc) {
			return
		}
		// tunggu sebentar: kalau Mac-nya hanya menyambung ulang, teman tidak perlu tahu
		user := p.UserID
		time.AfterFunc(s.live.grace, func() {
			if !s.live.online(user) {
				s.announcePresence(user, false)
			}
		})
	}()
	ctx := ws.CloseRead(r.Context())

	write := func(b []byte) bool {
		wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		return ws.Write(wctx, websocket.MessageText, b) == nil
	}
	unread, err := s.unreadCounts(ctx, p.UserID)
	if err != nil {
		log.Printf("live: unread %v", err)
		unread = []map[string]any{}
	}
	onlineFriends := []string{}
	if fs, err := s.friends(ctx, p.UserID); err != nil {
		log.Printf("live: teman %v", err)
	} else {
		for _, f := range fs {
			if s.seenOnline(f.id, f.hidden) {
				onlineFriends = append(onlineFriends, f.id)
			}
		}
	}
	hello, _ := json.Marshal(map[string]any{"type": "hello", "unread": unread, "online_friends": onlineFriends})
	if !write(hello) {
		return nil
	}

	ping := time.NewTicker(livePing)
	defer ping.Stop()
	recheck := time.NewTicker(liveRecheck)
	defer recheck.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-lc.done:
			ws.Close(websocket.StatusPolicyViolation, "sambungan ditutup server")
			return nil
		case b := <-lc.send:
			if !write(b) {
				return nil
			}
		case <-ping.C:
			pctx, cancel := context.WithTimeout(ctx, 15*time.Second)
			err := ws.Ping(pctx)
			cancel()
			if err != nil {
				return nil
			}
		case <-recheck.C:
			var ok bool
			s.DB.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM devices d JOIN users u ON u.id=d.user_id
				WHERE d.id=$1 AND u.disabled_at IS NULL)`, p.DeviceID).Scan(&ok)
			if !ok {
				ws.Close(websocket.StatusPolicyViolation, "token tidak berlaku")
				return nil
			}
		}
	}
}
