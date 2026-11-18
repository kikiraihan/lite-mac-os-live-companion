package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// linkMac: hubungkan satu "aplikasi Mac" ke akun pemilik sesi web `owner`.
func linkMac(t *testing.T, ts *httptest.Server, owner *client) *client {
	t.Helper()
	mac := newClient(t, ts)
	start := mac.must(201, "POST", "/api/app/link/start", map[string]any{"device_name": "Mac"})
	owner.must(200, "POST", "/api/link/"+start["code"].(string)+"/approve", nil)
	mac.bearer = mac.must(200, "POST", "/api/app/link/poll", map[string]any{"poll_token": start["poll_token"]})["token"].(string)
	return mac
}

// dial membuka saluran real-time /api/app/ws dengan token perangkat.
func dial(t *testing.T, ts *httptest.Server, token string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/api/app/ws",
		&websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + token}}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.CloseNow() })
	return ws
}

func next(t *testing.T, ws *websocket.Conn) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, b, err := ws.Read(ctx)
	if err != nil {
		t.Fatalf("baca ws: %v", err)
	}
	var m map[string]any
	json.Unmarshal(b, &m)
	return m
}

func TestChat(t *testing.T) {
	s, ts := testServer(t, true)
	kiki, dina, raka := register(t, ts, "kiki"), register(t, ts, "dina"), register(t, ts, "raka")
	kikiID, dinaID, rakaID := userID(t, s, "kiki"), userID(t, s, "dina"), userID(t, s, "raka")
	inv := kiki.must(201, "POST", "/api/friends/invites", nil)
	dina.must(200, "POST", "/api/invites/"+inv["code"].(string)+"/accept", nil)
	kmac, dmac, rmac := linkMac(t, ts, kiki), linkMac(t, ts, dina), linkMac(t, ts, raka)

	// tanpa token → saluran ditolak
	if _, _, err := websocket.Dial(context.Background(), "ws"+strings.TrimPrefix(ts.URL, "http")+"/api/app/ws", nil); err == nil {
		t.Fatal("ws tanpa token diterima")
	}
	dws := dial(t, ts, dmac.bearer)
	if h := next(t, dws); h["type"] != "hello" {
		t.Fatalf("hello: %v", h)
	}

	// bukan teman / diri sendiri → 404; pesan kosong → 422
	rmac.must(404, "POST", "/api/app/messages/"+kikiID, map[string]any{"text": "halo"})
	kmac.must(404, "POST", "/api/app/messages/"+kikiID, map[string]any{"text": "halo"})
	kmac.must(422, "POST", "/api/app/messages/"+dinaID, map[string]any{"text": "   "})
	kmac.must(404, "GET", "/api/app/messages/"+rakaID, nil)

	// Kiki mengirim → Mac Dina langsung menerima lewat ws
	sent := kmac.must(201, "POST", "/api/app/messages/"+dinaID, map[string]any{"text": "  makan   siang yuk "})
	if sent["message"].(map[string]any)["text"] != "makan siang yuk" {
		t.Fatalf("kirim: %v", sent)
	}
	ev := next(t, dws)
	if ev["type"] != "message" || ev["friend_id"] != kikiID || ev["friend_name"] != "Kiki" || ev["message"].(map[string]any)["mine"] != false {
		t.Fatalf("kabar pesan: %v", ev)
	}

	// belum dibaca: di sync dan di hello saat menyambung ulang
	unreadOK := func(v any) bool {
		l, _ := v.([]any)
		if len(l) != 1 {
			return false
		}
		e := l[0].(map[string]any)
		return e["friend_id"] == kikiID && e["friend_name"] == "Kiki" && e["count"] == float64(1)
	}
	if u := dmac.must(200, "GET", "/api/app/sync", nil)["unread"]; !unreadOK(u) {
		t.Fatalf("unread sync: %v", u)
	}
	// daftar teman di sync: Kiki saja (Raka bukan teman Dina)
	if f := list(dmac.must(200, "GET", "/api/app/sync", nil), "friends"); len(f) != 1 || f[0].(map[string]any)["id"] != kikiID {
		t.Fatalf("teman di sync: %v", f)
	}
	if h := next(t, dial(t, ts, dmac.bearer)); !unreadOK(h["unread"]) {
		t.Fatalf("unread hello: %v", h)
	}

	// riwayat dari sisi Dina, lalu tandai dibaca → kabar "read" ke Mac Dina
	dmac.must(201, "POST", "/api/app/messages/"+kikiID, map[string]any{"text": "ayo!"})
	next(t, dws) // salinan pesan Dina sendiri
	hist := dmac.must(200, "GET", "/api/app/messages/"+kikiID, nil)
	msgs := list(hist, "messages")
	if len(msgs) != 2 || msgs[0].(map[string]any)["mine"] != false || msgs[1].(map[string]any)["mine"] != true {
		t.Fatalf("riwayat: %v", hist)
	}
	dmac.must(200, "POST", "/api/app/messages/"+kikiID+"/read", nil)
	if ev := next(t, dws); ev["type"] != "read" || ev["friend_id"] != kikiID {
		t.Fatalf("kabar dibaca: %v", ev)
	}
	if u := list(dmac.must(200, "GET", "/api/app/sync", nil), "unread"); len(u) != 0 {
		t.Fatalf("unread setelah dibaca: %v", u)
	}

	// sapaan juga memberi kabar supaya Mac langsung sinkron
	kiki.must(201, "POST", "/api/friends/"+dinaID+"/nudge", map[string]any{"text": "hai"})
	if ev := next(t, dws); ev["type"] != "nudge" {
		t.Fatalf("kabar sapaan: %v", ev)
	}

	// halaman lama
	for i := 0; i < 55; i++ {
		s.DB.Exec(`INSERT INTO messages(from_user, to_user, text) VALUES($1,$2,$3)`, kikiID, dinaID, fmt.Sprint("isi ", i))
	}
	page := kmac.must(200, "GET", "/api/app/messages/"+dinaID, nil)
	if len(list(page, "messages")) != 50 || page["has_more"] != true {
		t.Fatalf("halaman: %d %v", len(list(page, "messages")), page["has_more"])
	}
	first := list(page, "messages")[0].(map[string]any)["id"].(float64)
	older := kmac.must(200, "GET", fmt.Sprintf("/api/app/messages/%s?before=%d", dinaID, int64(first)), nil)
	if len(list(older, "messages")) != 7 || older["has_more"] != false {
		t.Fatalf("halaman lama: %v", older)
	}

	// token dicabut → saluran diputus server
	devs := list(dina.must(200, "GET", "/api/devices", nil), "data")
	dina.must(200, "DELETE", "/api/devices/"+devs[0].(map[string]any)["id"].(string), nil)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, _, err := dws.Read(ctx); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("ws tidak diputus: %v", err)
	}

	// putus teman → tidak bisa kirim lagi
	kiki.must(200, "DELETE", "/api/friends/"+dinaID, nil)
	kmac.must(404, "POST", "/api/app/messages/"+dinaID, map[string]any{"text": "masih di sana?"})
}

func TestPresence(t *testing.T) {
	s, ts := testServer(t, true)
	s.live.grace = 50 * time.Millisecond // sebelum ada koneksi
	kiki, dina, raka := register(t, ts, "kiki"), register(t, ts, "dina"), register(t, ts, "raka")
	kikiID, dinaID := userID(t, s, "kiki"), userID(t, s, "dina")
	inv := kiki.must(201, "POST", "/api/friends/invites", nil)
	dina.must(200, "POST", "/api/invites/"+inv["code"].(string)+"/accept", nil)
	kmac, dmac, rmac := linkMac(t, ts, kiki), linkMac(t, ts, dina), linkMac(t, ts, raka)

	onlineIn := func(sync map[string]any, id string) bool {
		for _, f := range list(sync, "friends") {
			if m := f.(map[string]any); m["id"] == id {
				return m["online"] == true
			}
		}
		t.Fatalf("teman %s tidak ada di sync", id)
		return false
	}

	// Dina belum membuka saluran → offline di mata Kiki
	if onlineIn(kmac.must(200, "GET", "/api/app/sync", nil), dinaID) {
		t.Fatal("Dina online padahal belum tersambung")
	}

	kws := dial(t, ts, kmac.bearer)
	if h := next(t, kws); h["type"] != "hello" || len(h["online_friends"].([]any)) != 0 {
		t.Fatalf("hello Kiki: %v", h)
	}
	rws := dial(t, ts, rmac.bearer) // Raka bukan teman: tidak boleh mendapat kabar Dina
	next(t, rws)

	// Dina tersambung → Kiki mendapat kabar online, dan hello Dina menyebut Kiki online
	dws := dial(t, ts, dmac.bearer)
	if h := next(t, dws); len(h["online_friends"].([]any)) != 1 || h["online_friends"].([]any)[0] != kikiID {
		t.Fatalf("hello Dina: %v", h)
	}
	if ev := next(t, kws); ev["type"] != "presence" || ev["friend_id"] != dinaID || ev["online"] != true {
		t.Fatalf("kabar online: %v", ev)
	}
	if !onlineIn(kmac.must(200, "GET", "/api/app/sync", nil), dinaID) {
		t.Fatal("Dina tidak online di sync")
	}

	// Mac kedua Dina tidak memberi kabar ulang; menutup satu Mac tidak membuat Dina offline
	dws2 := dial(t, ts, dmac.bearer)
	next(t, dws2)
	dws2.Close(websocket.StatusNormalClosure, "")
	time.Sleep(200 * time.Millisecond)
	if !onlineIn(kmac.must(200, "GET", "/api/app/sync", nil), dinaID) {
		t.Fatal("Dina offline padahal satu Mac masih tersambung")
	}

	// Mac terakhir ditutup → setelah jeda, Kiki mendapat kabar offline
	dws.Close(websocket.StatusNormalClosure, "")
	if ev := next(t, kws); ev["type"] != "presence" || ev["friend_id"] != dinaID || ev["online"] != false {
		t.Fatalf("kabar offline: %v", ev)
	}
	if onlineIn(kmac.must(200, "GET", "/api/app/sync", nil), dinaID) {
		t.Fatal("Dina masih online di sync")
	}

	// web: daftar teman membawa status online juga
	webOnline := func(id string) bool {
		for _, f := range list(kiki.must(200, "GET", "/api/friends", nil), "friends") {
			if m := f.(map[string]any); m["id"] == id {
				return m["online"] == true
			}
		}
		t.Fatalf("teman %s tidak ada di /api/friends", id)
		return false
	}
	if webOnline(dinaID) {
		t.Fatal("web: Dina online padahal sudah menutup Temu")
	}

	// Dina menyembunyikan status saat sedang online → Kiki langsung melihatnya offline
	dws = dial(t, ts, dmac.bearer)
	next(t, dws)
	if ev := next(t, kws); ev["online"] != true {
		t.Fatalf("kabar online lagi: %v", ev)
	}
	if !webOnline(dinaID) {
		t.Fatal("web: Dina tidak online")
	}
	if r := dmac.must(200, "PUT", "/api/app/presence", map[string]any{"hidden": true}); r["hidden"] != true {
		t.Fatalf("sembunyikan: %v", r)
	}
	if ev := next(t, kws); ev["type"] != "presence" || ev["friend_id"] != dinaID || ev["online"] != false {
		t.Fatalf("kabar sembunyi: %v", ev)
	}
	if onlineIn(kmac.must(200, "GET", "/api/app/sync", nil), dinaID) || webOnline(dinaID) {
		t.Fatal("status Dina masih terlihat online")
	}
	if h := next(t, dial(t, ts, kmac.bearer)); len(h["online_friends"].([]any)) != 0 {
		t.Fatalf("hello menyebut Dina online: %v", h)
	}
	if u := dmac.must(200, "GET", "/api/app/sync", nil)["user"].(map[string]any); u["hide_presence"] != true {
		t.Fatalf("sync user: %v", u)
	}
	dmac.must(422, "PUT", "/api/app/presence", map[string]any{})

	// tersembunyi: menutup & membuka Temu tidak memberi kabar apa pun
	dws.Close(websocket.StatusNormalClosure, "")
	dws = dial(t, ts, dmac.bearer)
	next(t, dws)
	// quiet: tidak ada kabar dalam 200 ms. Batas waktu baca menutup koneksinya, jadi Kiki menyambung ulang sesudahnya.
	quiet := func(ws *websocket.Conn, who string) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
		defer cancel()
		if _, b, err := ws.Read(ctx); err == nil {
			t.Fatalf("%s menerima kabar: %s", who, b)
		}
	}
	time.Sleep(200 * time.Millisecond) // lewat jeda offline
	quiet(kws, "Kiki")
	kws = dial(t, ts, kmac.bearer)
	next(t, kws)

	// ditampilkan lagi lewat web (Akun) → kabar online; /api/auth/me ikut berubah
	if u := dina.must(200, "PATCH", "/api/auth/me", map[string]any{"hide_presence": false})["user"].(map[string]any); u["hide_presence"] != false {
		t.Fatalf("auth/me: %v", u)
	}
	if ev := next(t, kws); ev["friend_id"] != dinaID || ev["online"] != true {
		t.Fatalf("kabar tampil lagi: %v", ev)
	}
	// menyimpan nilai yang sama tidak memberi kabar ulang
	dina.must(200, "PATCH", "/api/auth/me", map[string]any{"hide_presence": false})
	quiet(kws, "Kiki")

	// Raka tidak menerima kabar apa pun
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	if _, b, err := rws.Read(ctx); err == nil {
		t.Fatalf("Raka menerima kabar: %s", b)
	}
}
