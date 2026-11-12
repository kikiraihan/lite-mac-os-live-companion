package app

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/httpx"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/security"
)

func (s *Server) friendRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/friends", s.user(s.listFriends))
	mux.HandleFunc("DELETE /api/friends/{id}", s.user(s.unfriend))
	mux.HandleFunc("POST /api/friends/{id}/nudge", s.user(s.nudge))
	mux.HandleFunc("POST /api/friends/invites", s.user(s.createInvite))
	mux.HandleFunc("POST /api/friends/requests", s.user(s.sendFriendRequest))
	mux.HandleFunc("POST /api/friends/requests/{id}/accept", s.user(s.acceptFriendRequest))
	mux.HandleFunc("DELETE /api/friends/requests/{id}", s.user(s.deleteFriendRequest))
	// tautan undangan: info-nya boleh dilihat sebelum masuk / daftar
	mux.HandleFunc("GET /api/invites/{code}", s.wrap(s.limited(s.inviteInfo)))
	mux.HandleFunc("GET /api/invites/{code}/pet.png", s.wrap(s.invitePet))
	mux.HandleFunc("POST /api/invites/{code}/accept", s.user(s.acceptInvite))
}

func pair(a, b string) (string, string) {
	if a < b {
		return a, b
	}
	return b, a
}

func (s *Server) areFriends(ctx context.Context, a, b string) bool {
	x, y := pair(a, b)
	var ok bool
	s.DB.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM friendships WHERE user_a=$1 AND user_b=$2)`, x, y).Scan(&ok)
	return ok
}

func (s *Server) befriend(ctx context.Context, a, b string) error {
	if a == b {
		return nil
	}
	x, y := pair(a, b)
	if _, err := s.DB.ExecContext(ctx, `INSERT INTO friendships(user_a, user_b) VALUES($1,$2) ON CONFLICT DO NOTHING`, x, y); err != nil {
		return err
	}
	_, err := s.DB.ExecContext(ctx, `DELETE FROM friend_requests WHERE (from_user=$1 AND to_user=$2) OR (from_user=$2 AND to_user=$1)`, a, b)
	return err
}

func (s *Server) listFriends(w http.ResponseWriter, r *http.Request) error {
	me := who(r).UserID
	rows, err := s.DB.QueryContext(r.Context(), `SELECT u.id, u.name, u.handle, f.created_at FROM friendships f
		JOIN users u ON u.id = CASE WHEN f.user_a=$1 THEN f.user_b ELSE f.user_a END
		WHERE (f.user_a=$1 OR f.user_b=$1) AND u.disabled_at IS NULL ORDER BY lower(u.name)`, me)
	if err != nil {
		return err
	}
	defer rows.Close()
	friends := []map[string]any{}
	index := map[string]int{}
	for rows.Next() {
		var id, name, handle string
		var at time.Time
		if err := rows.Scan(&id, &name, &handle, &at); err != nil {
			return err
		}
		index[id] = len(friends)
		friends = append(friends, map[string]any{"id": id, "name": name, "handle": handle, "since": at, "pets": []map[string]any{}})
	}
	if err := rows.Err(); err != nil {
		return err
	}
	// pet teman + status permintaanku atas tiap pet
	prow, err := s.DB.QueryContext(r.Context(), `SELECT p.id, p.owner_id, p.name, p.bio, p.sheet_ver, sh.id, sh.status
		FROM pets p LEFT JOIN pet_shares sh ON sh.pet_id=p.id AND sh.to_user=$1
		WHERE p.hidden_at IS NULL AND p.owner_id IN (
			SELECT CASE WHEN user_a=$1 THEN user_b ELSE user_a END FROM friendships WHERE user_a=$1 OR user_b=$1)
		ORDER BY p.created_at`, me)
	if err != nil {
		return err
	}
	defer prow.Close()
	for prow.Next() {
		var id, owner, name, bio string
		var ver int
		var shareID, status sql.NullString
		if err := prow.Scan(&id, &owner, &name, &bio, &ver, &shareID, &status); err != nil {
			return err
		}
		i, ok := index[owner]
		if !ok {
			continue
		}
		pet := map[string]any{"id": id, "name": name, "bio": bio, "sheet_url": fmt.Sprintf("/api/pets/%s/sheet.png?v=%d", id, ver),
			"share_id": nil, "share_status": "none"}
		if shareID.Valid {
			pet["share_id"], pet["share_status"] = shareID.String, status.String
		}
		friends[i]["pets"] = append(friends[i]["pets"].([]map[string]any), pet)
	}
	if err := prow.Err(); err != nil {
		return err
	}

	reqs := func(q string) ([]map[string]any, error) {
		rows, err := s.DB.QueryContext(r.Context(), q, me)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		out := []map[string]any{}
		for rows.Next() {
			var id, uid, name, handle string
			var at time.Time
			if err := rows.Scan(&id, &at, &uid, &name, &handle); err != nil {
				return nil, err
			}
			out = append(out, map[string]any{"id": id, "created_at": at, "user": map[string]any{"id": uid, "name": name, "handle": handle}})
		}
		return out, rows.Err()
	}
	incoming, err := reqs(`SELECT fr.id, fr.created_at, u.id, u.name, u.handle FROM friend_requests fr JOIN users u ON u.id=fr.from_user WHERE fr.to_user=$1 ORDER BY fr.created_at DESC`)
	if err != nil {
		return err
	}
	outgoing, err := reqs(`SELECT fr.id, fr.created_at, u.id, u.name, u.handle FROM friend_requests fr JOIN users u ON u.id=fr.to_user WHERE fr.from_user=$1 ORDER BY fr.created_at DESC`)
	if err != nil {
		return err
	}
	httpx.JSON(w, 200, map[string]any{"friends": friends, "incoming": incoming, "outgoing": outgoing})
	return nil
}

func (s *Server) unfriend(w http.ResponseWriter, r *http.Request) error {
	other, err := pathID(r, "id")
	if err != nil {
		return err
	}
	me := who(r).UserID
	x, y := pair(me, other)
	res, err := s.DB.ExecContext(r.Context(), `DELETE FROM friendships WHERE user_a=$1 AND user_b=$2`, x, y)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.ErrNotFound
	}
	// pet titipan di kedua arah ikut pulang
	_, err = s.DB.ExecContext(r.Context(), `DELETE FROM pet_shares sh USING pets p WHERE p.id=sh.pet_id
		AND ((p.owner_id=$1 AND sh.to_user=$2) OR (p.owner_id=$2 AND sh.to_user=$1))`, me, other)
	if err != nil {
		return err
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

// nudge: sapa teman — pet di Mac-nya akan menyampaikan pesannya.
func (s *Server) nudge(w http.ResponseWriter, r *http.Request) error {
	other, err := pathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Text string `json:"text"`
	}
	if err := httpx.Decode(r, &req, 1<<12); err != nil {
		return err
	}
	me := who(r).UserID
	if !s.areFriends(r.Context(), me, other) {
		return httpx.ErrNotFound
	}
	var recent int
	s.DB.QueryRowContext(r.Context(), `SELECT count(*) FROM nudges WHERE from_user=$1 AND to_user=$2 AND created_at > now() - interval '1 minute'`, me, other).Scan(&recent)
	if recent >= 3 {
		return httpx.Err(429, "rate_limited", "Pelan-pelan, sapaanmu barusan masih di jalan.")
	}
	if _, err := s.DB.ExecContext(r.Context(), `INSERT INTO nudges(from_user, to_user, text) VALUES($1,$2,$3)`, me, other, clean(req.Text, 80)); err != nil {
		return err
	}
	httpx.JSON(w, 201, map[string]any{"ok": true})
	return nil
}

// ---------------- undangan ----------------

func (s *Server) createInvite(w http.ResponseWriter, r *http.Request) error {
	me := who(r).UserID
	var code string
	var exp time.Time
	// satu tautan aktif per pengguna, berlaku 14 hari
	err := s.DB.QueryRowContext(r.Context(), `SELECT code, expires_at FROM friend_invites WHERE from_user=$1 AND expires_at > now() + interval '1 day'
		ORDER BY created_at DESC LIMIT 1`, me).Scan(&code, &exp)
	if errors.Is(err, sql.ErrNoRows) {
		code = security.RandomCode(10)
		exp = time.Now().Add(14 * 24 * time.Hour)
		_, err = s.DB.ExecContext(r.Context(), `INSERT INTO friend_invites(code, from_user, expires_at) VALUES($1,$2,$3)`, code, me, exp)
	}
	if err != nil {
		return err
	}
	httpx.JSON(w, 201, map[string]any{"code": code, "url": s.Cfg.PublicURL + "/undang/" + code, "expires_at": exp})
	return nil
}

func (s *Server) inviteOwner(r *http.Request) (id, name, handle string, err error) {
	code := strings.ToUpper(r.PathValue("code"))
	err = s.DB.QueryRowContext(r.Context(), `SELECT u.id, u.name, u.handle FROM friend_invites i JOIN users u ON u.id=i.from_user
		WHERE i.code=$1 AND i.expires_at > now() AND u.disabled_at IS NULL`, code).Scan(&id, &name, &handle)
	if errors.Is(err, sql.ErrNoRows) {
		err = httpx.Err(404, "invite_invalid", "Tautan undangan ini sudah tidak berlaku. Minta tautan baru dari temanmu.")
	}
	return
}

func (s *Server) inviteInfo(w http.ResponseWriter, r *http.Request) error {
	_, name, handle, err := s.inviteOwner(r)
	if err != nil {
		return err
	}
	httpx.JSON(w, 200, map[string]any{"from": map[string]any{"name": name, "handle": handle},
		"pet_url": "/api/invites/" + strings.ToUpper(r.PathValue("code")) + "/pet.png"})
	return nil
}

// invitePet: pet pertama si pengundang, supaya halaman undangan terasa hidup.
func (s *Server) invitePet(w http.ResponseWriter, r *http.Request) error {
	id, _, _, err := s.inviteOwner(r)
	if err != nil {
		return err
	}
	var sheet []byte
	if err := s.DB.QueryRowContext(r.Context(), `SELECT sheet FROM pets WHERE owner_id=$1 AND hidden_at IS NULL ORDER BY created_at LIMIT 1`, id).Scan(&sheet); err != nil {
		return notFoundIf(err)
	}
	servePNG(w, r, sheet)
	return nil
}

func (s *Server) acceptInvite(w http.ResponseWriter, r *http.Request) error {
	id, name, _, err := s.inviteOwner(r)
	if err != nil {
		return err
	}
	me := who(r).UserID
	if id == me {
		return httpx.Invalid("Ini tautan undanganmu sendiri. Kirim ke teman, ya.")
	}
	if err := s.befriend(r.Context(), me, id); err != nil {
		return err
	}
	s.DB.ExecContext(r.Context(), `UPDATE friend_invites SET uses=uses+1 WHERE code=$1`, strings.ToUpper(r.PathValue("code")))
	httpx.JSON(w, 200, map[string]any{"ok": true, "friend": map[string]any{"id": id, "name": name}})
	return nil
}

// ---------------- permintaan pertemanan lewat nama pengguna ----------------

func (s *Server) sendFriendRequest(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Handle string `json:"handle"`
	}
	if err := httpx.Decode(r, &req, 1<<10); err != nil {
		return err
	}
	me := who(r).UserID
	h := strings.TrimPrefix(strings.ToLower(strings.TrimSpace(req.Handle)), "@")
	var other string
	err := s.DB.QueryRowContext(r.Context(), `SELECT id FROM users WHERE lower(handle)=$1 AND disabled_at IS NULL`, h).Scan(&other)
	if errors.Is(err, sql.ErrNoRows) {
		return httpx.Err(404, "user_not_found", "Tidak ada pengguna bernama @"+h+".")
	}
	if err != nil {
		return err
	}
	if other == me {
		return httpx.Invalid("Itu nama penggunamu sendiri.")
	}
	if s.areFriends(r.Context(), me, other) {
		return httpx.Err(409, "already_friends", "Kalian sudah berteman.")
	}
	// dia sudah lebih dulu meminta → langsung berteman
	var reverse bool
	s.DB.QueryRowContext(r.Context(), `SELECT EXISTS(SELECT 1 FROM friend_requests WHERE from_user=$1 AND to_user=$2)`, other, me).Scan(&reverse)
	if reverse {
		if err := s.befriend(r.Context(), me, other); err != nil {
			return err
		}
		httpx.JSON(w, 200, map[string]any{"ok": true, "friends": true})
		return nil
	}
	if _, err := s.DB.ExecContext(r.Context(), `INSERT INTO friend_requests(from_user, to_user) VALUES($1,$2) ON CONFLICT DO NOTHING`, me, other); err != nil {
		return err
	}
	httpx.JSON(w, 201, map[string]any{"ok": true, "friends": false})
	return nil
}

func (s *Server) acceptFriendRequest(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	me := who(r).UserID
	var from string
	if err := s.DB.QueryRowContext(r.Context(), `SELECT from_user FROM friend_requests WHERE id=$1 AND to_user=$2`, id, me).Scan(&from); err != nil {
		return notFoundIf(err)
	}
	if err := s.befriend(r.Context(), me, from); err != nil {
		return err
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

// deleteFriendRequest: penerima menolak, atau pengirim membatalkan.
func (s *Server) deleteFriendRequest(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	res, err := s.DB.ExecContext(r.Context(), `DELETE FROM friend_requests WHERE id=$1 AND (to_user=$2 OR from_user=$2)`, id, who(r).UserID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.ErrNotFound
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}
