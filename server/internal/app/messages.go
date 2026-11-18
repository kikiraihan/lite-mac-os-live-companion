package app

import (
	"context"
	"database/sql"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/httpx"
)

// Pesan antar teman dari aplikasi Mac (⌘-klik pet teman). Hanya lewat token perangkat (/api/app/*),
// dan hanya antara dua orang yang berteman. Kabar real-time dikirim lewat hub (live.go).
//
// Status pesan (hanya untuk pesanku sendiri, "status" di JSON), seperti WhatsApp:
//   sent      ✓        tersimpan di server
//   delivered ✓✓       sudah sampai di Mac penerima (lewat saluran real-time, sync, atau saat memuat obrolan)
//   read      ✓✓ biru  penerima sudah membuka obrolannya
// Perubahan status dikirim ke Mac pengirim sebagai kabar "receipt".

const maxMessage = 1000 // karakter

func (s *Server) messageRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/app/ws", s.device(s.appLive))
	mux.HandleFunc("GET /api/app/messages/{id}", s.device(s.appMessages))
	mux.HandleFunc("POST /api/app/messages/{id}", s.device(s.appSendMessage))
	mux.HandleFunc("POST /api/app/messages/{id}/read", s.device(s.appReadMessages))
}

// chatFriend: id teman dari path; harus teman pemanggil dan akunnya aktif (selain itu 404).
func (s *Server) chatFriend(r *http.Request) (id, name string, err error) {
	if id, err = pathID(r, "id"); err != nil {
		return
	}
	id = strings.ToLower(id)
	me := who(r).UserID
	if id == me || !s.areFriends(r.Context(), me, id) {
		return "", "", httpx.ErrNotFound
	}
	err = s.DB.QueryRowContext(r.Context(), `SELECT name FROM users WHERE id=$1 AND disabled_at IS NULL`, id).Scan(&name)
	return id, name, notFoundIf(err)
}

func messageJSON(id int64, text string, at time.Time, mine bool) map[string]any {
	return map[string]any{"id": id, "text": text, "created_at": at, "mine": mine}
}

// myMessageJSON: pesanku sendiri + statusnya (sent / delivered / read)
func myMessageJSON(id int64, text string, at time.Time, status string) map[string]any {
	m := messageJSON(id, text, at, true)
	m["status"] = status
	return m
}

func messageStatus(delivered, read sql.NullTime) string {
	switch {
	case read.Valid:
		return "read"
	case delivered.Valid:
		return "delivered"
	}
	return "sent"
}

// markDelivered: pesan untuk `me` (dari `from`, atau dari siapa pun kalau kosong) yang belum diterima
// ditandai diterima, lalu Mac pengirimnya diberi kabar "receipt".
func (s *Server) markDelivered(ctx context.Context, me, from string) {
	rows, err := s.DB.QueryContext(ctx, `WITH u AS (
			UPDATE messages SET delivered_at=now() WHERE to_user=$1 AND delivered_at IS NULL
				AND ($2 = '' OR from_user::text = $2) RETURNING from_user, id)
		SELECT from_user, max(id) FROM u GROUP BY from_user`, me, from)
	if err != nil {
		log.Printf("pesan: diterima %v", err)
		return
	}
	defer rows.Close()
	for rows.Next() {
		var sender string
		var upto int64
		if rows.Scan(&sender, &upto) == nil {
			s.live.publish(sender, map[string]any{"type": "receipt", "friend_id": me, "delivered_upto": upto})
		}
	}
}

// appMessages: 50 pesan terakhir (urut lama → baru); ?before=<id> untuk yang lebih lama.
func (s *Server) appMessages(w http.ResponseWriter, r *http.Request) error {
	friend, name, err := s.chatFriend(r)
	if err != nil {
		return err
	}
	me := who(r).UserID
	before, _ := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
	s.markDelivered(r.Context(), me, friend) // obrolan dibuka di Mac ini → pesan dari teman sudah sampai
	rows, err := s.DB.QueryContext(r.Context(), `SELECT id, from_user, text, created_at, delivered_at, read_at FROM messages
		WHERE LEAST(from_user, to_user)=LEAST($1::uuid, $2::uuid) AND GREATEST(from_user, to_user)=GREATEST($1::uuid, $2::uuid)
		AND ($3::bigint = 0 OR id < $3) ORDER BY id DESC LIMIT 51`, me, friend, before)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id int64
		var from, text string
		var at time.Time
		var delivered, read sql.NullTime
		if err := rows.Scan(&id, &from, &text, &at, &delivered, &read); err != nil {
			return err
		}
		if from == me {
			out = append(out, myMessageJSON(id, text, at, messageStatus(delivered, read)))
		} else {
			out = append(out, messageJSON(id, text, at, false))
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	more := len(out) > 50
	if more {
		out = out[:50]
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	httpx.JSON(w, 200, map[string]any{"friend": map[string]any{"id": friend, "name": name}, "messages": out, "has_more": more})
	return nil
}

func (s *Server) appSendMessage(w http.ResponseWriter, r *http.Request) error {
	friend, _, err := s.chatFriend(r)
	if err != nil {
		return err
	}
	var req struct {
		Text string `json:"text"`
	}
	if err := httpx.Decode(r, &req, 1<<13); err != nil {
		return err
	}
	text := clean(req.Text, maxMessage)
	if text == "" {
		return httpx.Invalid("Pesannya masih kosong. Tulis sesuatu dulu, lalu kirim.")
	}
	p := who(r)
	var recent int
	s.DB.QueryRowContext(r.Context(), `SELECT count(*) FROM messages WHERE from_user=$1 AND to_user=$2 AND created_at > now() - interval '1 minute'`,
		p.UserID, friend).Scan(&recent)
	if recent >= 30 {
		return httpx.Err(429, "rate_limited", "Pelan-pelan, pesanmu sudah banyak sekali barusan. Tunggu sebentar, lalu kirim lagi.")
	}
	var id int64
	var at time.Time
	if err := s.DB.QueryRowContext(r.Context(), `INSERT INTO messages(from_user, to_user, text) VALUES($1,$2,$3) RETURNING id, created_at`,
		p.UserID, friend, text).Scan(&id, &at); err != nil {
		return err
	}
	// ke teman (semua Mac-nya) dan ke Mac lain milik pengirim, supaya jendela chat di sana ikut bertambah
	status := "sent"
	if s.live.publish(friend, map[string]any{"type": "message", "friend_id": p.UserID, "friend_name": p.Name,
		"message": messageJSON(id, text, at, false)}) > 0 {
		// minimal satu Mac teman sedang tersambung dan menerimanya → langsung ✓✓
		if _, err := s.DB.ExecContext(r.Context(), `UPDATE messages SET delivered_at=now() WHERE id=$1`, id); err == nil {
			status = "delivered"
		}
	}
	mine := myMessageJSON(id, text, at, status)
	s.live.publish(p.UserID, map[string]any{"type": "message", "friend_id": friend, "message": mine})
	httpx.JSON(w, 201, map[string]any{"message": mine})
	return nil
}

// appReadMessages: semua pesan dari teman ini sudah dibaca → indikator di semua Mac pemanggil hilang.
func (s *Server) appReadMessages(w http.ResponseWriter, r *http.Request) error {
	friend, _, err := s.chatFriend(r)
	if err != nil {
		return err
	}
	me := who(r).UserID
	var upto sql.NullInt64
	err = s.DB.QueryRowContext(r.Context(), `WITH u AS (
			UPDATE messages SET read_at=now(), delivered_at=COALESCE(delivered_at, now())
				WHERE to_user=$1 AND from_user=$2 AND read_at IS NULL RETURNING id)
		SELECT max(id) FROM u`, me, friend).Scan(&upto)
	if err != nil {
		return err
	}
	if upto.Valid {
		s.live.publish(me, map[string]any{"type": "read", "friend_id": friend})
		// Mac teman: pesannya ke aku sudah dibaca (✓✓ biru)
		s.live.publish(friend, map[string]any{"type": "receipt", "friend_id": me, "delivered_upto": upto.Int64, "read_upto": upto.Int64})
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

// unreadCounts: pesan belum dibaca per teman (hanya dari yang masih berteman & aktif),
// berisi nama juga supaya menu aplikasi bisa menulis "Pesan dari Dina" walau pet Dina tidak tampil di Mac.
func (s *Server) unreadCounts(ctx context.Context, me string) ([]map[string]any, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT m.from_user, u.name, count(*) FROM messages m JOIN users u ON u.id=m.from_user
		WHERE m.to_user=$1 AND m.read_at IS NULL AND u.disabled_at IS NULL
		AND EXISTS (SELECT 1 FROM friendships f WHERE f.user_a=LEAST(m.from_user, m.to_user) AND f.user_b=GREATEST(m.from_user, m.to_user))
		GROUP BY m.from_user, u.name ORDER BY max(m.id) DESC`, me)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, name string
		var n int
		if err := rows.Scan(&id, &name, &n); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{"friend_id": id, "friend_name": name, "count": n})
	}
	return out, rows.Err()
}
