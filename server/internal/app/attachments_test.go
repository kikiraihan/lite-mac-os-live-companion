package app

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"testing"
)

// sendFile: kirim lampiran dari "aplikasi Mac" (bearer), seperti Client.swift
func sendFile(t *testing.T, mac *client, friend, name string, data []byte, once bool) (int, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	if once {
		mw.WriteField("once", "1")
	}
	fw, _ := mw.CreateFormFile("file", name)
	fw.Write(data)
	mw.Close()
	return mac.do("POST", "/api/app/messages/"+friend+"/files", &multipartBody{&buf, mw.FormDataContentType()})
}

// multipartBody: badan multipart untuk client.do (app_test.go)
type multipartBody struct {
	buf *bytes.Buffer
	ct  string
}

// getFile: unduh isi lampiran → (status, isi)
func getFile(t *testing.T, mac *client, friend string, msg any) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest("GET", mac.base+"/api/app/messages/"+friend+"/files/"+fmt.Sprint(msg), nil)
	req.Header.Set("Authorization", "Bearer "+mac.bearer)
	resp, err := mac.http.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

func TestAttachments(t *testing.T) {
	s, ts := testServer(t, true)
	kiki, dina, raka := register(t, ts, "kiki"), register(t, ts, "dina"), register(t, ts, "raka")
	kikiID, dinaID := userID(t, s, "kiki"), userID(t, s, "dina")
	inv := kiki.must(201, "POST", "/api/friends/invites", nil)
	dina.must(200, "POST", "/api/invites/"+inv["code"].(string)+"/accept", nil)
	kmac, dmac, rmac := linkMac(t, ts, kiki), linkMac(t, ts, dina), linkMac(t, ts, raka)
	dws := dial(t, ts, dmac.bearer)
	next(t, dws) // hello

	png := append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{1}, 100)...)

	// bukan teman → 404; file kosong → 422; kebesaran → 413
	if code, _ := sendFile(t, rmac, kikiID, "a.png", png, false); code != 404 {
		t.Fatalf("bukan teman: %d", code)
	}
	if code, _ := sendFile(t, kmac, dinaID, "a.png", nil, false); code != 422 {
		t.Fatalf("kosong: %d", code)
	}
	if code, _ := sendFile(t, kmac, dinaID, "besar.bin", make([]byte, maxAttachment+1), false); code != 413 {
		t.Fatalf("kebesaran: %d", code)
	}

	// gambar biasa: label di text, keterangan di attachment, kabar ke Mac Dina
	code, out := sendFile(t, kmac, dinaID, "../../liburan.png", png, false)
	if code != 201 {
		t.Fatalf("kirim gambar: %d %v", code, out)
	}
	m := out["message"].(map[string]any)
	a := m["attachment"].(map[string]any)
	if m["text"] != "📷 Foto" || a["kind"] != "image" || a["name"] != "liburan.png" || a["available"] != true || a["once"] != false {
		t.Fatalf("pesan gambar: %v", m)
	}
	if ev := next(t, dws); ev["type"] != "message" || ev["message"].(map[string]any)["attachment"] == nil {
		t.Fatalf("kabar gambar: %v", ev)
	}
	// bisa diunduh berkali-kali oleh dua pihak; Raka tidak
	for _, mac := range []*client{dmac, dmac, kmac} {
		friend := kikiID
		if mac == kmac {
			friend = dinaID
		}
		if code, b := getFile(t, mac, friend, m["id"]); code != 200 || !bytes.Equal(b, png) {
			t.Fatalf("unduh gambar: %d", code)
		}
	}
	if code, _ := getFile(t, rmac, kikiID, m["id"]); code != 404 {
		t.Fatalf("Raka mengunduh: %d", code)
	}

	// sekali lihat: pengirim tidak bisa membuka; penerima sekali saja, lalu kedua pihak diberi kabar
	code, out = sendFile(t, kmac, dinaID, "rahasia.pdf", []byte("%PDF-1.4 isi"), true)
	if code != 201 {
		t.Fatalf("kirim sekali lihat: %d %v", code, out)
	}
	once := out["message"].(map[string]any)
	if a := once["attachment"].(map[string]any); once["text"] != "📎 File sekali unduh" || a["kind"] != "file" || a["mime"] != "application/pdf" || a["once"] != true {
		t.Fatalf("pesan sekali lihat: %v", once)
	}
	next(t, dws)
	kws := dial(t, ts, kmac.bearer)
	next(t, kws) // hello
	if code, _ := getFile(t, kmac, dinaID, once["id"]); code != 403 {
		t.Fatalf("pengirim membuka sekali lihat: %d", code)
	}
	if code, b := getFile(t, dmac, kikiID, once["id"]); code != 200 || string(b) != "%PDF-1.4 isi" {
		t.Fatalf("buka sekali lihat: %d", code)
	}
	if code, _ := getFile(t, dmac, kikiID, once["id"]); code != 410 {
		t.Fatalf("buka kedua kali: %d", code)
	}
	if ev := next(t, kws); ev["type"] != "file_opened" || ev["friend_id"] != dinaID || ev["message_id"] != once["id"] {
		t.Fatalf("kabar dibuka ke pengirim: %v", ev)
	}
	ev := next(t, dws)
	if ev["type"] == "presence" { // Kiki baru tersambung
		ev = next(t, dws)
	}
	if ev["type"] != "file_opened" || ev["friend_id"] != kikiID {
		t.Fatalf("kabar dibuka ke penerima: %v", ev)
	}

	// riwayat: keterangan tetap ada, isinya tidak
	msgs := list(dmac.must(200, "GET", "/api/app/messages/"+kikiID, nil), "messages")
	last := msgs[len(msgs)-1].(map[string]any)["attachment"].(map[string]any)
	if last["available"] != false || last["opened"] != true {
		t.Fatalf("riwayat sekali lihat: %v", last)
	}

	// lewat sehari → unduhan ditolak walau belum dibersihkan, lalu pembersih menghapus isinya
	s.DB.Exec(`UPDATE messages SET attach_expires_at = now() - interval '1 minute' WHERE id=$1`, m["id"])
	if code, _ := getFile(t, dmac, kikiID, m["id"]); code != 410 {
		t.Fatalf("unduh kedaluwarsa: %d", code)
	}
	if n, err := s.cleanupFiles(context.Background()); err != nil || n != 1 {
		t.Fatalf("pembersih: %d %v", n, err)
	}
	msgs = list(dmac.must(200, "GET", "/api/app/messages/"+kikiID, nil), "messages")
	if a := msgs[0].(map[string]any)["attachment"].(map[string]any); a["available"] != false || a["name"] != "liburan.png" {
		t.Fatalf("riwayat kedaluwarsa: %v", a)
	}
}
