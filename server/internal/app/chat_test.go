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
