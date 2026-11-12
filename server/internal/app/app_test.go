package app

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/config"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/db"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/security"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/sprite"
)

// Test integrasi: butuh PostgreSQL. Dilewati kalau TEMANI_TEST_DATABASE_URL kosong.
//
//	TEMANI_TEST_DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres?sslmode=disable go test ./...
func testServer(t *testing.T, mock bool) (*Server, *httptest.Server) {
	t.Helper()
	base := os.Getenv("TEMANI_TEST_DATABASE_URL")
	if base == "" {
		t.Skip("TEMANI_TEST_DATABASE_URL kosong — test integrasi dilewati")
	}
	ctx := context.Background()
	root, err := db.Open(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	name := "temani_test_" + strings.ToLower(security.RandomCode(10))
	if _, err := root.ExecContext(ctx, `CREATE DATABASE `+name); err != nil {
		t.Fatal(err)
	}
	url := base[:strings.LastIndex(base, "/")+1] + name
	if i := strings.Index(base, "?"); i >= 0 {
		url += base[i:]
	}
	conn, err := db.Open(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Migrate(ctx, conn); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{Env: "test", PublicURL: "http://temani.test", AppSecret: bytes.Repeat([]byte{7}, 32),
		SessionTTL: time.Hour, AITimeout: 10 * time.Second, AIMock: mock, WebDir: t.TempDir()}
	s := New(conn, cfg)
	ts := httptest.NewServer(s.Routes())
	t.Cleanup(func() {
		ts.Close()
		conn.Close()
		root.ExecContext(ctx, `DROP DATABASE `+name+` WITH (FORCE)`)
		root.Close()
	})
	return s, ts
}

// client: satu "browser" (cookie jar + token CSRF) atau satu aplikasi Mac (bearer).
type client struct {
	t      *testing.T
	base   string
	http   *http.Client
	csrf   string
	bearer string
}

func newClient(t *testing.T, ts *httptest.Server) *client {
	jar, _ := cookiejar.New(nil)
	return &client{t: t, base: ts.URL, http: &http.Client{Jar: jar}}
}

func (c *client) do(method, path string, body any) (int, map[string]any) {
	c.t.Helper()
	var rd io.Reader
	ct := ""
	switch b := body.(type) {
	case nil:
	case *bytes.Buffer:
		rd = b
	default:
		j, _ := json.Marshal(b)
		rd, ct = bytes.NewReader(j), "application/json"
	}
	req, _ := http.NewRequest(method, c.base+path, rd)
	if ct != "" {
		req.Header.Set("Content-Type", ct)
	}
	if c.csrf != "" {
		req.Header.Set("X-CSRF-Token", c.csrf)
	}
	if c.bearer != "" {
		req.Header.Set("Authorization", "Bearer "+c.bearer)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	out := map[string]any{}
	if strings.HasPrefix(resp.Header.Get("Content-Type"), "application/json") {
		json.Unmarshal(raw, &out)
	} else {
		out["raw"] = raw
	}
	if tok, ok := out["csrf_token"].(string); ok {
		c.csrf = tok
	}
	return resp.StatusCode, out
}

// must: panggil dan pastikan statusnya.
func (c *client) must(want int, method, path string, body any) map[string]any {
	c.t.Helper()
	code, out := c.do(method, path, body)
	if code != want {
		c.t.Fatalf("%s %s = %d (mau %d): %v", method, path, code, want, out)
	}
	return out
}

func (c *client) upload(want int, path, field string, data []byte, fields map[string]string) map[string]any {
	c.t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for k, v := range fields {
		mw.WriteField(k, v)
	}
	fw, _ := mw.CreateFormFile(field, "gambar.png")
	fw.Write(data)
	mw.Close()
	req, _ := http.NewRequest("POST", c.base+path, &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("X-CSRF-Token", c.csrf)
	resp, err := c.http.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode != want {
		c.t.Fatalf("POST %s = %d (mau %d): %v", path, resp.StatusCode, want, out)
	}
	return out
}

func register(t *testing.T, ts *httptest.Server, handle string) *client {
	c := newClient(t, ts)
	c.must(201, "POST", "/api/auth/register", map[string]any{"email": handle + "@contoh.id", "name": strings.ToUpper(handle[:1]) + handle[1:],
		"handle": handle, "password": "rahasia-banget", "template": "oren"})
	return c
}

func list(m map[string]any, key string) []any {
	l, _ := m[key].([]any)
	return l
}

func TestUserFlow(t *testing.T) {
	s, ts := testServer(t, true)
	kiki, dina := register(t, ts, "kiki"), register(t, ts, "dina")

	// tanpa sesi → 401; tanpa CSRF → 403
	anon := newClient(t, ts)
	anon.must(401, "GET", "/api/pets", nil)
	kcsrf := kiki.csrf
	kiki.csrf = ""
	kiki.must(403, "POST", "/api/pets", map[string]any{"template": "rubah"})
	kiki.csrf = kcsrf

	// pet pertama dari template saat daftar
	pets := kiki.must(200, "GET", "/api/pets", nil)
	if len(list(pets, "mine")) != 1 {
		t.Fatalf("pet awal: %v", pets)
	}
	kikiPet := list(pets, "mine")[0].(map[string]any)["id"].(string)

	// sheet dari editor (PNG 128×128 dalam base64) → pet baru; lalu ganti nama
	tpl, _ := sprite.TemplatePNG("kelinci")
	created := dina.must(201, "POST", "/api/pets", map[string]any{"name": "Salju", "sheet": "data:image/png;base64," + b64(tpl)})
	dinaPet := created["pet"].(map[string]any)["id"].(string)
	dina.must(200, "PATCH", "/api/pets/"+dinaPet, map[string]any{"name": "Salju Kecil", "bio": "suka wortel"})
	dina.must(422, "POST", "/api/pets", map[string]any{"name": "Rusak", "sheet": "bukan-gambar"})

	// belum berteman → pet orang lain tidak terlihat
	kiki.must(404, "GET", "/api/pets/"+dinaPet, nil)
	kiki.must(422, "POST", "/api/pets/"+dinaPet+"/request", nil)

	// undangan: info bisa dibuka tanpa masuk, lalu Dina menerima
	inv := kiki.must(201, "POST", "/api/friends/invites", nil)
	code := inv["code"].(string)
	info := anon.must(200, "GET", "/api/invites/"+code, nil)
	if info["from"].(map[string]any)["handle"] != "kiki" {
		t.Fatalf("info undangan: %v", info)
	}
	if _, out := anon.do("GET", "/api/invites/"+code+"/pet.png", nil); len(out["raw"].([]byte)) < 100 {
		t.Fatal("gambar pet undangan kosong")
	}
	kiki.must(422, "POST", "/api/invites/"+code+"/accept", nil) // undangan sendiri
	dina.must(200, "POST", "/api/invites/"+code+"/accept", nil)
	fr := kiki.must(200, "GET", "/api/friends", nil)
	if len(list(fr, "friends")) != 1 {
		t.Fatalf("teman: %v", fr)
	}

	// Kiki meminta pet Dina → Dina menyetujui → muncul sebagai titipan
	kiki.must(201, "POST", "/api/pets/"+dinaPet+"/request", nil)
	reqs := dina.must(200, "GET", "/api/pet-requests", nil)
	if len(list(reqs, "incoming")) != 1 {
		t.Fatalf("permintaan masuk: %v", reqs)
	}
	shareID := list(reqs, "incoming")[0].(map[string]any)["id"].(string)
	kiki.must(404, "POST", "/api/pet-requests/"+shareID+"/approve", nil) // bukan pemilik
	dina.must(200, "POST", "/api/pet-requests/"+shareID+"/approve", nil)
	if g := list(kiki.must(200, "GET", "/api/pets", nil), "guests"); len(g) != 1 || g[0].(map[string]any)["name"] != "Salju Kecil" {
		t.Fatalf("titipan: %v", g)
	}

	// hubungkan Mac: mulai dari aplikasi → setujui di web → ambil token sekali
	mac := newClient(t, ts)
	start := mac.must(201, "POST", "/api/app/link/start", map[string]any{"device_name": "MacBook Kiki"})
	poll := map[string]any{"poll_token": start["poll_token"]}
	if st := mac.must(200, "POST", "/api/app/link/poll", poll); st["status"] != "pending" {
		t.Fatalf("poll: %v", st)
	}
	linkCode := start["code"].(string)
	kiki.must(200, "GET", "/api/link/"+linkCode, nil)
	kiki.must(200, "POST", "/api/link/"+linkCode+"/approve", nil)
	approved := mac.must(200, "POST", "/api/app/link/poll", poll)
	mac.bearer = approved["token"].(string)
	mac.must(410, "POST", "/api/app/link/poll", poll) // token hanya bisa diambil sekali

	// sapaan Dina sampai ke Mac Kiki, sekali saja
	dina.must(201, "POST", "/api/friends/"+userID(t, s, "kiki")+"/nudge", map[string]any{"text": "makan siang yuk"})
	sync := mac.must(200, "GET", "/api/app/sync", nil)
	if len(list(sync, "pets")) != 2 || len(list(sync, "nudges")) != 1 {
		t.Fatalf("sync: %v", sync)
	}
	if n := list(mac.must(200, "GET", "/api/app/sync", nil), "nudges"); len(n) != 0 {
		t.Fatalf("sapaan terkirim dua kali: %v", n)
	}
	if _, out := mac.do("GET", "/api/app/pets/"+dinaPet+"/sheet.png?v=1", nil); len(out["raw"].([]byte)) < 100 {
		t.Fatal("sheet titipan tidak terunduh")
	}
	// pet disembunyikan dari Mac → hilang dari sync
	kiki.must(200, "PATCH", "/api/pets/"+kikiPet, map[string]any{"on_mac": false})
	if p := list(mac.must(200, "GET", "/api/app/sync", nil), "pets"); len(p) != 1 {
		t.Fatalf("sync setelah on_mac=false: %v", p)
	}

	// putus pertemanan → titipan ikut pulang
	dina.must(200, "DELETE", "/api/friends/"+userID(t, s, "kiki"), nil)
	if g := list(kiki.must(200, "GET", "/api/pets", nil), "guests"); len(g) != 0 {
		t.Fatalf("titipan masih ada: %v", g)
	}

	// token perangkat dicabut dari web
	devs := list(kiki.must(200, "GET", "/api/devices", nil), "data")
	kiki.must(200, "DELETE", "/api/devices/"+devs[0].(map[string]any)["id"].(string), nil)
	mac.must(401, "GET", "/api/app/sync", nil)
}

func TestGenerate(t *testing.T) {
	s, ts := testServer(t, true)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.RunWorker(ctx)
	u := register(t, ts, "raka")

	info := u.must(200, "GET", "/api/generate/info", nil)
	if info["ai_available"] != true || !strings.Contains(info["prompt"].(string), "magenta") {
		t.Fatalf("info: %v", info)
	}
	guide, _ := guidePNG()

	// cara manual: unggah gambar grid → langsung jadi sheet
	man := u.upload(201, "/api/generate/manual", "image", guide, nil)
	u.must(201, "POST", "/api/pets", map[string]any{"name": "Dari ChatGPT", "generation_id": man["id"]})
	u.upload(422, "/api/generate/manual", "image", []byte("bukan gambar sama sekali, hanya teks biasa"), nil)

	// cara AI (provider mock): antre → selesai → jadi pet
	gen := u.upload(202, "/api/generate", "photo", guide, map[string]string{"note": "pakai topi"})
	id := gen["id"].(string)
	var st map[string]any
	for i := 0; i < 100; i++ {
		if st = u.must(200, "GET", "/api/generate/"+id, nil); st["status"] == "done" || st["status"] == "failed" {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if st["status"] != "done" {
		t.Fatalf("generate: %v", st)
	}
	if _, out := u.do("GET", st["sheet_url"].(string), nil); len(out["raw"].([]byte)) < 100 {
		t.Fatal("sheet hasil kosong")
	}
	u.must(201, "POST", "/api/pets", map[string]any{"name": "Dari Foto", "generation_id": id})
	var photo []byte
	s.DB.QueryRow(`SELECT photo FROM generations WHERE id=$1`, id).Scan(&photo)
	if photo != nil {
		t.Fatal("foto pengguna masih tersimpan setelah generate selesai")
	}

	// jatah harian (bawaan 3) — yang ke-4 ditolak
	u.upload(202, "/api/generate", "photo", guide, nil)
	u.upload(202, "/api/generate", "photo", guide, nil)
	u.upload(429, "/api/generate", "photo", guide, nil)
}

func TestAdminIsSeparate(t *testing.T) {
	s, ts := testServer(t, false)
	u := register(t, ts, "sari")
	req, _ := http.NewRequest("GET", "/", nil)
	if err := s.CreateAdmin(req, "admin@contoh.id", "admin-rahasia", "Admin"); err != nil {
		t.Fatal(err)
	}

	// sesi pengguna tidak membuka API admin, dan akun pengguna tidak bisa masuk admin
	u.must(401, "GET", "/api/admin/overview", nil)
	u.must(401, "POST", "/api/admin/auth/login", map[string]any{"email": "sari@contoh.id", "password": "rahasia-banget"})

	adm := newClient(t, ts)
	adm.must(401, "POST", "/api/admin/auth/login", map[string]any{"email": "admin@contoh.id", "password": "salah"})
	adm.must(200, "POST", "/api/admin/auth/login", map[string]any{"email": "admin@contoh.id", "password": "admin-rahasia"})
	// sesi admin tidak membuka API pengguna
	adm.must(401, "GET", "/api/pets", nil)
	if ov := adm.must(200, "GET", "/api/admin/overview", nil); ov["users"].(float64) != 1 {
		t.Fatalf("overview: %v", ov)
	}

	// koneksi AI: key dienkripsi di DB dan tidak pernah dikirim balik
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer sk-rahasia-1234567890" {
			http.Error(w, `{"error":"unauthorized"}`, 401)
			return
		}
		switch r.URL.Path {
		case "/v1/models":
			fmt.Fprint(w, `{"data":[{"id":"gambar-1","architecture":{"output_modalities":["image"]}},{"id":"teks-1"}]}`)
		case "/v1/chat/completions":
			b, _ := sprite.TemplatePNG("beruang")
			g, _ := sprite.Guide(b)
			json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": "",
				"images": []any{map[string]any{"image_url": map[string]any{"url": "data:image/png;base64," + b64(g)}}}}}}})
		}
	}))
	defer fake.Close()
	s.AIHTTP = fake.Client()
	conn := adm.must(200, "POST", "/api/admin/connections", map[string]any{"name": "Uji", "kind": "openrouter", "base_url": fake.URL + "/v1",
		"api_key": "sk-rahasia-1234567890", "image_model": "gambar-1", "style": "chat"})
	id := conn["id"].(string)
	lst := adm.must(200, "GET", "/api/admin/connections", nil)
	if raw, _ := json.Marshal(lst); strings.Contains(string(raw), "sk-rahasia-1234567890") {
		t.Fatal("API key bocor di daftar koneksi")
	}
	var enc []byte
	s.DB.QueryRow(`SELECT api_key_enc FROM ai_connections WHERE id=$1`, id).Scan(&enc)
	if bytes.Contains(enc, []byte("sk-rahasia")) {
		t.Fatal("API key tersimpan tanpa enkripsi")
	}
	if tr := adm.must(200, "POST", "/api/admin/connections/"+id+"/test", nil); tr["ok"] != true {
		t.Fatalf("tes koneksi: %v", tr)
	}
	if m := list(adm.must(200, "GET", "/api/admin/connections/"+id+"/models", nil), "data"); len(m) != 2 {
		t.Fatalf("model: %v", m)
	}
	// ubah tanpa mengisi key → key lama tetap dipakai
	adm.must(200, "PATCH", "/api/admin/connections/"+id, map[string]any{"name": "Uji 2", "kind": "openrouter", "base_url": fake.URL + "/v1",
		"image_model": "gambar-1", "style": "chat"})

	// generate sungguhan lewat provider palsu
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.RunWorker(ctx)
	guide, _ := guidePNG()
	gen := u.upload(202, "/api/generate", "photo", guide, nil)
	var st map[string]any
	for i := 0; i < 100; i++ {
		if st = u.must(200, "GET", "/api/generate/"+gen["id"].(string), nil); st["status"] != "queued" && st["status"] != "running" {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if st["status"] != "done" {
		var msg string
		s.DB.QueryRow(`SELECT error FROM generations WHERE id=$1`, gen["id"]).Scan(&msg)
		t.Fatalf("generate lewat provider: %v (%s)", st, msg)
	}
	if g := list(adm.must(200, "GET", "/api/admin/generations", nil), "data"); len(g) != 1 || g[0].(map[string]any)["provider"] != "Uji 2" {
		t.Fatalf("log generate: %v", g)
	}

	// pengaturan: tutup pendaftaran → daftar tanpa undangan ditolak
	adm.must(200, "PUT", "/api/admin/settings", map[string]any{"registration_open": false, "daily_generations": 5, "max_pets": 3})
	newClient(t, ts).must(403, "POST", "/api/auth/register", map[string]any{"email": "baru@contoh.id", "name": "Baru", "handle": "baru", "password": "rahasia-banget"})
	inv := u.must(201, "POST", "/api/friends/invites", nil)
	newClient(t, ts).must(201, "POST", "/api/auth/register", map[string]any{"email": "baru@contoh.id", "name": "Baru", "handle": "baru",
		"password": "rahasia-banget", "invite": inv["code"]})
	if f := list(u.must(200, "GET", "/api/friends", nil), "friends"); len(f) != 1 {
		t.Fatalf("pendaftar lewat undangan harus langsung jadi teman: %v", f)
	}

	// moderasi: pengguna dinonaktifkan → sesi mati
	adm.must(200, "PATCH", "/api/admin/users/"+userID(t, s, "sari"), map[string]any{"disabled": true})
	u.must(401, "GET", "/api/pets", nil)
	if a := list(adm.must(200, "GET", "/api/admin/audit", nil), "data"); len(a) < 4 {
		t.Fatalf("audit: %v", a)
	}
	adm.must(200, "POST", "/api/admin/auth/logout", nil)
	adm.must(401, "GET", "/api/admin/overview", nil)
}

func userID(t *testing.T, s *Server, handle string) string {
	var id string
	if err := s.DB.QueryRow(`SELECT id FROM users WHERE handle=$1`, handle).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

var _ = sql.ErrNoRows

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }
