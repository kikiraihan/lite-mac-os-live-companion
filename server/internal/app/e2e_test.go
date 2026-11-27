package app

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"mime/multipart"
	"testing"
)

// e2eMac: "aplikasi Mac" dengan kunci keamanan (seperti E2E.swift). Hanya kunci tanda tangannya yang nyata;
// server tidak pernah membuka amplop, jadi amplop di tes cukup byte acak berukuran benar.
type e2eMac struct {
	*client
	device string
	sign   ed25519.PrivateKey
}

func withKeys(t *testing.T, mac *client) *e2eMac {
	t.Helper()
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	agree := make([]byte, 32)
	rand.Read(agree)
	sig := ed25519.Sign(priv, append([]byte(e2eKeyContext), agree...))
	body := map[string]any{"agree": b64(agree), "sign": b64(pub), "sig": b64(sig)}
	res := mac.must(200, "PUT", "/api/app/keys", body)
	mac.must(200, "PUT", "/api/app/keys", body) // kunci yang sama boleh dikirim ulang
	return &e2eMac{client: mac, device: res["device_id"].(string), sign: priv}
}

// seal: amplop untuk Mac-Mac ini, ditandatangani Mac pengirim
func (m *e2eMac) seal(to ...string) map[string]any {
	ct := make([]byte, 80)
	rand.Read(ct)
	env := &e2eEnvelope{V: 1, FromDevice: m.device, CT: b64(ct), Keys: map[string]string{}}
	for _, d := range to {
		e := make([]byte, e2eEnvelopeSize)
		rand.Read(e)
		env.Keys[d] = b64(e)
	}
	env.Sig = b64(ed25519.Sign(m.sign, e2eSigned(env)))
	raw, _ := json.Marshal(env)
	var out map[string]any
	json.Unmarshal(raw, &out)
	return out
}

func TestE2E(t *testing.T) {
	s, ts := testServer(t, true)
	kiki, dina, raka := register(t, ts, "kiki"), register(t, ts, "dina"), register(t, ts, "raka")
	kikiID, dinaID := userID(t, s, "kiki"), userID(t, s, "dina")
	inv := kiki.must(201, "POST", "/api/friends/invites", nil)
	dina.must(200, "POST", "/api/invites/"+inv["code"].(string)+"/accept", nil)
	kmacPlain, dmacPlain, rmac := linkMac(t, ts, kiki), linkMac(t, ts, dina), linkMac(t, ts, raka)

	// kunci tidak sah → 422; teman belum punya kunci → 409 (aplikasi lalu mengirim teks biasa)
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	agree := make([]byte, 32)
	kmacPlain.must(422, "PUT", "/api/app/keys", map[string]any{"agree": b64(agree), "sign": b64(pub), "sig": b64(make([]byte, 64))})
	kmac := withKeys(t, kmacPlain)
	kmac.must(409, "PUT", "/api/app/keys", map[string]any{"agree": b64(agree), "sign": b64(pub),
		"sig": b64(ed25519.Sign(priv, append([]byte(e2eKeyContext), agree...)))}) // kunci lain untuk Mac yang sama
	kmac.must(409, "POST", "/api/app/messages/"+dinaID, map[string]any{"e2e": kmac.seal(kmac.device)})

	// direktori kunci: hanya teman; jumlah Mac vs jumlah kunci
	rmac.must(404, "GET", "/api/app/keys/"+kikiID, nil)
	dir := kmac.must(200, "GET", "/api/app/keys/"+dinaID, nil)
	if dir["me"] != kmac.device || dir["friend"].(map[string]any)["devices"].(float64) != 1 ||
		len(list(dir["friend"].(map[string]any), "keys")) != 0 || len(list(dir["mine"].(map[string]any), "keys")) != 1 {
		t.Fatalf("direktori: %v", dir)
	}

	dmac := withKeys(t, dmacPlain)
	dws := dial(t, ts, dmac.bearer)
	next(t, dws) // hello

	// amplop kurang (Mac Dina tidak diberi) → 409 e2e_stale; Mac asing → 409; tanda tangan palsu → 422
	kmac.must(409, "POST", "/api/app/messages/"+dinaID, map[string]any{"e2e": kmac.seal(kmac.device)})
	kmac.must(409, "POST", "/api/app/messages/"+dinaID, map[string]any{"e2e": kmac.seal(kmac.device, dmac.device,
		"00000000-0000-0000-0000-000000000000")})
	forged := kmac.seal(kmac.device, dmac.device)
	forged["ct"] = b64([]byte("isi lain"))
	kmac.must(422, "POST", "/api/app/messages/"+dinaID, map[string]any{"e2e": forged})
	// Mac Dina tidak boleh mengaku sebagai Mac Kiki
	dmac.must(422, "POST", "/api/app/messages/"+kikiID, map[string]any{"e2e": kmac.seal(kmac.device, dmac.device)})

	// kirim → kolom text hanya label, ciphertext diteruskan apa adanya (juga lewat ws)
	env := kmac.seal(kmac.device, dmac.device)
	sent := kmac.must(201, "POST", "/api/app/messages/"+dinaID, map[string]any{"text": "rahasia", "e2e": env})["message"].(map[string]any)
	if sent["text"] != e2eTextLabel || sent["e2e"].(map[string]any)["ct"] != env["ct"] {
		t.Fatalf("kirim e2e: %v", sent)
	}
	if ev := next(t, dws); ev["message"].(map[string]any)["e2e"].(map[string]any)["sig"] != env["sig"] {
		t.Fatalf("ws e2e: %v", ev)
	}
	var stored string
	s.DB.QueryRow(`SELECT text FROM messages WHERE id=$1`, int64(sent["id"].(float64))).Scan(&stored)
	if stored != e2eTextLabel {
		t.Fatalf("teks asli tersimpan di server: %q", stored)
	}
	hist := list(dmac.must(200, "GET", "/api/app/messages/"+kikiID, nil), "messages")
	if last := hist[len(hist)-1].(map[string]any); last["e2e"] == nil || last["text"] != e2eTextLabel {
		t.Fatalf("riwayat e2e: %v", last)
	}

	// Mac baru Dina (belum punya kunci) tidak menghalangi; begitu punya kunci, wajib diberi amplop
	dmac2 := linkMac(t, ts, dina)
	kmac.must(201, "POST", "/api/app/messages/"+dinaID, map[string]any{"e2e": kmac.seal(kmac.device, dmac.device)})
	dmac2k := withKeys(t, dmac2)
	kmac.must(409, "POST", "/api/app/messages/"+dinaID, map[string]any{"e2e": kmac.seal(kmac.device, dmac.device)})
	kmac.must(201, "POST", "/api/app/messages/"+dinaID, map[string]any{"e2e": kmac.seal(kmac.device, dmac.device, dmac2k.device)})
	// Mac diputuskan → kuncinya ikut hilang
	dmac2k.must(200, "POST", "/api/app/unlink", nil)
	kmac.must(409, "POST", "/api/app/messages/"+dinaID, map[string]any{"e2e": kmac.seal(kmac.device, dmac.device, dmac2k.device)})

	// lampiran terenkripsi: nama & jenis asli tidak sampai ke server
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	mw.WriteField("once", "1")
	mw.WriteField("kind", "image")
	raw, _ := json.Marshal(kmac.seal(kmac.device, dmac.device))
	mw.WriteField("e2e", string(raw))
	fw, _ := mw.CreateFormFile("file", "liburan-bali.jpg")
	cipher := bytes.Repeat([]byte{7}, 300)
	fw.Write(cipher)
	mw.Close()
	code, res := kmac.do("POST", "/api/app/messages/"+dinaID+"/files", &multipartBody{&buf, mw.FormDataContentType()})
	if code != 201 {
		t.Fatalf("lampiran e2e = %d: %v", code, res)
	}
	m := res["message"].(map[string]any)
	a := m["attachment"].(map[string]any)
	if m["e2e"] == nil || a["kind"] != "image" || a["name"] != "Foto" || a["mime"] != "application/octet-stream" || a["once"] != true {
		t.Fatalf("lampiran e2e: %v", m)
	}
	if code, got := getFile(t, dmac.client, kikiID, m["id"]); code != 200 || !bytes.Equal(got, cipher) {
		t.Fatalf("unduh lampiran e2e = %d", code)
	}
	if code, _ := getFile(t, dmac.client, kikiID, m["id"]); code != 410 {
		t.Fatalf("sekali lihat e2e dibuka dua kali = %d", code)
	}
	var name string
	s.DB.QueryRow(`SELECT attach_name FROM messages WHERE id=$1`, int64(m["id"].(float64))).Scan(&name)
	if name != "Foto" {
		t.Fatalf("nama file asli tersimpan: %q", name)
	}

	// sesi web (pengguna) dan admin tidak punya jalan ke kunci
	if code, _ := kiki.do("GET", "/api/app/keys/"+dinaID, nil); code != 401 {
		t.Fatalf("sesi web membaca kunci = %d", code)
	}
}
