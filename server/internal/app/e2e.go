package app

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"sort"
	"strings"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/httpx"
)

// Enkripsi ujung ke ujung (E2EE) obrolan, tahap 1 (docs/TECH_DEBT.md). Server TIDAK bisa membaca isi pesan:
// ia hanya menyimpan kunci publik tiap Mac dan meneruskan ciphertext. Semua kriptografi ada di aplikasi Mac
// (Sources/Temu/E2E.swift, CryptoKit):
//
//	kunci Mac      X25519 (agree) + Ed25519 (sign), dibuat di Mac, kunci privatnya di Keychain.
//	               PUT /api/app/keys sekali per Mac; tidak bisa diganti (Mac baru = tautkan ulang = kunci baru).
//	pesan          isi (JSON) dienkripsi ChaChaPoly dengan kunci acak; kunci itu dibungkus untuk SETIAP Mac
//	               teman dan setiap Mac milik pengirim ("keys": {device_id: amplop}); ditandatangani Mac pengirim.
//	lampiran       file dienkripsi di Mac dengan kunci acak; kunci, nama & jenis aslinya ada di dalam isi pesan.
//
// Server tetap memeriksa yang bisa diperiksa tanpa membaca isi: Mac pengirim = Mac pemanggil, tanda tangan sah,
// dan amplop untuk semua Mac (yang sudah punya kunci) milik kedua orang — supaya tidak ada Mac yang ketinggalan.
// Yang tetap terlihat server (metadata): siapa ke siapa, kapan, ukuran, foto/file, sekali lihat, emot lewat pet.

const (
	e2eVersion = 1
	maxE2ECT   = 16 << 10 // byte ciphertext isi pesan (teks ≤ 1000 karakter / keterangan lampiran)
	// amplop = kunci publik sementara X25519 (32) + ChaChaPoly(kunci pesan 32 byte): nonce 12 + 32 + tag 16
	e2eEnvelopeSize = 32 + 12 + 32 + 16
	e2eKeyContext   = "temu-e2e-v1 key\n"
	e2eMsgContext   = "temu-e2e-v1 msg\n"
	// label di kolom text untuk aplikasi lama / Mac yang belum punya kunci
	e2eTextLabel = "🔒 Pesan terenkripsi"
)

func (s *Server) e2eRoutes(mux *http.ServeMux) {
	mux.HandleFunc("PUT /api/app/keys", s.device(s.appPutKeys))
	mux.HandleFunc("GET /api/app/keys/{id}", s.device(s.appGetKeys))
}

type e2eEnvelope struct {
	V          int               `json:"v"`
	FromDevice string            `json:"from_device"`
	CT         string            `json:"ct"`
	Keys       map[string]string `json:"keys"`
	Sig        string            `json:"sig"`
}

// e2eSigned: byte yang ditandatangani Mac pengirim. Daftar Mac tujuan ikut ditandatangani, jadi server tidak bisa
// memindahkan pesan ke orang lain; amplopnya sendiri dilindungi AEAD.
func e2eSigned(env *e2eEnvelope) []byte {
	ids := make([]string, 0, len(env.Keys))
	for id := range env.Keys {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return []byte(e2eMsgContext + env.FromDevice + "\n" + strings.Join(ids, ",") + "\n" + env.CT)
}

func b64dec(s string) ([]byte, bool) {
	b, err := base64.StdEncoding.DecodeString(s)
	return b, err == nil
}

// appPutKeys: kunci publik Mac ini. Sekali saja; kunci yang sama boleh dikirim ulang.
func (s *Server) appPutKeys(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Agree string `json:"agree"`
		Sign  string `json:"sign"`
		Sig   string `json:"sig"`
	}
	if err := httpx.Decode(r, &req, 1<<10); err != nil {
		return err
	}
	agree, ok1 := b64dec(req.Agree)
	sign, ok2 := b64dec(req.Sign)
	sig, ok3 := b64dec(req.Sig)
	if !ok1 || !ok2 || !ok3 || len(agree) != 32 || len(sign) != ed25519.PublicKeySize || len(sig) != ed25519.SignatureSize ||
		!ed25519.Verify(sign, append([]byte(e2eKeyContext), agree...), sig) {
		return httpx.Invalid("Kunci keamanan Mac ini tidak sah. Perbarui aplikasi Temu, lalu coba lagi.")
	}
	dev := who(r).DeviceID
	res, err := s.DB.ExecContext(r.Context(), `INSERT INTO device_keys(device_id, agree_pub, sign_pub, sig) VALUES($1,$2,$3,$4)
		ON CONFLICT (device_id) DO UPDATE SET sig=device_keys.sig
		WHERE device_keys.agree_pub=EXCLUDED.agree_pub AND device_keys.sign_pub=EXCLUDED.sign_pub`, dev, agree, sign, sig)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpx.Err(409, "keys_exist", "Mac ini sudah punya kunci keamanan lain. Putuskan Mac ini dari akun, "+
			"lalu hubungkan lagi supaya kuncinya dibuat ulang.")
	}
	httpx.JSON(w, 200, map[string]any{"device_id": dev})
	return nil
}

type deviceKey struct {
	user, device string
	agree, sign  []byte
	sig          []byte
}

// pairKeys: kunci semua Mac milik dua orang (Mac tanpa kunci tidak ikut) + jumlah Mac masing-masing.
func (s *Server) pairKeys(ctx context.Context, me, friend string) (keys []deviceKey, devices map[string]int, err error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT d.user_id, d.id, k.agree_pub, k.sign_pub, k.sig FROM devices d
		JOIN device_keys k ON k.device_id=d.id WHERE d.user_id IN ($1, $2) ORDER BY d.created_at`, me, friend)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var k deviceKey
		if err := rows.Scan(&k.user, &k.device, &k.agree, &k.sign, &k.sig); err != nil {
			return nil, nil, err
		}
		keys = append(keys, k)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	devices = map[string]int{}
	cnt, err := s.DB.QueryContext(ctx, `SELECT user_id, count(*) FROM devices WHERE user_id IN ($1, $2) GROUP BY user_id`, me, friend)
	if err != nil {
		return nil, nil, err
	}
	defer cnt.Close()
	for cnt.Next() {
		var u string
		var n int
		if err := cnt.Scan(&u, &n); err != nil {
			return nil, nil, err
		}
		devices[u] = n
	}
	return keys, devices, cnt.Err()
}

// appGetKeys: kunci publik semua Mac teman dan Mac milikku, untuk mengenkripsi pesan ke teman ini.
// "devices" = jumlah Mac yang tertaut; kalau lebih banyak dari jumlah kunci, ada Mac yang belum diperbarui.
func (s *Server) appGetKeys(w http.ResponseWriter, r *http.Request) error {
	friend, _, err := s.chatFriend(r)
	if err != nil {
		return err
	}
	p := who(r)
	keys, devices, err := s.pairKeys(r.Context(), p.UserID, friend)
	if err != nil {
		return err
	}
	set := func(user string) map[string]any {
		list := []map[string]any{}
		for _, k := range keys {
			if k.user == user {
				list = append(list, map[string]any{"device_id": k.device, "agree": enc64(k.agree), "sign": enc64(k.sign), "sig": enc64(k.sig)})
			}
		}
		return map[string]any{"devices": devices[user], "keys": list}
	}
	httpx.JSON(w, 200, map[string]any{"me": p.DeviceID, "friend": set(friend), "mine": set(p.UserID)})
	return nil
}

func enc64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

// checkEnvelope: pesan E2EE dari pemanggil ke teman. Hasilnya JSON yang disimpan di messages.e2e.
func (s *Server) checkEnvelope(ctx context.Context, me, myDevice, friend string, env *e2eEnvelope) ([]byte, error) {
	bad := httpx.Invalid("Pesan terenkripsinya rusak. Perbarui aplikasi Temu, lalu coba lagi.")
	ct, ok := b64dec(env.CT)
	sig, ok2 := b64dec(env.Sig)
	if env.V != e2eVersion || !ok || !ok2 || len(ct) == 0 || len(ct) > maxE2ECT || len(sig) != ed25519.SignatureSize ||
		len(env.Keys) == 0 || len(env.Keys) > 2*10 || strings.ToLower(env.FromDevice) != myDevice {
		return nil, bad
	}
	for _, v := range env.Keys {
		if b, ok := b64dec(v); !ok || len(b) != e2eEnvelopeSize {
			return nil, bad
		}
	}
	keys, _, err := s.pairKeys(ctx, me, friend)
	if err != nil {
		return nil, err
	}
	stale := httpx.Err(409, "e2e_stale", "Daftar Mac temanmu baru saja berubah. Kirim lagi, ya.")
	friendKeyed, signed := false, false
	known := map[string]bool{}
	for _, k := range keys {
		known[k.device] = true
		if _, has := env.Keys[k.device]; !has {
			return nil, stale // ada Mac (teman / milikku) yang tidak diberi amplop
		}
		if k.user == friend {
			friendKeyed = true
		}
		if k.device == myDevice {
			if !ed25519.Verify(k.sign, e2eSigned(env), sig) {
				return nil, bad
			}
			signed = true
		}
	}
	if !signed {
		return nil, httpx.Err(409, "e2e_no_keys", "Kunci keamanan Mac ini belum terdaftar. Tunggu sebentar, lalu kirim lagi.")
	}
	if !friendKeyed {
		return nil, httpx.Err(409, "e2e_friend_no_keys", "Temu temanmu belum mendukung pesan terenkripsi. Kirim lagi, ya.")
	}
	for id := range env.Keys {
		if !known[id] {
			return nil, stale // Mac yang sudah diputuskan / bukan milik kalian berdua
		}
	}
	return json.Marshal(env)
}

// withE2E: tambahkan "e2e" ke JSON pesan (kalau pesannya terenkripsi)
func withE2E(m map[string]any, raw []byte) map[string]any {
	if len(raw) > 0 {
		m["e2e"] = json.RawMessage(raw)
	}
	return m
}

// nullJSON: nilai kolom JSONB (NULL untuk pesan biasa)
func nullJSON(raw []byte) any {
	if len(raw) == 0 {
		return nil
	}
	return string(raw)
}
