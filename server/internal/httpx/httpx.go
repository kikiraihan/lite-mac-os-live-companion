// Package httpx: bentuk respons JSON & error yang sama untuk semua endpoint.
package httpx

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
)

// AppError: error yang aman ditampilkan ke pengguna.
type AppError struct {
	Status  int
	Code    string
	Message string
}

func (e *AppError) Error() string { return e.Message }

func Err(status int, code, msg string) *AppError { return &AppError{status, code, msg} }

var (
	ErrUnauth    = Err(401, "unauthenticated", "Masuk dulu untuk melanjutkan.")
	ErrForbidden = Err(403, "forbidden", "Kamu tidak punya akses ke sini.")
	ErrNotFound  = Err(404, "not_found", "Tidak ditemukan.")
	ErrCSRF      = Err(403, "csrf", "Sesi halaman ini sudah usang. Muat ulang halaman, lalu coba lagi.")
)

func Invalid(msg string) *AppError { return Err(422, "validation_failed", msg) }

func JSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func Error(w http.ResponseWriter, r *http.Request, err error) {
	var ae *AppError
	if errors.As(err, &ae) {
		JSON(w, ae.Status, map[string]any{"error": map[string]any{"code": ae.Code, "message": ae.Message}})
		return
	}
	log.Printf("ERROR %s %s: %v", r.Method, r.URL.Path, err)
	JSON(w, 500, map[string]any{"error": map[string]any{"code": "internal", "message": "Ada masalah di server. Coba lagi sebentar."}})
}

// Decode membaca body JSON dengan batas ukuran.
func Decode(r *http.Request, v any, limit int64) error {
	body, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil {
		return Invalid("Permintaan tidak bisa dibaca.")
	}
	if int64(len(body)) > limit {
		return Err(413, "too_large", "Data yang dikirim terlalu besar.")
	}
	if err := json.Unmarshal(body, v); err != nil {
		return Invalid("Format permintaan tidak valid.")
	}
	return nil
}

func ClientIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		if v := r.Header.Get("CF-Connecting-IP"); v != "" {
			return v
		}
		if v := r.Header.Get("X-Forwarded-For"); v != "" {
			return strings.TrimSpace(strings.Split(v, ",")[0])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
