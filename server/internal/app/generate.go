package app

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/ai"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/httpx"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/security"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/sprite"
)

// Membuat pet dari foto. Dua cara:
//   - "ai"     : foto + contoh tata letak dikirim ke provider gambar yang diatur admin; hasilnya
//     dirapikan jadi sheet pixel art (sprite.Normalize).
//   - "manual" : pengguna menyalin prompt + mengunduh contoh tata letak, membuat gambarnya di
//     ChatGPT / alat lain, lalu mengunggah hasilnya ke sini untuk dirapikan.
//
// Foto pengguna hanya disimpan selama proses berjalan, lalu dihapus.

func (s *Server) generateRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/generate/info", s.user(s.generateInfo))
	mux.HandleFunc("GET /api/generate/guide.png", s.wrap(s.guideImage))
	mux.HandleFunc("POST /api/generate", s.user(s.startGeneration))
	mux.HandleFunc("POST /api/generate/manual", s.user(s.manualGeneration))
	mux.HandleFunc("GET /api/generate/{id}", s.user(s.getGeneration))
	mux.HandleFunc("GET /api/generate/{id}/sheet.png", s.user(s.generationSheet))
}

const guideTemplate = "oren"

func guidePNG() ([]byte, error) {
	b, _ := sprite.TemplatePNG(guideTemplate)
	return sprite.Guide(b)
}

func (s *Server) guideImage(w http.ResponseWriter, r *http.Request) error {
	g, err := guidePNG()
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	if r.URL.Query().Get("download") != "" {
		w.Header().Set("Content-Disposition", `attachment; filename="temani-tata-letak.png"`)
	}
	w.Write(g)
	return nil
}

func (s *Server) aiAvailable(ctx context.Context) bool {
	if s.Cfg.AIMock {
		return true
	}
	var n int
	s.DB.QueryRowContext(ctx, `SELECT count(*) FROM ai_connections WHERE enabled`).Scan(&n)
	return n > 0
}

func (s *Server) usedToday(ctx context.Context, user string) int {
	var n int
	s.DB.QueryRowContext(ctx, `SELECT count(*) FROM generations WHERE user_id=$1 AND mode='ai' AND status<>'failed'
		AND created_at > now() - interval '24 hours'`, user).Scan(&n)
	return n
}

func (s *Server) generateInfo(w http.ResponseWriter, r *http.Request) error {
	st := s.settings(r.Context())
	httpx.JSON(w, 200, map[string]any{
		"ai_available": s.aiAvailable(r.Context()) && st.DailyGenerations > 0,
		"daily_limit":  st.DailyGenerations,
		"used_today":   s.usedToday(r.Context(), who(r).UserID),
		"prompt":       sprite.BuildPrompt(st.Prompt, ""),
		"guide_url":    "/api/generate/guide.png",
		"frames":       sprite.Frames,
	})
	return nil
}

// readUpload: satu file gambar dari form multipart.
func readUpload(r *http.Request, field string, limit int64) ([]byte, string, error) {
	r.Body = http.MaxBytesReader(nil, r.Body, limit+1<<16)
	if err := r.ParseMultipartForm(limit); err != nil {
		return nil, "", httpx.Err(413, "too_large", fmt.Sprintf("File terlalu besar (maksimal %d MB).", limit>>20))
	}
	f, _, err := r.FormFile(field)
	if err != nil {
		return nil, "", httpx.Invalid("Pilih file gambarnya dulu.")
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, "", httpx.Err(413, "too_large", fmt.Sprintf("File terlalu besar (maksimal %d MB).", limit>>20))
	}
	mime := http.DetectContentType(data)
	if mime != "image/png" && mime != "image/jpeg" && mime != "image/webp" && mime != "image/gif" {
		return nil, "", httpx.Invalid("File harus berupa gambar PNG atau JPEG.")
	}
	return data, mime, nil
}

func (s *Server) startGeneration(w http.ResponseWriter, r *http.Request) error {
	me := who(r).UserID
	st := s.settings(r.Context())
	if !s.aiAvailable(r.Context()) || st.DailyGenerations <= 0 {
		return httpx.Err(409, "ai_unavailable", "Generate otomatis belum tersedia. Pakai cara manual: salin prompt, buat di ChatGPT, lalu unggah hasilnya.")
	}
	if used := s.usedToday(r.Context(), me); used >= st.DailyGenerations {
		return httpx.Err(429, "quota_exceeded", fmt.Sprintf("Jatah generate hari ini sudah habis (%d kali). Coba lagi besok, atau pakai cara manual.", st.DailyGenerations))
	}
	photo, mime, err := readUpload(r, "photo", 8<<20)
	if err != nil {
		return err
	}
	if mime == "image/webp" || mime == "image/gif" {
		return httpx.Invalid("Foto harus PNG atau JPEG.")
	}
	var id string
	if err := s.DB.QueryRowContext(r.Context(), `INSERT INTO generations(user_id, mode, photo, photo_mime, note) VALUES($1,'ai',$2,$3,$4) RETURNING id`,
		me, photo, mime, clean(r.FormValue("note"), 200)).Scan(&id); err != nil {
		return err
	}
	select {
	case s.wake <- struct{}{}:
	default:
	}
	httpx.JSON(w, 202, map[string]any{"id": id, "status": "queued"})
	return nil
}

// manualGeneration: gambar buatan pengguna (dari ChatGPT, dll.) → langsung dirapikan.
func (s *Server) manualGeneration(w http.ResponseWriter, r *http.Request) error {
	data, mime, err := readUpload(r, "image", 12<<20)
	if err != nil {
		return err
	}
	if mime == "image/webp" {
		return httpx.Invalid("Simpan gambarnya sebagai PNG atau JPEG dulu, lalu unggah lagi.")
	}
	sheet, err := sprite.NormalizeBytes(data)
	if err != nil {
		return httpx.Invalid("Gambar belum bisa dipakai: " + err.Error() + ".")
	}
	var id string
	if err := s.DB.QueryRowContext(r.Context(), `INSERT INTO generations(user_id, mode, status, result_sheet, finished_at)
		VALUES($1,'manual','done',$2,now()) RETURNING id`, who(r).UserID, sheet).Scan(&id); err != nil {
		return err
	}
	httpx.JSON(w, 201, map[string]any{"id": id, "status": "done", "sheet_url": "/api/generate/" + id + "/sheet.png"})
	return nil
}

func (s *Server) getGeneration(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	var status, mode, msg string
	if err := s.DB.QueryRowContext(r.Context(), `SELECT status, mode, error FROM generations WHERE id=$1 AND user_id=$2`, id, who(r).UserID).
		Scan(&status, &mode, &msg); err != nil {
		return notFoundIf(err)
	}
	out := map[string]any{"id": id, "status": status, "mode": mode}
	if status == "done" {
		out["sheet_url"] = "/api/generate/" + id + "/sheet.png"
	}
	if status == "failed" {
		out["error"] = "Generate gagal. Coba lagi, atau pakai cara manual."
	}
	httpx.JSON(w, 200, out)
	return nil
}

func (s *Server) generationSheet(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	var sheet []byte
	if err := s.DB.QueryRowContext(r.Context(), `SELECT result_sheet FROM generations WHERE id=$1 AND user_id=$2 AND status='done'`, id, who(r).UserID).
		Scan(&sheet); err != nil || len(sheet) == 0 {
		return httpx.ErrNotFound
	}
	servePNG(w, r, sheet)
	return nil
}

// ---------------- worker ----------------

// RunWorker mengerjakan antrean generate satu per satu sampai ctx selesai.
func (s *Server) RunWorker(ctx context.Context) {
	// pekerjaan yang terputus saat server berhenti tidak diulang otomatis (bisa menagih dua kali)
	s.DB.ExecContext(ctx, `UPDATE generations SET status='failed', error='server dimulai ulang saat proses berjalan', photo=NULL, finished_at=now() WHERE status='running'`)
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		for s.workOne(ctx) {
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-s.wake:
		}
	}
}

func (s *Server) connections(ctx context.Context) ([]ai.Connection, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT id, name, kind, base_url, api_key_enc, image_model, style FROM ai_connections
		WHERE enabled ORDER BY priority, created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ai.Connection
	for rows.Next() {
		var c ai.Connection
		var enc []byte
		if err := rows.Scan(&c.ID, &c.Name, &c.Kind, &c.BaseURL, &enc, &c.Model, &c.Style); err != nil {
			return nil, err
		}
		key, err := security.Open(s.Cfg.AppSecret, enc)
		if err != nil {
			log.Printf("koneksi AI %s: API key tidak bisa dibuka (APP_SECRET berubah?)", c.Name)
			continue
		}
		c.APIKey = key
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Server) aiClient() *http.Client {
	if s.AIHTTP != nil {
		return s.AIHTTP
	}
	return ai.NewClient(s.Cfg.AITimeout, s.Cfg.Env != "production")
}

func (s *Server) workOne(ctx context.Context) bool {
	var id, mime, note string
	var photo []byte
	err := s.DB.QueryRowContext(ctx, `UPDATE generations SET status='running' WHERE id = (
		SELECT id FROM generations WHERE status='queued' ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED)
		RETURNING id, photo, photo_mime, note`).Scan(&id, &photo, &mime, &note)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) && ctx.Err() == nil {
			log.Printf("worker generate: %v", err)
		}
		return false
	}
	start := time.Now()
	sheet, conn, err := s.generateSheet(ctx, photo, mime, note)
	ms := int(time.Since(start).Milliseconds())
	// simpan dengan konteks sendiri: hasil tidak boleh hilang hanya karena server sedang berhenti
	save, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	var connID any
	if conn.ID != "" {
		connID = conn.ID
	}
	if err != nil {
		log.Printf("generate %s gagal: %v", id, err)
		s.DB.ExecContext(save, `UPDATE generations SET status='failed', error=$2, photo=NULL, connection_id=$3, provider=$4, model=$5,
			duration_ms=$6, finished_at=now() WHERE id=$1`, id, truncateErr(err), connID, conn.Name, conn.Model, ms)
		return true
	}
	s.DB.ExecContext(save, `UPDATE generations SET status='done', result_sheet=$2, photo=NULL, connection_id=$3, provider=$4, model=$5,
		duration_ms=$6, finished_at=now() WHERE id=$1`, id, sheet, connID, conn.Name, conn.Model, ms)
	return true
}

func truncateErr(err error) string {
	s := err.Error()
	if len(s) > 600 {
		s = s[:600]
	}
	return s
}

// generateSheet mencoba tiap koneksi aktif menurut prioritas sampai ada yang berhasil.
func (s *Server) generateSheet(ctx context.Context, photo []byte, mime, note string) ([]byte, ai.Connection, error) {
	guide, err := guidePNG()
	if err != nil {
		return nil, ai.Connection{}, err
	}
	if s.Cfg.AIMock { // dev/CI: "hasil AI" = contoh tata letak dari template lain
		b, _ := sprite.TemplatePNG("rubah")
		g, _ := sprite.Guide(b)
		sheet, err := sprite.NormalizeBytes(g)
		return sheet, ai.Connection{Name: "mock", Model: "mock"}, err
	}
	conns, err := s.connections(ctx)
	if err != nil {
		return nil, ai.Connection{}, err
	}
	if len(conns) == 0 {
		return nil, ai.Connection{}, errors.New("tidak ada koneksi AI yang aktif")
	}
	prompt := sprite.BuildPrompt(s.settings(ctx).Prompt, note)
	ext := "jpg"
	if mime == "image/png" {
		ext = "png"
	}
	refs := []ai.Ref{{Name: "photo." + ext, Mime: mime, Data: photo}, {Name: "layout.png", Mime: "image/png", Data: guide}}
	var errs []string
	last := conns[0]
	for _, c := range conns {
		last = c
		cctx, cancel := context.WithTimeout(ctx, s.Cfg.AITimeout)
		img, err := ai.Generate(cctx, s.aiClient(), c, prompt, refs)
		cancel()
		if err == nil {
			var sheet []byte
			if sheet, err = sprite.NormalizeBytes(img.Data); err == nil {
				return sheet, c, nil
			}
		}
		errs = append(errs, c.Name+": "+err.Error())
	}
	return nil, last, errors.New(strings.Join(errs, " | "))
}
