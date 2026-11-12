package app

import (
	"context"
	"database/sql"
	"encoding/base64"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/httpx"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/sprite"
)

func (s *Server) petRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/templates", s.wrap(s.listTemplates))
	mux.HandleFunc("GET /api/templates/{id}", s.wrap(s.templateSheet))
	mux.HandleFunc("GET /api/pets", s.user(s.listPets))
	mux.HandleFunc("POST /api/pets", s.user(s.createPet))
	mux.HandleFunc("GET /api/pets/{id}", s.user(s.getPet))
	mux.HandleFunc("PATCH /api/pets/{id}", s.user(s.updatePet))
	mux.HandleFunc("DELETE /api/pets/{id}", s.user(s.deletePet))
	mux.HandleFunc("GET /api/pets/{id}/sheet.png", s.user(s.petSheet))
	mux.HandleFunc("POST /api/pets/{id}/request", s.user(s.requestPet))
	mux.HandleFunc("GET /api/pet-requests", s.user(s.listPetRequests))
	mux.HandleFunc("POST /api/pet-requests/{id}/approve", s.user(s.approvePetRequest))
	mux.HandleFunc("PATCH /api/pet-requests/{id}", s.user(s.updatePetShare))
	mux.HandleFunc("DELETE /api/pet-requests/{id}", s.user(s.deletePetRequest))
}

func (s *Server) listTemplates(w http.ResponseWriter, r *http.Request) error {
	out := make([]map[string]any, 0, len(sprite.Templates))
	for _, t := range sprite.Templates {
		out = append(out, map[string]any{"id": t.ID, "title": t.Title, "default_name": t.DefaultName, "sheet_url": "/api/templates/" + t.ID + ".png"})
	}
	httpx.JSON(w, 200, map[string]any{"data": out, "frames": sprite.Frames})
	return nil
}

func (s *Server) templateSheet(w http.ResponseWriter, r *http.Request) error {
	png, ok := sprite.TemplatePNG(strings.TrimSuffix(r.PathValue("id"), ".png"))
	if !ok {
		return httpx.ErrNotFound
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	w.Write(png)
	return nil
}

// petRow: kolom yang dipakai semua daftar pet (tanpa sheet — diambil lewat URL sendiri).
const petCols = `p.id, p.name, p.bio, p.origin, p.on_mac, p.sheet_ver, p.hidden_at, p.created_at, u.id, u.name, u.handle`

type petRow struct {
	ID, Name, Bio, Origin           string
	OnMac                           bool
	Ver                             int
	Hidden                          sql.NullTime
	Created                         time.Time
	OwnerID, OwnerName, OwnerHandle string
}

func (p *petRow) dest() []any {
	return []any{&p.ID, &p.Name, &p.Bio, &p.Origin, &p.OnMac, &p.Ver, &p.Hidden, &p.Created, &p.OwnerID, &p.OwnerName, &p.OwnerHandle}
}

func (p *petRow) json(viewer string) map[string]any {
	return map[string]any{
		"id": p.ID, "name": p.Name, "bio": p.Bio, "origin": p.Origin, "on_mac": p.OnMac, "sheet_ver": p.Ver,
		"sheet_url": fmt.Sprintf("/api/pets/%s/sheet.png?v=%d", p.ID, p.Ver),
		"hidden":    p.Hidden.Valid, "created_at": p.Created, "mine": p.OwnerID == viewer,
		"owner": map[string]any{"id": p.OwnerID, "name": p.OwnerName, "handle": p.OwnerHandle},
	}
}

func (s *Server) listPets(w http.ResponseWriter, r *http.Request) error {
	me := who(r).UserID
	rows, err := s.DB.QueryContext(r.Context(), `SELECT `+petCols+` FROM pets p JOIN users u ON u.id=p.owner_id
		WHERE p.owner_id=$1 ORDER BY p.created_at`, me)
	if err != nil {
		return err
	}
	defer rows.Close()
	mine := []map[string]any{}
	for rows.Next() {
		var p petRow
		if err := rows.Scan(p.dest()...); err != nil {
			return err
		}
		mine = append(mine, p.json(me))
	}
	// pet titipan teman (sudah disetujui)
	rows2, err := s.DB.QueryContext(r.Context(), `SELECT `+petCols+`, sh.id, sh.on_mac FROM pet_shares sh
		JOIN pets p ON p.id=sh.pet_id JOIN users u ON u.id=p.owner_id
		WHERE sh.to_user=$1 AND sh.status='approved' AND p.hidden_at IS NULL ORDER BY sh.decided_at`, me)
	if err != nil {
		return err
	}
	defer rows2.Close()
	guests := []map[string]any{}
	for rows2.Next() {
		var p petRow
		var shareID string
		var onMac bool
		if err := rows2.Scan(append(p.dest(), &shareID, &onMac)...); err != nil {
			return err
		}
		j := p.json(me)
		j["share_id"], j["on_mac"] = shareID, onMac
		guests = append(guests, j)
	}
	httpx.JSON(w, 200, map[string]any{"mine": mine, "guests": guests, "max_pets": s.settings(r.Context()).MaxPets})
	return rows2.Err()
}

// decodeSheet: data URI / base64 PNG dari editor → sheet yang sudah dinormalkan.
func decodeSheet(b64 string) ([]byte, error) {
	if i := strings.Index(b64, ","); strings.HasPrefix(b64, "data:") && i > 0 {
		b64 = b64[i+1:]
	}
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(raw) == 0 {
		return nil, httpx.Invalid("Gambar pet tidak terbaca.")
	}
	out, err := sprite.NormalizeBytes(raw)
	if err != nil {
		return nil, httpx.Invalid("Gambar pet tidak bisa dipakai: " + err.Error() + ".")
	}
	return out, nil
}

func (s *Server) createPet(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Name         string `json:"name"`
		Template     string `json:"template"`
		Sheet        string `json:"sheet"`
		GenerationID string `json:"generation_id"`
	}
	if err := httpx.Decode(r, &req, 2<<20); err != nil {
		return err
	}
	me := who(r).UserID
	st := s.settings(r.Context())
	var n int
	if err := s.DB.QueryRowContext(r.Context(), `SELECT count(*) FROM pets WHERE owner_id=$1`, me).Scan(&n); err != nil {
		return err
	}
	if n >= st.MaxPets {
		return httpx.Err(409, "pet_limit", fmt.Sprintf("Kamu sudah punya %d pet (batasnya %d). Lepas satu dulu untuk membuat yang baru.", n, st.MaxPets))
	}
	name := clean(req.Name, 24)
	var sheet []byte
	origin := "drawn"
	switch {
	case req.GenerationID != "":
		if !uuidRe.MatchString(req.GenerationID) {
			return httpx.ErrNotFound
		}
		var mode string
		err := s.DB.QueryRowContext(r.Context(), `SELECT result_sheet, mode FROM generations WHERE id=$1 AND user_id=$2 AND status='done'`,
			req.GenerationID, me).Scan(&sheet, &mode)
		if err != nil || len(sheet) == 0 {
			return httpx.Err(404, "not_found", "Hasil generate itu tidak ditemukan atau belum selesai.")
		}
		origin = "ai"
		if mode == "manual" {
			origin = "upload"
		}
		if req.Sheet != "" { // hasil AI yang dirapikan dulu di editor
			var err error
			if sheet, err = decodeSheet(req.Sheet); err != nil {
				return err
			}
		}
	case req.Sheet != "":
		var err error
		if sheet, err = decodeSheet(req.Sheet); err != nil {
			return err
		}
		if req.Template != "" {
			origin = "template"
		}
	case req.Template != "":
		tpl, ok := sprite.FindTemplate(req.Template)
		if !ok {
			return httpx.Invalid("Template pet tidak dikenal.")
		}
		sheet, _ = sprite.TemplatePNG(tpl.ID)
		origin = "template"
		if name == "" {
			name = tpl.DefaultName
		}
	default:
		return httpx.Invalid("Pilih template, gambar sendiri, atau pakai hasil generate.")
	}
	if name == "" {
		return httpx.Invalid("Beri nama pet-mu.")
	}
	var id string
	if err := s.DB.QueryRowContext(r.Context(), `INSERT INTO pets(owner_id, name, sheet, origin) VALUES($1,$2,$3,$4) RETURNING id`,
		me, name, sheet, origin).Scan(&id); err != nil {
		return err
	}
	return s.writePet(w, r, id, 201)
}

func (s *Server) writePet(w http.ResponseWriter, r *http.Request, id string, status int) error {
	var p petRow
	err := s.DB.QueryRowContext(r.Context(), `SELECT `+petCols+` FROM pets p JOIN users u ON u.id=p.owner_id WHERE p.id=$1`, id).Scan(p.dest()...)
	if err != nil {
		return notFoundIf(err)
	}
	httpx.JSON(w, status, map[string]any{"pet": p.json(who(r).UserID)})
	return nil
}

// canSeePet: pemilik, penerima titipan, atau teman pemilik (untuk melihat sebelum meminta).
func (s *Server) canSeePet(ctx context.Context, petID, viewer string) (owner string, ok bool, err error) {
	var hidden sql.NullTime
	if err = s.DB.QueryRowContext(ctx, `SELECT owner_id, hidden_at FROM pets WHERE id=$1`, petID).Scan(&owner, &hidden); err != nil {
		return "", false, notFoundIf(err)
	}
	if owner == viewer {
		return owner, true, nil
	}
	if hidden.Valid {
		return owner, false, nil
	}
	return owner, s.areFriends(ctx, owner, viewer), nil
}

func (s *Server) getPet(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	if _, ok, err := s.canSeePet(r.Context(), id, who(r).UserID); err != nil {
		return err
	} else if !ok {
		return httpx.ErrNotFound
	}
	return s.writePet(w, r, id, 200)
}

func (s *Server) petSheet(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	if _, ok, err := s.canSeePet(r.Context(), id, who(r).UserID); err != nil {
		return err
	} else if !ok {
		return httpx.ErrNotFound
	}
	var sheet []byte
	if err := s.DB.QueryRowContext(r.Context(), `SELECT sheet FROM pets WHERE id=$1`, id).Scan(&sheet); err != nil {
		return notFoundIf(err)
	}
	servePNG(w, r, sheet)
	return nil
}

func (s *Server) updatePet(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Name  *string `json:"name"`
		Bio   *string `json:"bio"`
		OnMac *bool   `json:"on_mac"`
		Sheet *string `json:"sheet"`
	}
	if err := httpx.Decode(r, &req, 2<<20); err != nil {
		return err
	}
	me := who(r).UserID
	var owner string
	if err := s.DB.QueryRowContext(r.Context(), `SELECT owner_id FROM pets WHERE id=$1`, id).Scan(&owner); err != nil {
		return notFoundIf(err)
	}
	if owner != me {
		return httpx.ErrNotFound
	}
	if req.Name != nil {
		n := clean(*req.Name, 24)
		if n == "" {
			return httpx.Invalid("Nama pet tidak boleh kosong.")
		}
		if _, err := s.DB.ExecContext(r.Context(), `UPDATE pets SET name=$2, updated_at=now() WHERE id=$1`, id, n); err != nil {
			return err
		}
	}
	if req.Bio != nil {
		if _, err := s.DB.ExecContext(r.Context(), `UPDATE pets SET bio=$2, updated_at=now() WHERE id=$1`, id, clean(*req.Bio, 140)); err != nil {
			return err
		}
	}
	if req.OnMac != nil {
		if _, err := s.DB.ExecContext(r.Context(), `UPDATE pets SET on_mac=$2 WHERE id=$1`, id, *req.OnMac); err != nil {
			return err
		}
	}
	if req.Sheet != nil {
		sheet, err := decodeSheet(*req.Sheet)
		if err != nil {
			return err
		}
		if _, err := s.DB.ExecContext(r.Context(), `UPDATE pets SET sheet=$2, sheet_ver=sheet_ver+1, updated_at=now() WHERE id=$1`, id, sheet); err != nil {
			return err
		}
	}
	return s.writePet(w, r, id, 200)
}

func (s *Server) deletePet(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	res, err := s.DB.ExecContext(r.Context(), `DELETE FROM pets WHERE id=$1 AND owner_id=$2`, id, who(r).UserID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.ErrNotFound
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

// ---------------- titip pet (minta pet teman untuk tampil di Mac kita) ----------------

func (s *Server) requestPet(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	me := who(r).UserID
	owner, ok, err := s.canSeePet(r.Context(), id, me)
	if err != nil {
		return err
	}
	if !ok || owner == me {
		return httpx.Invalid("Kamu hanya bisa meminta pet milik teman.")
	}
	var n int
	s.DB.QueryRowContext(r.Context(), `SELECT count(*) FROM pet_shares WHERE to_user=$1`, me).Scan(&n)
	if n >= 30 {
		return httpx.Err(409, "share_limit", "Terlalu banyak pet titipan. Pulangkan beberapa dulu.")
	}
	if _, err := s.DB.ExecContext(r.Context(), `INSERT INTO pet_shares(pet_id, to_user) VALUES($1,$2) ON CONFLICT DO NOTHING`, id, me); err != nil {
		return err
	}
	httpx.JSON(w, 201, map[string]any{"ok": true})
	return nil
}

// listPetRequests: permintaan masuk untuk pet-ku, dan pet-ku yang sedang dititipkan.
func (s *Server) listPetRequests(w http.ResponseWriter, r *http.Request) error {
	me := who(r).UserID
	rows, err := s.DB.QueryContext(r.Context(), `SELECT sh.id, sh.status, sh.created_at, p.id, p.name, p.sheet_ver, t.id, t.name, t.handle
		FROM pet_shares sh JOIN pets p ON p.id=sh.pet_id JOIN users t ON t.id=sh.to_user
		WHERE p.owner_id=$1 ORDER BY sh.created_at DESC`, me)
	if err != nil {
		return err
	}
	defer rows.Close()
	incoming, lent := []map[string]any{}, []map[string]any{}
	for rows.Next() {
		var id, status, pid, pname, tid, tname, thandle string
		var ver int
		var at time.Time
		if err := rows.Scan(&id, &status, &at, &pid, &pname, &ver, &tid, &tname, &thandle); err != nil {
			return err
		}
		item := map[string]any{"id": id, "created_at": at,
			"pet":  map[string]any{"id": pid, "name": pname, "sheet_url": fmt.Sprintf("/api/pets/%s/sheet.png?v=%d", pid, ver)},
			"user": map[string]any{"id": tid, "name": tname, "handle": thandle}}
		if status == "approved" {
			lent = append(lent, item)
		} else {
			incoming = append(incoming, item)
		}
	}
	httpx.JSON(w, 200, map[string]any{"incoming": incoming, "lent": lent})
	return rows.Err()
}

func (s *Server) approvePetRequest(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	res, err := s.DB.ExecContext(r.Context(), `UPDATE pet_shares sh SET status='approved', decided_at=now()
		FROM pets p WHERE sh.id=$1 AND p.id=sh.pet_id AND p.owner_id=$2 AND sh.status='requested'`, id, who(r).UserID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.ErrNotFound
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

// updatePetShare: penerima titipan mengatur apakah pet itu tampil di Mac-nya.
func (s *Server) updatePetShare(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		OnMac bool `json:"on_mac"`
	}
	if err := httpx.Decode(r, &req, 1<<10); err != nil {
		return err
	}
	res, err := s.DB.ExecContext(r.Context(), `UPDATE pet_shares SET on_mac=$3 WHERE id=$1 AND to_user=$2`, id, who(r).UserID, req.OnMac)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.ErrNotFound
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}

// deletePetRequest: pemilik menolak / menarik pulang, atau peminta membatalkan / memulangkan.
func (s *Server) deletePetRequest(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	res, err := s.DB.ExecContext(r.Context(), `DELETE FROM pet_shares sh USING pets p
		WHERE sh.id=$1 AND p.id=sh.pet_id AND (p.owner_id=$2 OR sh.to_user=$2)`, id, who(r).UserID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.ErrNotFound
	}
	httpx.JSON(w, 200, map[string]any{"ok": true})
	return nil
}
