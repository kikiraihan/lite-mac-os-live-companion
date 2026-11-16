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
//
// Hub disimpan di memori: cukup untuk satu proses server (seperti deploy saat ini).

const (
	livePing     = 25 * time.Second
	liveRecheck  = 5 * time.Minute // token / akun dicek ulang secara berkala
	livePerUser  = 20
	liveSendSize = 32
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
}

func newHub() *hub { return &hub{users: map[string]map[*liveConn]struct{}{}} }

func (h *hub) add(c *liveConn) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	set := h.users[c.user]
	if len(set) >= livePerUser {
		return false
	}
	if set == nil {
		set = map[*liveConn]struct{}{}
		h.users[c.user] = set
	}
	set[c] = struct{}{}
	return true
}

func (h *hub) remove(c *liveConn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if set := h.users[c.user]; set != nil {
		delete(set, c)
		if len(set) == 0 {
			delete(h.users, c.user)
		}
	}
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

func (s *Server) appLive(w http.ResponseWriter, r *http.Request) error {
	p := who(r)
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		return nil // Accept sudah menulis respons galat
	}
	ws.SetReadLimit(1 << 10) // aplikasi tidak mengirim apa-apa lewat saluran ini
	lc := &liveConn{user: p.UserID, device: p.DeviceID, send: make(chan []byte, liveSendSize), done: make(chan struct{})}
	if !s.live.add(lc) {
		ws.Close(websocket.StatusTryAgainLater, "terlalu banyak koneksi")
		return nil
	}
	defer s.live.remove(lc)
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
	hello, _ := json.Marshal(map[string]any{"type": "hello", "unread": unread})
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
