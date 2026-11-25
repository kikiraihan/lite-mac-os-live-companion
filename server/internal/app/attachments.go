package app

import (
	"context"
	"database/sql"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/httpx"
)

// Lampiran di obrolan (gambar / file) dari aplikasi Mac. Aturannya:
//
//	biasa         tersimpan di server paling lama sehari (attachTTL), lalu dihapus otomatis (RunCleanup);
//	              pengirim dan penerima boleh mengunduhnya berkali-kali selama masih ada.
//	sekali lihat  ("once"), seperti WhatsApp: hanya penerima yang bisa membuka, dan hanya sekali —
//	              datanya dihapus dari server di permintaan unduh yang sama. Belum dibuka dalam sehari → ikut dihapus.
//
// Isi file hanya di tabel message_files; keterangannya (nama, ukuran, jenis) tetap di messages supaya
// obrolan bisa menulis "sudah dibuka" / "sudah dihapus". Kolom text berisi label ("📷 Foto") untuk aplikasi lama
// dan balon kata pet. Penerima diberi tahu lewat kabar "message" biasa; saat pesan sekali lihat dibuka,
// kedua pihak mendapat kabar "file_opened".

const (
	maxAttachment = 10 << 20       // 10 MB per file
	maxPending    = 100 << 20      // total lampiran milik satu pengirim yang masih tersimpan di server
	attachTTL     = 24 * time.Hour // masa simpan lampiran
)

func (s *Server) attachmentRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/app/messages/{id}/files", s.device(s.appSendFile))
	mux.HandleFunc("GET /api/app/messages/{id}/files/{msg}", s.device(s.appGetFile))
}

// attachment: keterangan lampiran sebuah pesan (nil = pesan biasa)
type attachment struct {
	Kind      string
	Name      string
	Mime      string
	Size      int
	Once      bool
	ExpiresAt time.Time
	Opened    bool // sekali lihat: sudah dibuka penerimanya
	Available bool // isinya masih ada di server
}

func (a *attachment) json() map[string]any {
	return map[string]any{"kind": a.Kind, "name": a.Name, "mime": a.Mime, "size": a.Size, "once": a.Once,
		"expires_at": a.ExpiresAt, "opened": a.Opened, "available": a.Available && time.Now().Before(a.ExpiresAt)}
}

// withAttachment: tambahkan "attachment" ke JSON pesan (kalau ada)
func withAttachment(m map[string]any, a *attachment) map[string]any {
	if a != nil {
		m["attachment"] = a.json()
	}
	return m
}

// attachLabel: isi kolom text untuk pesan lampiran (aplikasi lama, balon kata pet, daftar belum dibaca)
func attachLabel(kind, name string, once bool) string {
	switch {
	case once && kind == "image":
		return "📷 Foto sekali lihat"
	case once:
		return "📎 File sekali unduh"
	case kind == "image":
		return "📷 Foto"
	}
	return "📎 " + name
}

// fileName: nama file dari pengirim, dirapikan (tanpa folder / karakter kendali, paling panjang 120 karakter)
func fileName(raw string) string {
	name := filepath.Base(strings.ReplaceAll(raw, "\\", "/"))
	name = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || r == '/' || r == '"' {
			return -1
		}
		return r
	}, name)
	name = clean(name, 120)
	if name == "" || name == "." || name == ".." {
		return "file"
	}
	return name
}

// imageMimes: gambar yang ditampilkan langsung di obrolan; selain ini dikirim sebagai file
var imageMimes = map[string]bool{"image/png": true, "image/jpeg": true, "image/gif": true, "image/webp": true}

func (s *Server) appSendFile(w http.ResponseWriter, r *http.Request) error {
	friend, _, err := s.chatFriend(r)
	if err != nil {
		return err
	}
	tooBig := httpx.Err(413, "too_large", fmt.Sprintf("File terlalu besar. Maksimal %d MB per kiriman.", maxAttachment>>20))
	r.Body = http.MaxBytesReader(w, r.Body, maxAttachment+1<<16)
	if err := r.ParseMultipartForm(1 << 20); err != nil {
		return tooBig
	}
	defer r.MultipartForm.RemoveAll()
	f, hdr, err := r.FormFile("file")
	if err != nil {
		return httpx.Invalid("Pilih file atau gambarnya dulu, lalu kirim lagi.")
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxAttachment+1))
	if err != nil || len(data) > maxAttachment {
		return tooBig
	}
	if len(data) == 0 {
		return httpx.Invalid("File itu kosong (0 byte). Pilih file lain.")
	}
	once := r.FormValue("once") == "1" || r.FormValue("once") == "true"
	name := fileName(hdr.Filename)
	mt := http.DetectContentType(data)
	kind := "file"
	if imageMimes[mt] {
		kind = "image"
	} else if byExt := mime.TypeByExtension(strings.ToLower(filepath.Ext(name))); byExt != "" && !strings.HasPrefix(byExt, "image/") {
		// tebakan dari ekstensi lebih tepat untuk dokumen (pdf, docx, …); gambar hanya dipercaya dari isinya
		mt = byExt
	}
	if i := strings.Index(mt, ";"); i >= 0 {
		mt = strings.TrimSpace(mt[:i])
	}

	p := who(r)
	var recent int
	s.DB.QueryRowContext(r.Context(), `SELECT count(*) FROM messages WHERE from_user=$1 AND to_user=$2 AND created_at > now() - interval '1 minute'`,
		p.UserID, friend).Scan(&recent)
	if recent >= 30 {
		return httpx.Err(429, "rate_limited", "Pelan-pelan, pesanmu sudah banyak sekali barusan. Tunggu sebentar, lalu kirim lagi.")
	}
	var pending int64
	s.DB.QueryRowContext(r.Context(), `SELECT COALESCE(sum(octet_length(f.data)), 0) FROM message_files f JOIN messages m ON m.id=f.message_id
		WHERE m.from_user=$1 AND m.attach_expires_at > now()`, p.UserID).Scan(&pending)
	if pending+int64(len(data)) > maxPending {
		return httpx.Err(429, "storage_full", fmt.Sprintf("Kirimanmu yang masih tersimpan di server sudah hampir %d MB. "+
			"Tunggu sebagian terhapus otomatis (paling lama sehari), lalu kirim lagi.", maxPending>>20))
	}

	a := &attachment{Kind: kind, Name: name, Mime: mt, Size: len(data), Once: once, Available: true}
	text := attachLabel(kind, name, once)
	tx, err := s.DB.BeginTx(r.Context(), nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var id int64
	var at time.Time
	if err := tx.QueryRowContext(r.Context(), `INSERT INTO messages(from_user, to_user, text, attach_kind, attach_name, attach_mime, attach_size, attach_once, attach_expires_at)
		VALUES($1,$2,$3,$4,$5,$6,$7,$8, now() + $9 * interval '1 second') RETURNING id, created_at, attach_expires_at`,
		p.UserID, friend, text, kind, name, mt, len(data), once, int(attachTTL/time.Second)).Scan(&id, &at, &a.ExpiresAt); err != nil {
		return err
	}
	if _, err := tx.ExecContext(r.Context(), `INSERT INTO message_files(message_id, data) VALUES($1,$2)`, id, data); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}

	// sama seperti appSendMessage: ke semua Mac teman dan ke Mac lain milik pengirim
	status := "sent"
	if s.live.publish(friend, map[string]any{"type": "message", "friend_id": p.UserID, "friend_name": p.Name,
		"message": withAttachment(messageJSON(id, text, "", at, false), a)}) > 0 {
		if _, err := s.DB.ExecContext(r.Context(), `UPDATE messages SET delivered_at=now() WHERE id=$1`, id); err == nil {
			status = "delivered"
		}
	}
	mine := withAttachment(myMessageJSON(id, text, "", at, status), a)
	s.live.publish(p.UserID, map[string]any{"type": "message", "friend_id": friend, "message": mine})
	httpx.JSON(w, 201, map[string]any{"message": mine})
	return nil
}

// appGetFile: isi lampiran. Pesan sekali lihat hanya untuk penerimanya, dan isinya langsung dihapus dari server.
func (s *Server) appGetFile(w http.ResponseWriter, r *http.Request) error {
	friend, _, err := s.chatFriend(r)
	if err != nil {
		return err
	}
	msg, err := strconv.ParseInt(r.PathValue("msg"), 10, 64)
	if err != nil || msg <= 0 {
		return httpx.ErrNotFound
	}
	me := who(r).UserID
	var from, kind, name, mt string
	var once bool
	var expires time.Time
	var opened sql.NullTime
	err = s.DB.QueryRowContext(r.Context(), `SELECT from_user, attach_kind, attach_name, attach_mime, attach_once, attach_expires_at, attach_opened_at
		FROM messages WHERE id=$1 AND attach_kind IS NOT NULL
		AND ((from_user=$2 AND to_user=$3) OR (from_user=$3 AND to_user=$2))`, msg, me, friend).
		Scan(&from, &kind, &name, &mt, &once, &expires, &opened)
	if err != nil {
		return notFoundIf(err)
	}
	gone := httpx.Err(410, "gone", "File ini sudah lewat sehari, jadi sudah dihapus dari server. Minta temanmu mengirim ulang.")
	if once && from == me {
		return httpx.Err(403, "once_sender", "Pesan sekali lihat hanya bisa dibuka penerimanya, dan hanya sekali.")
	}
	if once && opened.Valid {
		return httpx.Err(410, "opened", "Pesan sekali lihat ini sudah dibuka, jadi sudah dihapus dari server.")
	}
	if !time.Now().Before(expires) {
		return gone
	}

	var data []byte
	if once {
		// hapus & ambil dalam satu perintah: dua permintaan bersamaan tidak bisa sama-sama mendapatkannya
		err = s.DB.QueryRowContext(r.Context(), `WITH d AS (DELETE FROM message_files WHERE message_id=$1 RETURNING data),
			u AS (UPDATE messages SET attach_opened_at=now() WHERE id=$1 AND EXISTS (SELECT 1 FROM d))
			SELECT data FROM d`, msg).Scan(&data)
		if err != nil {
			if err == sql.ErrNoRows {
				return httpx.Err(410, "opened", "Pesan sekali lihat ini sudah dibuka, jadi sudah dihapus dari server.")
			}
			return err
		}
		opened := map[string]any{"type": "file_opened", "message_id": msg}
		s.live.publish(friend, withFriend(opened, me))
		s.live.publish(me, withFriend(opened, friend))
	} else if err = s.DB.QueryRowContext(r.Context(), `SELECT data FROM message_files WHERE message_id=$1`, msg).Scan(&data); err != nil {
		if err == sql.ErrNoRows {
			return gone
		}
		return err
	}

	h := w.Header()
	if kind == "image" && imageMimes[mt] {
		h.Set("Content-Type", mt)
	} else {
		h.Set("Content-Type", "application/octet-stream") // tidak pernah ditampilkan sebagai halaman
	}
	h.Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": name}))
	h.Set("X-Temu-Mime", mt)
	h.Set("Content-Length", strconv.Itoa(len(data)))
	h.Set("Cache-Control", "private, no-store")
	w.Write(data)
	return nil
}

// withFriend: salinan kabar dengan friend_id (kabar yang sama dikirim ke dua orang dengan sudut pandang berbeda)
func withFriend(ev map[string]any, friend string) map[string]any {
	out := map[string]any{"friend_id": friend}
	for k, v := range ev {
		out[k] = v
	}
	return out
}

// RunCleanup menghapus isi lampiran yang sudah lewat sehari, tiap 10 menit sampai ctx selesai.
// Unduhan juga memeriksa masa berlakunya sendiri, jadi file yang kedaluwarsa tidak pernah terkirim walau belum dibersihkan.
func (s *Server) RunCleanup(ctx context.Context) {
	t := time.NewTicker(10 * time.Minute)
	defer t.Stop()
	for {
		if n, err := s.cleanupFiles(ctx); err != nil {
			log.Printf("pembersih lampiran: %v", err)
		} else if n > 0 {
			log.Printf("pembersih lampiran: %d file kedaluwarsa dihapus", n)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (s *Server) cleanupFiles(ctx context.Context) (int64, error) {
	res, err := s.DB.ExecContext(ctx, `DELETE FROM message_files f USING messages m
		WHERE m.id=f.message_id AND m.attach_expires_at <= now()`)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}
