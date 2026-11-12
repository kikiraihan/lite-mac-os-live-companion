// Package app: server HTTP Temani — API web pengguna (/api/…), API admin (/api/admin/…,
// sesi & cookie terpisah), API aplikasi Mac (/api/app/…, token perangkat), dan SPA Vue.
package app

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/config"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/httpx"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/security"
)

type Server struct {
	DB  *sql.DB
	Cfg config.Config
	// AIHTTP: klien HTTP ke provider AI (bisa diganti di test).
	AIHTTP *http.Client

	ipLimit    *security.Limiter
	authLimit  *security.Limiter
	loginLimit *security.Limiter
	wake       chan struct{} // membangunkan worker generate
}

func New(conn *sql.DB, cfg config.Config) *Server {
	return &Server{
		DB:         conn,
		Cfg:        cfg,
		ipLimit:    security.NewLimiter(600, 300),
		authLimit:  security.NewLimiter(20, 10),
		loginLimit: security.NewLimiter(2, 8),
		wake:       make(chan struct{}, 1),
	}
}

// Principal: siapa yang memanggil. Tepat satu dari UserID / AdminID yang terisi.
type Principal struct {
	UserID   string
	DeviceID string // terisi kalau lewat token aplikasi Mac
	AdminID  string
	Super    bool
	Name     string
	Handle   string
	Email    string
}

type ctxKey struct{}

func who(r *http.Request) *Principal {
	p, _ := r.Context().Value(ctxKey{}).(*Principal)
	if p == nil {
		return &Principal{}
	}
	return p
}

func withPrincipal(r *http.Request, p *Principal) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), ctxKey{}, p))
}

// Handler: handler yang mengembalikan error (ditulis sebagai JSON standar).
type Handler func(w http.ResponseWriter, r *http.Request) error

func (s *Server) wrap(h Handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := h(w, r); err != nil {
			httpx.Error(w, r, err)
		}
	}
}

// limited: pembatas ketat per IP untuk endpoint masuk / daftar / tautan perangkat.
func (s *Server) limited(h Handler) Handler {
	return func(w http.ResponseWriter, r *http.Request) error {
		if !s.authLimit.Allow(httpx.ClientIP(r, s.Cfg.TrustProxy)) {
			return httpx.Err(429, "rate_limited", "Terlalu banyak percobaan. Tunggu sebentar, lalu coba lagi.")
		}
		return h(w, r)
	}
}

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// pathID: id dari path harus UUID; selain itu langsung 404 (tidak sampai ke SQL).
func pathID(r *http.Request, name string) (string, error) {
	id := r.PathValue(name)
	if !uuidRe.MatchString(id) {
		return "", httpx.ErrNotFound
	}
	return id, nil
}

func notFoundIf(err error) error {
	if errors.Is(err, sql.ErrNoRows) {
		return httpx.ErrNotFound
	}
	return err
}

func nt(t sql.NullTime) any {
	if t.Valid {
		return t.Time
	}
	return nil
}

func (s *Server) secureCookies() bool { return strings.HasPrefix(s.Cfg.PublicURL, "https://") }

// cookieName: di HTTPS cookie sesi memakai awalan __Host- (terkunci ke host ini, wajib Secure).
func (s *Server) cookieName(base string) string {
	if s.secureCookies() {
		return "__Host-" + base
	}
	return base
}

// checkCSRF: double-submit — header X-CSRF-Token harus sama dengan cookie CSRF.
func checkCSRF(r *http.Request, cookie string) error {
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		return nil
	}
	c, err := r.Cookie(cookie)
	if err != nil || c.Value == "" || r.Header.Get("X-CSRF-Token") != c.Value {
		return httpx.ErrCSRF
	}
	return nil
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	s.authRoutes(mux)
	s.petRoutes(mux)
	s.friendRoutes(mux)
	s.generateRoutes(mux)
	s.deviceRoutes(mux)
	s.adminAuthRoutes(mux)
	s.adminRoutes(mux)

	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if err := s.DB.PingContext(ctx); err != nil {
			httpx.JSON(w, 503, map[string]any{"status": "db_down"})
			return
		}
		httpx.JSON(w, 200, map[string]any{"status": "ok", "time": time.Now().UTC()})
	})
	mux.HandleFunc("GET /api/config", func(w http.ResponseWriter, r *http.Request) {
		st := s.settings(r.Context())
		httpx.JSON(w, 200, map[string]any{"registration_open": st.RegistrationOpen, "mac_download_url": s.Cfg.MacDownloadURL})
	})
	mux.Handle("/", s.spa())
	return s.middleware(mux)
}

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		h.Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; frame-ancestors 'none'")
		if s.secureCookies() {
			h.Set("Strict-Transport-Security", "max-age=31536000")
		}
		if strings.HasPrefix(r.URL.Path, "/api/") && !s.ipLimit.Allow(httpx.ClientIP(r, s.Cfg.TrustProxy)) {
			httpx.Error(w, r, httpx.Err(429, "rate_limited", "Terlalu banyak permintaan. Tunggu sebentar."))
			return
		}
		next.ServeHTTP(w, r)
	})
}

// spa menyajikan hasil build Vue; path yang tidak ada → index.html (history mode).
func (s *Server) spa() http.Handler {
	fs := http.FileServer(http.Dir(s.Cfg.WebDir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			httpx.Error(w, r, httpx.ErrNotFound)
			return
		}
		p := filepath.Join(s.Cfg.WebDir, filepath.Clean("/"+r.URL.Path))
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			if strings.HasPrefix(r.URL.Path, "/assets/") {
				w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			}
			fs.ServeHTTP(w, r)
			return
		}
		index := filepath.Join(s.Cfg.WebDir, "index.html")
		if _, err := os.Stat(index); err != nil {
			http.Error(w, "Frontend belum di-build (npm run build di web/).", 503)
			return
		}
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeFile(w, r, index)
	})
}

// servePNG: sheet pet — kecil dan versinya ada di URL (?v=), jadi boleh di-cache lama.
func servePNG(w http.ResponseWriter, r *http.Request, data []byte) {
	w.Header().Set("Content-Type", "image/png")
	if r.URL.Query().Get("v") != "" {
		w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	} else {
		w.Header().Set("Cache-Control", "private, no-cache")
	}
	w.Write(data)
}

// ---------------- pengaturan aplikasi (diubah dari admin) ----------------

type Settings struct {
	// RegistrationOpen=false → daftar hanya lewat tautan undangan teman.
	RegistrationOpen bool `json:"registration_open"`
	// DailyGenerations: jatah generate AI per pengguna per hari (0 = dimatikan).
	DailyGenerations int `json:"daily_generations"`
	MaxPets          int `json:"max_pets"`
	// Prompt: templat prompt generate; kosong = bawaan (sprite.DefaultPrompt).
	Prompt string `json:"prompt"`
}

func defaultSettings() Settings {
	return Settings{RegistrationOpen: true, DailyGenerations: 3, MaxPets: 12}
}

func (s *Server) settings(ctx context.Context) Settings {
	st := defaultSettings()
	var raw []byte
	if err := s.DB.QueryRowContext(ctx, `SELECT value FROM settings WHERE key='app'`).Scan(&raw); err == nil {
		json.Unmarshal(raw, &st)
	}
	return st
}

func clean(s string, max int) string {
	s = strings.TrimSpace(strings.Join(strings.Fields(s), " "))
	if r := []rune(s); len(r) > max {
		s = string(r[:max])
	}
	return s
}
