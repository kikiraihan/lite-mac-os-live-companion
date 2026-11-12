package app

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/ai"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/httpx"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/security"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/sprite"
)

func (s *Server) adminRoutes(mux *http.ServeMux) {
	a := s.admin
	mux.HandleFunc("GET /api/admin/overview", a(s.adminOverview))
	mux.HandleFunc("GET /api/admin/users", a(s.adminUsers))
	mux.HandleFunc("PATCH /api/admin/users/{id}", a(s.adminUpdateUser))
	mux.HandleFunc("GET /api/admin/pets", a(s.adminPets))
	mux.HandleFunc("PATCH /api/admin/pets/{id}", a(s.adminUpdatePet))
	mux.HandleFunc("GET /api/admin/pets/{id}/sheet.png", a(s.adminPetSheet))

	mux.HandleFunc("GET /api/admin/connections", a(s.adminConnections))
	mux.HandleFunc("POST /api/admin/connections", a(s.adminSaveConnection))
	mux.HandleFunc("PATCH /api/admin/connections/{id}", a(s.adminSaveConnection))
	mux.HandleFunc("DELETE /api/admin/connections/{id}", a(s.adminDeleteConnection))
	mux.HandleFunc("POST /api/admin/connections/{id}/test", a(s.adminTestConnection))
	mux.HandleFunc("GET /api/admin/connections/{id}/models", a(s.adminConnectionModels))

	mux.HandleFunc("GET /api/admin/generations", a(s.adminGenerations))
	mux.HandleFunc("GET /api/admin/settings", a(s.adminGetSettings))
	mux.HandleFunc("PUT /api/admin/settings", a(s.adminPutSettings))
	mux.HandleFunc("GET /api/admin/audit", a(s.adminAudit))

	mux.HandleFunc("GET /api/admin/accounts", s.superAdmin(s.adminAccounts))
	mux.HandleFunc("POST /api/admin/accounts", s.superAdmin(s.adminCreateAccount))
	mux.HandleFunc("PATCH /api/admin/accounts/{id}", s.superAdmin(s.adminUpdateAccount))
}

func (s *Server) adminOverview(w http.ResponseWriter, r *http.Request) error {
	var users, users7, pets, friendships, devices, shares, genToday, genFailed, conns int
	err := s.DB.QueryRowContext(r.Context(), `SELECT
		(SELECT count(*) FROM users),
		(SELECT count(*) FROM users WHERE created_at > now() - interval '7 days'),
		(SELECT count(*) FROM pets),
		(SELECT count(*) FROM friendships),
		(SELECT count(*) FROM devices WHERE last_seen_at > now() - interval '7 days'),
		(SELECT count(*) FROM pet_shares WHERE status='approved'),
		(SELECT count(*) FROM generations WHERE created_at > now() - interval '24 hours'),
		(SELECT count(*) FROM generations WHERE status='failed' AND created_at > now() - interval '24 hours'),
		(SELECT count(*) FROM ai_connections WHERE enabled)`).
		Scan(&users, &users7, &pets, &friendships, &devices, &shares, &genToday, &genFailed, &conns)
	if err != nil {
		return err
	}
	// pendaftar & generate per hari, 14 hari terakhir
	series := func(table string) ([]map[string]any, error) {
		rows, err := s.DB.QueryContext(r.Context(), `SELECT d::date, (SELECT count(*) FROM `+table+` t WHERE t.created_at::date = d::date)
			FROM generate_series(current_date - 13, current_date, interval '1 day') d ORDER BY d`)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		out := []map[string]any{}
		for rows.Next() {
			var d time.Time
			var n int
			if err := rows.Scan(&d, &n); err != nil {
				return nil, err
			}
			out = append(out, map[string]any{"date": d.Format("2006-01-02"), "count": n})
		}
		return out, rows.Err()
	}
	signups, err := series("users")
	if err != nil {
		return err
	}
	gens, err := series("generations")
	if err != nil {
		return err
	}
	httpx.JSON(w, 200, map[string]any{
		"users": users, "users_week": users7, "pets": pets, "friendships": friendships, "active_macs": devices, "lent_pets": shares,
		"generations_today": genToday, "generations_failed_today": genFailed, "connections_enabled": conns, "ai_mock": s.Cfg.AIMock,
		"signups": signups, "generations": gens,
	})
	return nil
}

func (s *Server) adminUsers(w http.ResponseWriter, r *http.Request) error {
	q := "%" + strings.ToLower(clean(r.URL.Query().Get("q"), 60)) + "%"
	rows, err := s.DB.QueryContext(r.Context(), `SELECT u.id, u.email, u.name, u.handle, u.disabled_at, u.last_seen_at, u.created_at,
		(SELECT count(*) FROM pets p WHERE p.owner_id=u.id),
		(SELECT count(*) FROM friendships f WHERE f.user_a=u.id OR f.user_b=u.id),
		(SELECT count(*) FROM devices d WHERE d.user_id=u.id)
		FROM users u WHERE lower(u.email) LIKE $1 OR lower(u.name) LIKE $1 OR lower(u.handle) LIKE $1
		ORDER BY u.created_at DESC LIMIT 200`, q)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, email, name, handle string
		var dis, seen sql.NullTime
		var at time.Time
		var pets, friends, macs int
		if err := rows.Scan(&id, &email, &name, &handle, &dis, &seen, &at, &pets, &friends, &macs); err != nil {
			return err
		}
		out = append(out, map[string]any{"id": id, "email": email, "name": name, "handle": handle, "disabled": dis.Valid,
			"last_seen_at": nt(seen), "created_at": at, "pets": pets, "friends": friends, "macs": macs})
	}
	httpx.JSON(w, 200, map[string]any{"data": out})
	return rows.Err()
}

func (s *Server) adminUpdateUser(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Disabled bool `json:"disabled"`
	}
	if err := httpx.Decode(r, &req, 1<<10); err != nil {
		return err
	}
	q := `UPDATE users SET disabled_at=NULL WHERE id=$1`
	if req.Disabled {
		q = `UPDATE users SET disabled_at=COALESCE(disabled_at, now()) WHERE id=$1`
	}
	res, err := s.DB.ExecContext(r.Context(), q, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.ErrNotFound
	}
	if req.Disabled { // keluarkan dari semua browser; token Mac ditolak lewat disabled_at
		s.DB.ExecContext(r.Context(), `DELETE FROM sessions WHERE user_id=$1`, id)
	}
	s.audit(r, "user.update", id, map[string]any{"disabled": req.Disabled})
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

func (s *Server) adminPets(w http.ResponseWriter, r *http.Request) error {
	q := "%" + strings.ToLower(clean(r.URL.Query().Get("q"), 60)) + "%"
	rows, err := s.DB.QueryContext(r.Context(), `SELECT p.id, p.name, p.origin, p.sheet_ver, p.hidden_at, p.created_at, u.name, u.handle,
		(SELECT count(*) FROM pet_shares sh WHERE sh.pet_id=p.id AND sh.status='approved')
		FROM pets p JOIN users u ON u.id=p.owner_id
		WHERE lower(p.name) LIKE $1 OR lower(u.handle) LIKE $1 OR lower(u.name) LIKE $1
		ORDER BY p.created_at DESC LIMIT 200`, q)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, name, origin, owner, handle string
		var ver, lent int
		var hidden sql.NullTime
		var at time.Time
		if err := rows.Scan(&id, &name, &origin, &ver, &hidden, &at, &owner, &handle, &lent); err != nil {
			return err
		}
		out = append(out, map[string]any{"id": id, "name": name, "origin": origin, "hidden": hidden.Valid, "created_at": at,
			"owner_name": owner, "owner_handle": handle, "lent": lent,
			"sheet_url": "/api/admin/pets/" + id + "/sheet.png?v=" + itoa(ver)})
	}
	httpx.JSON(w, 200, map[string]any{"data": out})
	return rows.Err()
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

func (s *Server) adminUpdatePet(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Hidden bool `json:"hidden"`
	}
	if err := httpx.Decode(r, &req, 1<<10); err != nil {
		return err
	}
	q := `UPDATE pets SET hidden_at=NULL WHERE id=$1`
	if req.Hidden {
		q = `UPDATE pets SET hidden_at=COALESCE(hidden_at, now()) WHERE id=$1`
	}
	res, err := s.DB.ExecContext(r.Context(), q, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.ErrNotFound
	}
	s.audit(r, "pet.update", id, map[string]any{"hidden": req.Hidden})
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

func (s *Server) adminPetSheet(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	var sheet []byte
	if err := s.DB.QueryRowContext(r.Context(), `SELECT sheet FROM pets WHERE id=$1`, id).Scan(&sheet); err != nil {
		return notFoundIf(err)
	}
	servePNG(w, r, sheet)
	return nil
}

// ---------------- koneksi provider AI ----------------

func (s *Server) adminConnections(w http.ResponseWriter, r *http.Request) error {
	rows, err := s.DB.QueryContext(r.Context(), `SELECT id, name, kind, base_url, api_key_enc, image_model, style, enabled, priority,
		last_test_at, last_test_ok, last_test_msg, updated_at,
		(SELECT count(*) FROM generations g WHERE g.connection_id=c.id AND g.status='done'),
		(SELECT count(*) FROM generations g WHERE g.connection_id=c.id AND g.status='failed')
		FROM ai_connections c ORDER BY priority, created_at`)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, name, kind, base, model, style, msg string
		var enc []byte
		var enabled bool
		var prio, done, failed int
		var testAt sql.NullTime
		var testOK sql.NullBool
		var updated time.Time
		if err := rows.Scan(&id, &name, &kind, &base, &enc, &model, &style, &enabled, &prio, &testAt, &testOK, &msg, &updated, &done, &failed); err != nil {
			return err
		}
		// API key tidak pernah dikirim balik — hanya potongan untuk dikenali
		masked := "tidak terbaca"
		if key, err := security.Open(s.Cfg.AppSecret, enc); err == nil {
			masked = security.MaskKey(key)
		}
		var ok any
		if testOK.Valid {
			ok = testOK.Bool
		}
		out = append(out, map[string]any{"id": id, "name": name, "kind": kind, "base_url": base, "api_key_masked": masked,
			"image_model": model, "style": style, "enabled": enabled, "priority": prio, "last_test_at": nt(testAt), "last_test_ok": ok,
			"last_test_msg": msg, "updated_at": updated, "done": done, "failed": failed})
	}
	httpx.JSON(w, 200, map[string]any{"data": out, "presets": ai.Presets, "ai_mock": s.Cfg.AIMock})
	return rows.Err()
}

// adminSaveConnection: buat (POST) atau ubah (PATCH). Saat mengubah, api_key kosong = tetap.
func (s *Server) adminSaveConnection(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Name     string `json:"name"`
		Kind     string `json:"kind"`
		BaseURL  string `json:"base_url"`
		APIKey   string `json:"api_key"`
		Model    string `json:"image_model"`
		Style    string `json:"style"`
		Enabled  *bool  `json:"enabled"`
		Priority *int   `json:"priority"`
	}
	if err := httpx.Decode(r, &req, 1<<14); err != nil {
		return err
	}
	req.Name, req.Model = clean(req.Name, 60), clean(req.Model, 120)
	req.BaseURL = strings.TrimRight(strings.TrimSpace(req.BaseURL), "/")
	req.APIKey = strings.TrimSpace(req.APIKey)
	isNew := r.Method == http.MethodPost
	switch {
	case req.Name == "":
		return httpx.Invalid("Beri nama koneksi ini.")
	case req.Kind != "kenari" && req.Kind != "openrouter" && req.Kind != "custom":
		return httpx.Invalid("Jenis provider tidak dikenal.")
	case !strings.HasPrefix(req.BaseURL, "https://") && !(s.Cfg.Env != "production" && strings.HasPrefix(req.BaseURL, "http://")):
		return httpx.Invalid("Base URL harus diawali https://.")
	case req.Model == "":
		return httpx.Invalid("Isi model gambar yang dipakai.")
	case req.Style != "chat" && req.Style != "images":
		return httpx.Invalid("Gaya permintaan harus chat atau images.")
	case isNew && req.APIKey == "":
		return httpx.Invalid("Isi API key.")
	}
	enabled, prio := true, 100
	if req.Enabled != nil {
		enabled = *req.Enabled
	}
	if req.Priority != nil {
		prio = max(0, min(*req.Priority, 9999))
	}
	var enc []byte
	if req.APIKey != "" {
		var err error
		if enc, err = security.Seal(s.Cfg.AppSecret, req.APIKey); err != nil {
			return err
		}
	}
	var id string
	if isNew {
		if err := s.DB.QueryRowContext(r.Context(), `INSERT INTO ai_connections(name, kind, base_url, api_key_enc, image_model, style, enabled, priority)
			VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id`, req.Name, req.Kind, req.BaseURL, enc, req.Model, req.Style, enabled, prio).Scan(&id); err != nil {
			return err
		}
		s.audit(r, "connection.create", id, map[string]any{"name": req.Name, "kind": req.Kind, "model": req.Model})
	} else {
		var err error
		if id, err = pathID(r, "id"); err != nil {
			return err
		}
		res, err := s.DB.ExecContext(r.Context(), `UPDATE ai_connections SET name=$2, kind=$3, base_url=$4, image_model=$5, style=$6,
			enabled=$7, priority=$8, api_key_enc=COALESCE($9, api_key_enc), updated_at=now() WHERE id=$1`,
			id, req.Name, req.Kind, req.BaseURL, req.Model, req.Style, enabled, prio, enc)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return httpx.ErrNotFound
		}
		s.audit(r, "connection.update", id, map[string]any{"name": req.Name, "model": req.Model, "enabled": enabled, "key_changed": enc != nil})
	}
	httpx.JSON(w, 200, map[string]any{"id": id})
	return nil
}

func (s *Server) adminDeleteConnection(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	res, err := s.DB.ExecContext(r.Context(), `DELETE FROM ai_connections WHERE id=$1`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.ErrNotFound
	}
	s.audit(r, "connection.delete", id, nil)
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

func (s *Server) connection(ctx context.Context, id string) (ai.Connection, error) {
	var c ai.Connection
	var enc []byte
	err := s.DB.QueryRowContext(ctx, `SELECT id, name, kind, base_url, api_key_enc, image_model, style FROM ai_connections WHERE id=$1`, id).
		Scan(&c.ID, &c.Name, &c.Kind, &c.BaseURL, &enc, &c.Model, &c.Style)
	if err != nil {
		return c, notFoundIf(err)
	}
	if c.APIKey, err = security.Open(s.Cfg.AppSecret, enc); err != nil {
		return c, httpx.Err(409, "key_unreadable", "API key koneksi ini tidak bisa dibuka (APP_SECRET berubah?). Isi ulang API key-nya.")
	}
	return c, nil
}

// adminTestConnection: memanggil GET /models provider dengan key tersimpan.
func (s *Server) adminTestConnection(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	c, err := s.connection(r.Context(), id)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	models, err := ai.ListModels(ctx, s.aiClient(), c)
	ok, msg := err == nil, ""
	if err != nil {
		msg = truncateErr(err)
		var ae *ai.APIError
		if errors.As(err, &ae) && (ae.Status == 401 || ae.Status == 403) {
			msg = "API key ditolak provider (" + itoa(ae.Status) + ")."
		}
	} else {
		found := false
		for _, m := range models {
			found = found || m.ID == c.Model
		}
		msg = "Tersambung, " + itoa(len(models)) + " model terbaca."
		if !found && len(models) > 0 {
			msg += " Model \"" + c.Model + "\" tidak ada di daftar provider — periksa ejaannya."
		}
	}
	s.DB.ExecContext(r.Context(), `UPDATE ai_connections SET last_test_at=now(), last_test_ok=$2, last_test_msg=$3 WHERE id=$1`, id, ok, msg)
	httpx.JSON(w, 200, map[string]any{"ok": ok, "message": msg})
	return nil
}

func (s *Server) adminConnectionModels(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	c, err := s.connection(r.Context(), id)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	models, err := ai.ListModels(ctx, s.aiClient(), c)
	if err != nil {
		return httpx.Err(502, "provider_error", "Daftar model tidak bisa diambil: "+truncateErr(err))
	}
	httpx.JSON(w, 200, map[string]any{"data": models})
	return nil
}

func (s *Server) adminGenerations(w http.ResponseWriter, r *http.Request) error {
	rows, err := s.DB.QueryContext(r.Context(), `SELECT g.id, g.mode, g.status, g.provider, g.model, g.error, g.note, g.duration_ms, g.created_at,
		u.name, u.handle FROM generations g JOIN users u ON u.id=g.user_id ORDER BY g.created_at DESC LIMIT 200`)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, mode, status, provider, model, msg, note, name, handle string
		var ms int
		var at time.Time
		if err := rows.Scan(&id, &mode, &status, &provider, &model, &msg, &note, &ms, &at, &name, &handle); err != nil {
			return err
		}
		out = append(out, map[string]any{"id": id, "mode": mode, "status": status, "provider": provider, "model": model, "error": msg,
			"note": note, "duration_ms": ms, "created_at": at, "user_name": name, "user_handle": handle})
	}
	httpx.JSON(w, 200, map[string]any{"data": out})
	return rows.Err()
}

func (s *Server) adminGetSettings(w http.ResponseWriter, r *http.Request) error {
	httpx.JSON(w, 200, map[string]any{"settings": s.settings(r.Context()), "default_prompt": sprite.DefaultPrompt})
	return nil
}

func (s *Server) adminPutSettings(w http.ResponseWriter, r *http.Request) error {
	st := s.settings(r.Context())
	if err := httpx.Decode(r, &st, 1<<16); err != nil {
		return err
	}
	if st.DailyGenerations < 0 || st.DailyGenerations > 100 {
		return httpx.Invalid("Jatah generate per hari harus 0–100.")
	}
	if st.MaxPets < 1 || st.MaxPets > 50 {
		return httpx.Invalid("Batas pet per pengguna harus 1–50.")
	}
	if len(st.Prompt) > 6000 {
		return httpx.Invalid("Prompt terlalu panjang (maksimal 6000 karakter).")
	}
	st.Prompt = strings.TrimSpace(st.Prompt)
	b, _ := json.Marshal(st)
	if _, err := s.DB.ExecContext(r.Context(), `INSERT INTO settings(key, value) VALUES('app', $1)
		ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value`, b); err != nil {
		return err
	}
	s.audit(r, "settings.update", "app", map[string]any{"registration_open": st.RegistrationOpen, "daily_generations": st.DailyGenerations, "max_pets": st.MaxPets})
	httpx.JSON(w, 200, map[string]any{"settings": st})
	return nil
}

func (s *Server) adminAudit(w http.ResponseWriter, r *http.Request) error {
	rows, err := s.DB.QueryContext(r.Context(), `SELECT l.id, l.action, l.target, l.meta, l.ip, l.created_at, COALESCE(a.email, '(dihapus)')
		FROM audit_log l LEFT JOIN admins a ON a.id=l.admin_id ORDER BY l.id DESC LIMIT 200`)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id int64
		var action, target, ip, email string
		var meta []byte
		var at time.Time
		if err := rows.Scan(&id, &action, &target, &meta, &ip, &at, &email); err != nil {
			return err
		}
		out = append(out, map[string]any{"id": id, "action": action, "target": target, "meta": json.RawMessage(meta), "ip": ip, "created_at": at, "admin": email})
	}
	httpx.JSON(w, 200, map[string]any{"data": out})
	return rows.Err()
}

// ---------------- akun admin (superadmin) ----------------

func (s *Server) adminAccounts(w http.ResponseWriter, r *http.Request) error {
	rows, err := s.DB.QueryContext(r.Context(), `SELECT id, email, name, super, disabled_at, last_login_at, created_at FROM admins ORDER BY created_at`)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, email, name string
		var super bool
		var dis, last sql.NullTime
		var at time.Time
		if err := rows.Scan(&id, &email, &name, &super, &dis, &last, &at); err != nil {
			return err
		}
		out = append(out, map[string]any{"id": id, "email": email, "name": name, "super": super, "disabled": dis.Valid, "last_login_at": nt(last), "created_at": at})
	}
	httpx.JSON(w, 200, map[string]any{"data": out})
	return rows.Err()
}

func (s *Server) adminCreateAccount(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Email    string `json:"email"`
		Name     string `json:"name"`
		Password string `json:"password"`
		Super    bool   `json:"super"`
	}
	if err := httpx.Decode(r, &req, 1<<12); err != nil {
		return err
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	if !emailRe.MatchString(req.Email) {
		return httpx.Invalid("Email tidak valid.")
	}
	if err := security.ValidatePassword(req.Password); err != nil {
		return httpx.Invalid("Password " + err.Error() + ".")
	}
	hash, err := security.HashPassword(req.Password)
	if err != nil {
		return err
	}
	var id string
	err = s.DB.QueryRowContext(r.Context(), `INSERT INTO admins(email, name, password_hash, super) VALUES($1,$2,$3,$4)
		ON CONFLICT DO NOTHING RETURNING id`, req.Email, clean(req.Name, 60), hash, req.Super).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return httpx.Err(409, "email_taken", "Email itu sudah dipakai akun admin lain.")
	}
	if err != nil {
		return err
	}
	s.audit(r, "account.create", id, map[string]any{"email": req.Email, "super": req.Super})
	httpx.JSON(w, 201, map[string]any{"id": id})
	return nil
}

func (s *Server) adminUpdateAccount(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Super    *bool `json:"super"`
		Disabled *bool `json:"disabled"`
	}
	if err := httpx.Decode(r, &req, 1<<12); err != nil {
		return err
	}
	if who(r).AdminID == id {
		return httpx.Invalid("Akun sendiri tidak bisa diubah dari sini.")
	}
	var exists bool
	if err := s.DB.QueryRowContext(r.Context(), `SELECT EXISTS(SELECT 1 FROM admins WHERE id=$1)`, id).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return httpx.ErrNotFound
	}
	if req.Super != nil {
		if _, err := s.DB.ExecContext(r.Context(), `UPDATE admins SET super=$2 WHERE id=$1`, id, *req.Super); err != nil {
			return err
		}
	}
	if req.Disabled != nil {
		if *req.Disabled {
			s.DB.ExecContext(r.Context(), `UPDATE admins SET disabled_at=COALESCE(disabled_at, now()) WHERE id=$1`, id)
			s.DB.ExecContext(r.Context(), `DELETE FROM admin_sessions WHERE admin_id=$1`, id)
		} else {
			s.DB.ExecContext(r.Context(), `UPDATE admins SET disabled_at=NULL WHERE id=$1`, id)
		}
	}
	s.audit(r, "account.update", id, map[string]any{"super": req.Super, "disabled": req.Disabled})
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}
