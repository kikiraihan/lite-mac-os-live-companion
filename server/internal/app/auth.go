package app

import (
	"database/sql"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/httpx"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/security"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/sprite"
)

const (
	sessionCookie = "temani_session"
	csrfCookie    = "temani_csrf"
)

var (
	emailRe  = regexp.MustCompile(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)
	handleRe = regexp.MustCompile(`^[a-z0-9_]{3,20}$`)
)

func (s *Server) authRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/auth/register", s.wrap(s.limited(s.register)))
	mux.HandleFunc("POST /api/auth/login", s.wrap(s.limited(s.login)))
	mux.HandleFunc("POST /api/auth/logout", s.user(s.logout))
	mux.HandleFunc("GET /api/auth/me", s.user(s.me))
	mux.HandleFunc("PATCH /api/auth/me", s.user(s.updateMe))
	mux.HandleFunc("POST /api/auth/password", s.user(s.changePassword))
}

// user: wajib sesi pengguna (cookie) + CSRF. Sesi admin tidak berlaku di sini.
func (s *Server) user(h Handler) http.HandlerFunc {
	return s.wrap(func(w http.ResponseWriter, r *http.Request) error {
		c, err := r.Cookie(s.cookieName(sessionCookie))
		if err != nil || len(c.Value) < 20 {
			return httpx.ErrUnauth
		}
		p := &Principal{}
		var disabled sql.NullTime
		err = s.DB.QueryRowContext(r.Context(), `SELECT u.id, u.name, u.handle, u.email, u.disabled_at
			FROM sessions s JOIN users u ON u.id = s.user_id
			WHERE s.id_hash=$1 AND s.expires_at > now()`, security.SHA256(c.Value)).
			Scan(&p.UserID, &p.Name, &p.Handle, &p.Email, &disabled)
		if err != nil || disabled.Valid {
			return httpx.ErrUnauth
		}
		if err := checkCSRF(r, csrfCookie); err != nil {
			return err
		}
		return h(w, withPrincipal(r, p))
	})
}

func (s *Server) startSession(w http.ResponseWriter, r *http.Request, userID string) (string, error) {
	token := security.RandomToken(32)
	exp := time.Now().Add(s.Cfg.SessionTTL)
	ua := r.UserAgent()
	if len(ua) > 300 {
		ua = ua[:300]
	}
	if _, err := s.DB.ExecContext(r.Context(), `INSERT INTO sessions(id_hash, user_id, ip, user_agent, expires_at) VALUES($1,$2,$3,$4,$5)`,
		security.SHA256(token), userID, httpx.ClientIP(r, s.Cfg.TrustProxy), ua, exp); err != nil {
		return "", err
	}
	s.DB.ExecContext(r.Context(), `DELETE FROM sessions WHERE expires_at < now()`)
	s.DB.ExecContext(r.Context(), `UPDATE users SET last_seen_at=now() WHERE id=$1`, userID)
	// Lax: tautan undangan / hubungkan Mac yang dibuka dari luar tetap membawa sesi.
	http.SetCookie(w, &http.Cookie{Name: s.cookieName(sessionCookie), Value: token, Path: "/", Expires: exp, HttpOnly: true,
		Secure: s.secureCookies(), SameSite: http.SameSiteLaxMode})
	csrf := security.RandomToken(24)
	http.SetCookie(w, &http.Cookie{Name: csrfCookie, Value: csrf, Path: "/", Expires: exp,
		Secure: s.secureCookies(), SameSite: http.SameSiteLaxMode})
	return csrf, nil
}

func (s *Server) meData(r *http.Request, userID string) (map[string]any, error) {
	var email, name, handle string
	var created time.Time
	if err := s.DB.QueryRowContext(r.Context(), `SELECT email, name, handle, created_at FROM users WHERE id=$1`, userID).
		Scan(&email, &name, &handle, &created); err != nil {
		return nil, err
	}
	return map[string]any{"user": map[string]any{"id": userID, "email": email, "name": name, "handle": handle, "created_at": created}}, nil
}

func (s *Server) register(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Email    string `json:"email"`
		Name     string `json:"name"`
		Handle   string `json:"handle"`
		Password string `json:"password"`
		Invite   string `json:"invite"`
		Template string `json:"template"`
	}
	if err := httpx.Decode(r, &req, 1<<14); err != nil {
		return err
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	req.Name = clean(req.Name, 40)
	req.Handle = strings.ToLower(strings.TrimSpace(req.Handle))
	req.Invite = strings.ToUpper(strings.TrimSpace(req.Invite))
	switch {
	case !emailRe.MatchString(req.Email) || len(req.Email) > 200:
		return httpx.Invalid("Email tidak valid.")
	case req.Name == "":
		return httpx.Invalid("Isi nama panggilanmu.")
	case !handleRe.MatchString(req.Handle):
		return httpx.Invalid("Nama pengguna 3–20 karakter: huruf kecil, angka, atau garis bawah.")
	}
	if err := security.ValidatePassword(req.Password); err != nil {
		return httpx.Invalid("Password " + err.Error() + ".")
	}
	var inviter string
	if req.Invite != "" {
		s.DB.QueryRowContext(r.Context(), `SELECT from_user FROM friend_invites WHERE code=$1 AND expires_at > now()`, req.Invite).Scan(&inviter)
	}
	if !s.settings(r.Context()).RegistrationOpen && inviter == "" {
		return httpx.Err(403, "registration_closed", "Pendaftaran sedang ditutup. Minta tautan undangan dari teman yang sudah punya akun.")
	}
	hash, err := security.HashPassword(req.Password)
	if err != nil {
		return err
	}
	var id string
	err = s.DB.QueryRowContext(r.Context(), `INSERT INTO users(email, name, handle, password_hash) VALUES($1,$2,$3,$4)
		ON CONFLICT DO NOTHING RETURNING id`, req.Email, req.Name, req.Handle, hash).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		var n int
		s.DB.QueryRowContext(r.Context(), `SELECT count(*) FROM users WHERE lower(handle)=$1`, req.Handle).Scan(&n)
		if n > 0 {
			return httpx.Err(409, "handle_taken", "Nama pengguna itu sudah dipakai. Coba yang lain.")
		}
		return httpx.Err(409, "email_taken", "Email itu sudah punya akun. Masuk saja.")
	}
	if err != nil {
		return err
	}
	// pet pertama dari template yang dipilih saat daftar
	if tpl, ok := sprite.FindTemplate(req.Template); ok {
		png, _ := sprite.TemplatePNG(tpl.ID)
		s.DB.ExecContext(r.Context(), `INSERT INTO pets(owner_id, name, sheet, origin) VALUES($1,$2,$3,'template')`, id, tpl.DefaultName, png)
	}
	if inviter != "" {
		s.befriend(r.Context(), id, inviter)
		s.DB.ExecContext(r.Context(), `UPDATE friend_invites SET uses=uses+1 WHERE code=$1`, req.Invite)
	}
	csrf, err := s.startSession(w, r, id)
	if err != nil {
		return err
	}
	me, err := s.meData(r, id)
	if err != nil {
		return err
	}
	me["csrf_token"] = csrf
	httpx.JSON(w, 201, me)
	return nil
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := httpx.Decode(r, &req, 1<<14); err != nil {
		return err
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	if !s.loginLimit.Allow("login:" + req.Email) {
		return httpx.Err(429, "too_many_attempts", "Terlalu banyak percobaan masuk. Coba lagi beberapa menit lagi.")
	}
	var id, hash string
	var disabled sql.NullTime
	err := s.DB.QueryRowContext(r.Context(), `SELECT id, password_hash, disabled_at FROM users WHERE lower(email)=$1`, req.Email).
		Scan(&id, &hash, &disabled)
	if err != nil {
		security.DummyCheck(req.Password)
		return httpx.Err(401, "invalid_credentials", "Email atau password salah.")
	}
	if !security.CheckPassword(hash, req.Password) {
		return httpx.Err(401, "invalid_credentials", "Email atau password salah.")
	}
	if disabled.Valid {
		return httpx.Err(403, "account_disabled", "Akun ini dinonaktifkan. Hubungi admin.")
	}
	csrf, err := s.startSession(w, r, id)
	if err != nil {
		return err
	}
	me, err := s.meData(r, id)
	if err != nil {
		return err
	}
	me["csrf_token"] = csrf
	httpx.JSON(w, 200, me)
	return nil
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) error {
	if c, err := r.Cookie(s.cookieName(sessionCookie)); err == nil {
		s.DB.ExecContext(r.Context(), `DELETE FROM sessions WHERE id_hash=$1`, security.SHA256(c.Value))
	}
	for _, n := range []string{s.cookieName(sessionCookie), csrfCookie} {
		http.SetCookie(w, &http.Cookie{Name: n, Value: "", Path: "/", MaxAge: -1, Secure: s.secureCookies()})
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) error {
	me, err := s.meData(r, who(r).UserID)
	if err != nil {
		return err
	}
	if c, err := r.Cookie(csrfCookie); err == nil {
		me["csrf_token"] = c.Value
	}
	httpx.JSON(w, 200, me)
	return nil
}

func (s *Server) updateMe(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Name   *string `json:"name"`
		Handle *string `json:"handle"`
	}
	if err := httpx.Decode(r, &req, 1<<12); err != nil {
		return err
	}
	p := who(r)
	if req.Name != nil {
		n := clean(*req.Name, 40)
		if n == "" {
			return httpx.Invalid("Nama tidak boleh kosong.")
		}
		if _, err := s.DB.ExecContext(r.Context(), `UPDATE users SET name=$2 WHERE id=$1`, p.UserID, n); err != nil {
			return err
		}
	}
	if req.Handle != nil {
		h := strings.ToLower(strings.TrimSpace(*req.Handle))
		if !handleRe.MatchString(h) {
			return httpx.Invalid("Nama pengguna 3–20 karakter: huruf kecil, angka, atau garis bawah.")
		}
		res, err := s.DB.ExecContext(r.Context(), `UPDATE users SET handle=$2 WHERE id=$1
			AND NOT EXISTS (SELECT 1 FROM users WHERE lower(handle)=$2 AND id<>$1)`, p.UserID, h)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return httpx.Err(409, "handle_taken", "Nama pengguna itu sudah dipakai. Coba yang lain.")
		}
	}
	return s.me(w, r)
}

func (s *Server) changePassword(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Current string `json:"current_password"`
		New     string `json:"new_password"`
	}
	if err := httpx.Decode(r, &req, 1<<12); err != nil {
		return err
	}
	p := who(r)
	var hash string
	if err := s.DB.QueryRowContext(r.Context(), `SELECT password_hash FROM users WHERE id=$1`, p.UserID).Scan(&hash); err != nil {
		return err
	}
	if !security.CheckPassword(hash, req.Current) {
		return httpx.Err(401, "invalid_credentials", "Password lama salah.")
	}
	if err := security.ValidatePassword(req.New); err != nil {
		return httpx.Invalid("Password baru " + err.Error() + ".")
	}
	nh, err := security.HashPassword(req.New)
	if err != nil {
		return err
	}
	if _, err := s.DB.ExecContext(r.Context(), `UPDATE users SET password_hash=$2 WHERE id=$1`, p.UserID, nh); err != nil {
		return err
	}
	// sesi lain (browser lain) dikeluarkan; sesi ini tetap
	if c, err := r.Cookie(s.cookieName(sessionCookie)); err == nil {
		s.DB.ExecContext(r.Context(), `DELETE FROM sessions WHERE user_id=$1 AND id_hash<>$2`, p.UserID, security.SHA256(c.Value))
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}
