package app

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/httpx"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/security"
)

// ---------------- autentikasi admin ----------------
//
// Admin sepenuhnya terpisah dari pengguna biasa (pola Pancar):
//   - akun di tabel `admins`, sesi di `admin_sessions`;
//   - cookie sesi & CSRF sendiri, SameSite=Strict, umur maksimal 12 jam;
//   - endpoint masuk sendiri (/api/admin/auth/*), tidak ada pendaftaran publik — admin pertama
//     dibuat dari CLI (`make admin`), berikutnya oleh superadmin;
//   - admin dan pengguna dengan email yang sama tetap dua akun berbeda. Sesi pengguna tidak
//     memberi akses ke /api/admin, dan sebaliknya.

const (
	adminSessionCookie = "temani_admin_session"
	adminCSRFCookie    = "temani_admin_csrf"
)

func (s *Server) adminAuthRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/admin/auth/login", s.wrap(s.limited(s.adminLogin)))
	mux.HandleFunc("POST /api/admin/auth/logout", s.admin(s.adminLogout))
	mux.HandleFunc("GET /api/admin/auth/me", s.admin(s.adminMe))
	mux.HandleFunc("POST /api/admin/auth/password", s.admin(s.adminChangePassword))
}

// admin: wajib sesi admin + CSRF admin.
func (s *Server) admin(h Handler) http.HandlerFunc {
	return s.wrap(func(w http.ResponseWriter, r *http.Request) error {
		c, err := r.Cookie(s.cookieName(adminSessionCookie))
		if err != nil || len(c.Value) < 20 {
			return httpx.ErrUnauth
		}
		p := &Principal{}
		var disabled sql.NullTime
		err = s.DB.QueryRowContext(r.Context(), `SELECT a.id, a.email, a.name, a.super, a.disabled_at FROM admin_sessions s
			JOIN admins a ON a.id=s.admin_id WHERE s.id_hash=$1 AND s.expires_at > now()`, security.SHA256(c.Value)).
			Scan(&p.AdminID, &p.Email, &p.Name, &p.Super, &disabled)
		if err != nil || disabled.Valid {
			return httpx.ErrUnauth
		}
		if err := checkCSRF(r, adminCSRFCookie); err != nil {
			return err
		}
		return h(w, withPrincipal(r, p))
	})
}

// superAdmin: hanya superadmin (mengelola akun admin).
func (s *Server) superAdmin(h Handler) http.HandlerFunc {
	return s.admin(func(w http.ResponseWriter, r *http.Request) error {
		if !who(r).Super {
			return httpx.ErrForbidden
		}
		return h(w, r)
	})
}

func (s *Server) audit(r *http.Request, action, target string, meta map[string]any) {
	b, _ := json.Marshal(meta)
	if meta == nil {
		b = []byte("{}")
	}
	s.DB.ExecContext(r.Context(), `INSERT INTO audit_log(admin_id, action, target, meta, ip) VALUES($1,$2,$3,$4,$5)`,
		who(r).AdminID, action, target, b, httpx.ClientIP(r, s.Cfg.TrustProxy))
}

func adminJSON(p *Principal) map[string]any {
	return map[string]any{"admin": map[string]any{"id": p.AdminID, "email": p.Email, "name": p.Name, "super": p.Super}}
}

func (s *Server) adminLogin(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := httpx.Decode(r, &req, 1<<14); err != nil {
		return err
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	if !s.loginLimit.Allow("admin-login:" + req.Email) {
		return httpx.Err(429, "too_many_attempts", "Terlalu banyak percobaan masuk. Coba lagi beberapa menit lagi.")
	}
	p := &Principal{Email: req.Email}
	var hash string
	var disabled sql.NullTime
	err := s.DB.QueryRowContext(r.Context(), `SELECT id, name, super, password_hash, disabled_at FROM admins WHERE lower(email)=$1`, req.Email).
		Scan(&p.AdminID, &p.Name, &p.Super, &hash, &disabled)
	if err != nil {
		security.DummyCheck(req.Password)
		return httpx.Err(401, "invalid_credentials", "Email atau password salah.")
	}
	if !security.CheckPassword(hash, req.Password) || disabled.Valid {
		return httpx.Err(401, "invalid_credentials", "Email atau password salah.")
	}
	token := security.RandomToken(32)
	exp := time.Now().Add(min(s.Cfg.SessionTTL, 12*time.Hour))
	ua := r.UserAgent()
	if len(ua) > 300 {
		ua = ua[:300]
	}
	if _, err := s.DB.ExecContext(r.Context(), `INSERT INTO admin_sessions(id_hash, admin_id, ip, user_agent, expires_at) VALUES($1,$2,$3,$4,$5)`,
		security.SHA256(token), p.AdminID, httpx.ClientIP(r, s.Cfg.TrustProxy), ua, exp); err != nil {
		return err
	}
	s.DB.ExecContext(r.Context(), `DELETE FROM admin_sessions WHERE expires_at < now()`)
	s.DB.ExecContext(r.Context(), `UPDATE admins SET last_login_at=now() WHERE id=$1`, p.AdminID)
	http.SetCookie(w, &http.Cookie{Name: s.cookieName(adminSessionCookie), Value: token, Path: "/", Expires: exp, HttpOnly: true,
		Secure: s.secureCookies(), SameSite: http.SameSiteStrictMode})
	csrf := security.RandomToken(24)
	http.SetCookie(w, &http.Cookie{Name: adminCSRFCookie, Value: csrf, Path: "/", Expires: exp,
		Secure: s.secureCookies(), SameSite: http.SameSiteStrictMode})
	s.audit(withPrincipal(r, p), "admin.login", p.AdminID, nil)
	out := adminJSON(p)
	out["csrf_token"] = csrf
	httpx.JSON(w, 200, out)
	return nil
}

func (s *Server) adminLogout(w http.ResponseWriter, r *http.Request) error {
	if c, err := r.Cookie(s.cookieName(adminSessionCookie)); err == nil {
		s.DB.ExecContext(r.Context(), `DELETE FROM admin_sessions WHERE id_hash=$1`, security.SHA256(c.Value))
	}
	for _, n := range []string{s.cookieName(adminSessionCookie), adminCSRFCookie} {
		http.SetCookie(w, &http.Cookie{Name: n, Value: "", Path: "/", MaxAge: -1, Secure: s.secureCookies()})
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

func (s *Server) adminMe(w http.ResponseWriter, r *http.Request) error {
	out := adminJSON(who(r))
	if c, err := r.Cookie(adminCSRFCookie); err == nil {
		out["csrf_token"] = c.Value
	}
	httpx.JSON(w, 200, out)
	return nil
}

func (s *Server) adminChangePassword(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Current string `json:"current_password"`
		New     string `json:"new_password"`
	}
	if err := httpx.Decode(r, &req, 1<<12); err != nil {
		return err
	}
	p := who(r)
	var hash string
	if err := s.DB.QueryRowContext(r.Context(), `SELECT password_hash FROM admins WHERE id=$1`, p.AdminID).Scan(&hash); err != nil {
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
	if _, err := s.DB.ExecContext(r.Context(), `UPDATE admins SET password_hash=$2 WHERE id=$1`, p.AdminID, nh); err != nil {
		return err
	}
	if c, err := r.Cookie(s.cookieName(adminSessionCookie)); err == nil {
		s.DB.ExecContext(r.Context(), `DELETE FROM admin_sessions WHERE admin_id=$1 AND id_hash<>$2`, p.AdminID, security.SHA256(c.Value))
	}
	s.audit(r, "admin.password_changed", p.AdminID, nil)
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

// CreateAdmin dipakai CLI (`server admin:create`) untuk membuat / mereset superadmin.
func (s *Server) CreateAdmin(r *http.Request, email, password, name string) error {
	email = strings.ToLower(strings.TrimSpace(email))
	if !emailRe.MatchString(email) {
		return errors.New("email tidak valid")
	}
	if err := security.ValidatePassword(password); err != nil {
		return errors.New("password " + err.Error())
	}
	hash, err := security.HashPassword(password)
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(r.Context(), `INSERT INTO admins(email, name, password_hash, super) VALUES($1,$2,$3,true)
		ON CONFLICT (lower(email)) DO UPDATE SET password_hash=EXCLUDED.password_hash, super=true, disabled_at=NULL`, email, name, hash)
	return err
}
