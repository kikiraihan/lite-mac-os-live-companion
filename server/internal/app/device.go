package app

import (
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/httpx"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/security"
)

// Menghubungkan aplikasi Mac ke akun, tanpa mengetik password di aplikasi:
//  1. aplikasi  POST /api/app/link/start  → kode pendek + poll_token, lalu membuka
//     {PUBLIC_URL}/hubungkan?code=KODE di browser
//  2. pengguna (sudah masuk di web) menyetujui kode itu
//  3. aplikasi  POST /api/app/link/poll   → token perangkat (sekali saja), disimpan di Keychain
//
// Token perangkat hanya bisa membaca daftar pet yang tampil di Mac & sapaan teman.

func (s *Server) deviceRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/app/link/start", s.wrap(s.limited(s.linkStart)))
	mux.HandleFunc("POST /api/app/link/poll", s.wrap(s.linkPoll))
	mux.HandleFunc("GET /api/app/sync", s.device(s.appSync))
	mux.HandleFunc("GET /api/app/pets/{id}/sheet.png", s.device(s.appPetSheet))
	mux.HandleFunc("POST /api/app/unlink", s.device(s.appUnlink))

	mux.HandleFunc("GET /api/link/{code}", s.user(s.linkInfo))
	mux.HandleFunc("POST /api/link/{code}/approve", s.user(s.linkApprove))
	mux.HandleFunc("GET /api/devices", s.user(s.listDevices))
	mux.HandleFunc("DELETE /api/devices/{id}", s.user(s.deleteDevice))
}

// device: wajib token perangkat (Authorization: Bearer …).
func (s *Server) device(h Handler) http.HandlerFunc {
	return s.wrap(func(w http.ResponseWriter, r *http.Request) error {
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if len(tok) < 20 {
			return httpx.ErrUnauth
		}
		p := &Principal{}
		var disabled sql.NullTime
		err := s.DB.QueryRowContext(r.Context(), `UPDATE devices d SET last_seen_at=now() FROM users u
			WHERE d.token_hash=$1 AND u.id=d.user_id RETURNING d.id, u.id, u.name, u.handle, u.disabled_at`, security.SHA256(tok)).
			Scan(&p.DeviceID, &p.UserID, &p.Name, &p.Handle, &disabled)
		if err != nil || disabled.Valid {
			return httpx.ErrUnauth
		}
		return h(w, withPrincipal(r, p))
	})
}

func normCode(c string) string {
	return strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(c), "-", ""))
}

func (s *Server) linkStart(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		DeviceName string `json:"device_name"`
	}
	if err := httpx.Decode(r, &req, 1<<10); err != nil {
		return err
	}
	name := clean(req.DeviceName, 60)
	if name == "" {
		name = "Mac"
	}
	s.DB.ExecContext(r.Context(), `DELETE FROM device_links WHERE expires_at < now()`)
	code, poll := security.RandomCode(8), security.RandomToken(32)
	if _, err := s.DB.ExecContext(r.Context(), `INSERT INTO device_links(code, poll_hash, device_name, expires_at) VALUES($1,$2,$3,now() + interval '10 minutes')`,
		code, security.SHA256(poll), name); err != nil {
		return err
	}
	pretty := code[:4] + "-" + code[4:]
	httpx.JSON(w, 201, map[string]any{"code": pretty, "poll_token": poll, "expires_in": 600, "interval": 3,
		"url": s.Cfg.PublicURL + "/hubungkan?code=" + pretty})
	return nil
}

func (s *Server) linkPoll(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		PollToken string `json:"poll_token"`
	}
	if err := httpx.Decode(r, &req, 1<<10); err != nil {
		return err
	}
	var code, name string
	var user sql.NullString
	err := s.DB.QueryRowContext(r.Context(), `SELECT code, device_name, user_id FROM device_links WHERE poll_hash=$1 AND expires_at > now()`,
		security.SHA256(req.PollToken)).Scan(&code, &name, &user)
	if errors.Is(err, sql.ErrNoRows) {
		return httpx.Err(410, "link_expired", "Kode sudah kedaluwarsa. Mulai lagi dari aplikasi.")
	}
	if err != nil {
		return err
	}
	if !user.Valid {
		httpx.JSON(w, 200, map[string]any{"status": "pending"})
		return nil
	}
	// disetujui → buat token perangkat, sekali ambil
	res, err := s.DB.ExecContext(r.Context(), `DELETE FROM device_links WHERE code=$1`, code)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.Err(410, "link_expired", "Kode sudah dipakai.")
	}
	token := "tmn_" + security.RandomToken(32)
	if _, err := s.DB.ExecContext(r.Context(), `INSERT INTO devices(user_id, name, token_hash) VALUES($1,$2,$3)`, user.String, name, security.SHA256(token)); err != nil {
		return err
	}
	var uname, handle string
	s.DB.QueryRowContext(r.Context(), `SELECT name, handle FROM users WHERE id=$1`, user.String).Scan(&uname, &handle)
	httpx.JSON(w, 200, map[string]any{"status": "approved", "token": token, "user": map[string]any{"name": uname, "handle": handle}})
	return nil
}

func (s *Server) linkInfo(w http.ResponseWriter, r *http.Request) error {
	var name string
	var user sql.NullString
	err := s.DB.QueryRowContext(r.Context(), `SELECT device_name, user_id FROM device_links WHERE code=$1 AND expires_at > now()`,
		normCode(r.PathValue("code"))).Scan(&name, &user)
	if err != nil || user.Valid {
		return httpx.Err(404, "link_invalid", "Kode tidak ditemukan atau sudah kedaluwarsa. Klik \"Hubungkan akun\" lagi di aplikasi Mac.")
	}
	httpx.JSON(w, 200, map[string]any{"device_name": name})
	return nil
}

func (s *Server) linkApprove(w http.ResponseWriter, r *http.Request) error {
	me := who(r).UserID
	var n int
	s.DB.QueryRowContext(r.Context(), `SELECT count(*) FROM devices WHERE user_id=$1`, me).Scan(&n)
	if n >= 10 {
		return httpx.Err(409, "device_limit", "Sudah ada 10 Mac yang terhubung. Putuskan salah satu dulu.")
	}
	res, err := s.DB.ExecContext(r.Context(), `UPDATE device_links SET user_id=$2 WHERE code=$1 AND user_id IS NULL AND expires_at > now()`,
		normCode(r.PathValue("code")), me)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.Err(404, "link_invalid", "Kode tidak ditemukan atau sudah kedaluwarsa. Klik \"Hubungkan akun\" lagi di aplikasi Mac.")
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

func (s *Server) listDevices(w http.ResponseWriter, r *http.Request) error {
	rows, err := s.DB.QueryContext(r.Context(), `SELECT id, name, created_at, last_seen_at FROM devices WHERE user_id=$1 ORDER BY created_at DESC`, who(r).UserID)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, name string
		var at time.Time
		var seen sql.NullTime
		if err := rows.Scan(&id, &name, &at, &seen); err != nil {
			return err
		}
		out = append(out, map[string]any{"id": id, "name": name, "created_at": at, "last_seen_at": nt(seen)})
	}
	httpx.JSON(w, 200, map[string]any{"data": out})
	return rows.Err()
}

func (s *Server) deleteDevice(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	res, err := s.DB.ExecContext(r.Context(), `DELETE FROM devices WHERE id=$1 AND user_id=$2`, id, who(r).UserID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.ErrNotFound
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

// ---------------- API aplikasi Mac ----------------

// appSync: pet yang harus tampil di Mac ini + sapaan teman yang belum disampaikan.
func (s *Server) appSync(w http.ResponseWriter, r *http.Request) error {
	p := who(r)
	rows, err := s.DB.QueryContext(r.Context(), `
		SELECT p.id, p.name, p.sheet_ver, u.name, true FROM pets p JOIN users u ON u.id=p.owner_id
			WHERE p.owner_id=$1 AND p.on_mac AND p.hidden_at IS NULL
		UNION ALL
		SELECT p.id, p.name, p.sheet_ver, u.name, false FROM pet_shares sh JOIN pets p ON p.id=sh.pet_id JOIN users u ON u.id=p.owner_id
			WHERE sh.to_user=$1 AND sh.status='approved' AND sh.on_mac AND p.hidden_at IS NULL AND u.disabled_at IS NULL
		LIMIT 12`, p.UserID)
	if err != nil {
		return err
	}
	defer rows.Close()
	pets := []map[string]any{}
	for rows.Next() {
		var id, name, owner string
		var ver int
		var mine bool
		if err := rows.Scan(&id, &name, &ver, &owner, &mine); err != nil {
			return err
		}
		pets = append(pets, map[string]any{"id": id, "name": name, "sheet_ver": ver, "owner_name": owner, "mine": mine,
			"sheet_url": fmt.Sprintf("/api/app/pets/%s/sheet.png?v=%d", id, ver)})
	}
	if err := rows.Err(); err != nil {
		return err
	}
	nrows, err := s.DB.QueryContext(r.Context(), `UPDATE nudges n SET seen_at=now() FROM users u
		WHERE n.to_user=$1 AND n.seen_at IS NULL AND n.created_at > now() - interval '2 days' AND u.id=n.from_user
		RETURNING n.id, u.id, u.name, n.text`, p.UserID)
	if err != nil {
		return err
	}
	defer nrows.Close()
	nudges := []map[string]any{}
	for nrows.Next() {
		var id int64
		var from, name, text string
		if err := nrows.Scan(&id, &from, &name, &text); err != nil {
			return err
		}
		nudges = append(nudges, map[string]any{"id": id, "from_id": from, "from_name": name, "text": text})
	}
	httpx.JSON(w, 200, map[string]any{
		"user": map[string]any{"name": p.Name, "handle": p.Handle}, "pets": pets, "nudges": nudges,
		"poll_seconds": 60, "web_url": s.Cfg.PublicURL,
	})
	return nrows.Err()
}

func (s *Server) appPetSheet(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	me := who(r).UserID
	var sheet []byte
	err = s.DB.QueryRowContext(r.Context(), `SELECT p.sheet FROM pets p WHERE p.id=$1 AND p.hidden_at IS NULL AND (p.owner_id=$2
		OR EXISTS (SELECT 1 FROM pet_shares sh WHERE sh.pet_id=p.id AND sh.to_user=$2 AND sh.status='approved'))`, id, me).Scan(&sheet)
	if err != nil {
		return notFoundIf(err)
	}
	servePNG(w, r, sheet)
	return nil
}

func (s *Server) appUnlink(w http.ResponseWriter, r *http.Request) error {
	if _, err := s.DB.ExecContext(r.Context(), `DELETE FROM devices WHERE id=$1`, who(r).DeviceID); err != nil {
		return err
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}
