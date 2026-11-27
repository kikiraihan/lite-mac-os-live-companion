# Tech debt

Daftar pekerjaan yang sudah disadari tapi belum dikerjakan. Tiap butir: kenapa perlu, rencana, dan apa yang
belum diputuskan. Butir yang selesai dipindah ke catatan rilis, bukan dihapus diam-diam.

---

## 1. Enkripsi ujung ke ujung (E2EE) untuk obrolan

**Status:** **tahap 1 sudah jalan** (versi 1.17.0 — `server/internal/app/e2e.go`, `Sources/Temu/E2E.swift`).
Sisanya di bagian "Yang masih tertunda" di bawah. **Pesan lama dibiarkan apa adanya** (tetap teks biasa di
database, tetap terbaca seperti sekarang) — E2EE hanya berlaku untuk pesan yang dikirim setelah fitur ini aktif.

### Yang sudah dikerjakan (tahap 1)

- Kunci per Mac (X25519 + Ed25519, CryptoKit) di Keychain; kunci publik lewat `PUT /api/app/keys`, sekali per Mac
  (server menolak penggantian — Mac yang kehilangan kuncinya harus diputuskan lalu dihubungkan lagi).
- `GET /api/app/keys/{teman}`: kunci Mac teman + Mac milikku, beserta jumlah Mac yang tertaut.
- Pesan teks dan lampiran (gambar / file, termasuk sekali lihat) ke teman yang **semua** Mac-nya punya kunci
  dienkripsi di Mac pengirim; amplop untuk setiap Mac teman & Mac milikku; ditandatangani Mac pengirim.
  Server memeriksa tanda tangan dan kelengkapan amplop (409 `e2e_stale` → aplikasi mengambil kunci terbaru & kirim
  ulang sekali). Kolom `text` hanya label (`🔒 Pesan terenkripsi`, `📷 Foto`), nama file asli tidak disimpan.
- TOFU: kunci tanda tangan setiap Mac diingat; Mac yang sama dengan kunci lain → pesan ditolak.
- Tidak turun ke teks biasa: begitu obrolan dengan seorang teman pernah terenkripsi di Mac ini, Mac ini menolak
  mengirim teks biasa ke teman itu (mis. kunci tidak bisa diambil, atau teman menautkan Mac versi lama).
- Penanda "🔒 Pesan baru terenkripsi ujung ke ujung" di obrolan + tooltip per pesan.

Catatan perbedaan dari rancangan awal: amplop semua Mac ikut dikirim ke setiap Mac tujuan (bukan hanya amplop
miliknya). Aman — setiap amplop hanya bisa dibuka kunci privat Mac tujuannya — dan membuat saluran real-time
tidak perlu mengirim kabar berbeda per Mac.

### Yang masih tertunda

- **Nomor keamanan** untuk dicocokkan berdua (melawan server yang menyisipkan Mac palsu).
- **Pemberitahuan "Mac baru / kunci berubah"** di obrolan (sekarang: kunci berubah = pesan ditolak, Mac baru diterima
  diam-diam).
- **Double Ratchet** (forward secrecy per pesan) — tahap 2.
- **Emot lewat pet** masih terbuka (nama emotnya terlihat server).
- **Mac baru tidak bisa membaca riwayat E2EE** sebelum ia tertaut (tampil "Pesan terenkripsi untuk Mac lain").
- **Uji Swift otomatis** untuk enkripsi ↔ dekripsi bolak-balik (sekarang hanya dicek lewat build + uji jalan di CI).

### Kenapa

Sekarang isi obrolan (`messages.text`) dan isi lampiran (`message_files`) tersimpan apa adanya di PostgreSQL.
Siapa pun yang memegang server / cadangan database / akses admin bisa membacanya. Kesan Temu "hadir dan hangat,
bukan mengawasi" — server pun seharusnya tidak bisa membaca obrolan dua orang.

### Yang dilindungi dan yang tidak

| Terlindungi (server tidak bisa membaca) | Tetap terlihat server (metadata) |
|---|---|
| isi teks pesan | siapa mengirim ke siapa, kapan |
| isi lampiran (gambar / file), nama filenya | ukuran (kira-kira), jenis gambar/file, sekali lihat atau tidak |
| | status ✓ / ✓✓ / dibaca, online / offline |
| | nama emot lewat pet (lihat "Belum diputuskan") |

Bukan tujuan: menyembunyikan daftar teman, menyembunyikan kehadiran, melindungi dari Mac yang sudah dibobol.

### Prinsip

- **Tanpa dependensi baru.** Aplikasi Mac memakai **CryptoKit** bawaan macOS (target 13.0 sudah cukup):
  `Curve25519.KeyAgreement` (X25519), `Curve25519.Signing` (Ed25519), `HKDF<SHA256>`, `ChaChaPoly`.
  Server (Go) tidak perlu mendekripsi apa pun — cukup menyimpan dan meneruskan byte.
- **Kunci privat tidak pernah keluar dari Mac.** Disimpan di Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, tidak ikut sinkron iCloud), di samping token perangkat.
- **Per perangkat, bukan per akun.** Satu pengguna bisa menautkan beberapa Mac (`devices`), jadi setiap pesan
  dienkripsi ke setiap Mac penerima **dan** Mac lain milik pengirim (model "fan-out" seperti WhatsApp multi-device).
- **Server tetap jujur soal aturan lama**: lampiran tetap hilang sehari, sekali lihat tetap dihapus di unduhan
  pertama — yang berubah hanya isinya jadi ciphertext.

### Rancangan

**Kunci tiap Mac** (dibuat saat pertama kali tertaut / saat update ke versi E2EE):

- `identity` — Ed25519, kunci identitas jangka panjang perangkat.
- `signed prekey` — X25519, ditandatangani `identity`, diganti berkala (mis. 30 hari).
- `one-time prekeys` — X25519, sekumpulan (mis. 50), diisi ulang saat menipis.

**Tahap 1 — sederhana dulu (tanpa ratchet):** tiap pesan memakai kunci acak baru.

```
pesan  : kunci_pesan = 32 byte acak
         isi = ChaChaPoly.seal(teks/JSON, kunci_pesan)
amplop : untuk tiap Mac tujuan d:
           eph = X25519 sementara
           k   = HKDF(X25519(eph, prekey_d), info: "temu-e2e-v1" ‖ id_pengirim ‖ id_d)
           amplop_d = ChaChaPoly.seal(kunci_pesan, k) + eph.publicKey + id prekey yang dipakai
         ditandatangani identity pengirim (penerima tahu benar dari Mac teman, bukan dari server)
```

Ini sudah membuat server buta isi, tapi belum punya *forward secrecy* penuh kalau signed prekey bocor.

**Tahap 2 — Double Ratchet (seperti Signal / WhatsApp):** X3DH untuk membuka sesi antar dua Mac, lalu
Double Ratchet untuk tiap pesan. Dikerjakan setelah tahap 1 stabil; format amplop diberi `v` supaya bisa naik versi.

**Lampiran:** file dienkripsi di Mac dengan kunci acak (ChaChaPoly, dipotong per 64 KB supaya file 10 MB tidak
perlu dimuat sekaligus); kunci + nama file asli + jenis MIME ikut di dalam isi pesan terenkripsi. Server hanya
menyimpan ciphertext di `message_files` seperti sekarang. Batas 10 MB dihitung dari ciphertext.

**Pratinjau / balon kata pet:** teks didekripsi di Mac penerima, lalu tampil seperti biasa. `messages.text`
untuk pesan E2EE diisi label netral (`🔒 Pesan`, `📷 Foto`) supaya aplikasi lama dan kabar ringkas tetap jalan
tanpa membocorkan isi.

### Perubahan per bagian

_Rancangan asli (untuk tahap berikutnya; sebagian sudah dikerjakan seperti di atas):_

**Server (`server/`)**

- Migrasi baru:
  - `device_keys(device_id, identity_pub, signed_prekey_pub, signed_prekey_sig, prekey_id, updated_at)`
  - `device_one_time_prekeys(device_id, key_id, pub)` — diambil satu lalu dihapus (`DELETE … RETURNING`).
  - `message_envelopes(message_id, device_id, envelope BYTEA)` — satu baris per Mac tujuan.
  - `messages.e2e BOOLEAN NOT NULL DEFAULT false`, `messages.ciphertext BYTEA`.
- Endpoint (semua di `/api/app/*`, token perangkat, memakai `who(r)`):
  - `PUT  /api/app/keys` — unggah / perbarui kunci publik Mac ini.
  - `GET  /api/app/keys/{friend}` — kunci publik semua Mac teman **dan** Mac lain milikku (cek `canSeePet` /
    pertemanan seperti endpoint obrolan lain).
  - `POST /api/app/messages/{id}` menerima `{ciphertext, envelopes:[{device_id, envelope}], label}`; server
    menolak kalau ada Mac tujuan aktif yang tidak diberi amplop (supaya tidak ada Mac yang "ketinggalan").
  - Riwayat & kabar `message`: tiap Mac hanya menerima amplop miliknya sendiri.
- Validasi teks (`clean`, `maxMessage`, "pesannya masih kosong") pindah ke aplikasi Mac; server hanya membatasi
  ukuran ciphertext. Batas kecepatan (30 pesan/menit) tetap.
- Admin **tidak** mendapat endpoint apa pun untuk kunci atau amplop.

**Aplikasi Mac (`Sources/Temu/`)**

- File baru `E2E.swift`: buat / simpan kunci, enkripsi, dekripsi, verifikasi tanda tangan.
- `Client.swift`: unggah kunci saat tertaut, ambil kunci teman (disimpan di memori + Keychain untuk TOFU),
  kirim amplop, dekripsi pesan masuk sebelum masuk ke `PopoverModel.threads`.
- `Attachments.swift` / `SendPreview.swift`: enkripsi file setelah pratinjau, sebelum unggah; dekripsi setelah unduh.
- **Nomor keamanan** (Pengaturan › Pesan, atau klik kanan nama teman): 60 digit dari kunci identitas kedua pihak,
  bisa dicocokkan langsung / lewat telepon.
- **Pemberitahuan kunci berubah** di obrolan: "Mac Dina berganti kunci keamanan (Mac baru atau Temu dipasang
  ulang)." — tidak memblokir, hanya memberi tahu (seperti WhatsApp).
- Gembok kecil di kepala obrolan, tooltip: "Pesan di obrolan ini terenkripsi ujung ke ujung…".

**Web (`web/`)** — tidak ada obrolan di web, jadi tidak ada penyimpanan kunci di browser. Halaman Mac (`Mac.vue`)
cukup menyebut "Pesan baru terenkripsi ujung ke ujung" dan bahwa melepas tautan Mac = Mac itu tidak bisa membaca
pesan baru lagi.

**Dokumen** — perbarui `AGENTS.md` ("Aplikasi Mac tidak pernah memegang password": tambah bahwa Mac juga
memegang kunci privat E2EE di Keychain; aturan baru "server tidak pernah menerima kunci privat / teks asli
pesan E2EE") dan `README.md`.

### Peralihan (pesan lama dibiarkan)

1. Rilis aplikasi Mac yang bisa **membaca** pesan E2EE dan mengunggah kunci, tapi belum mengirim E2EE.
2. Setelah sebagian besar Mac sudah update: aplikasi mulai **mengirim** E2EE ke teman yang **semua** Mac-nya
   sudah punya kunci; ke teman yang belum, tetap teks biasa + keterangan kecil "belum terenkripsi — minta temanmu
   memperbarui Temu".
3. Pesan dan lampiran lama tetap teks biasa; tidak dimigrasi, tidak dienkripsi ulang. Lampiran lama tetap hilang
   sendiri dalam sehari.
4. Nanti (opsional): hentikan pengiriman teks biasa sama sekali; Mac lama melihat label `🔒 Perbarui Temu untuk
   membaca pesan ini`.

Versi: tahap 1 = naik `b` (fitur baru, format lama tetap terbaca). Menghentikan teks biasa = naik `a`.

### Belum diputuskan

- **Emot lewat pet**: nama emot (`reaction`) dikirim terbuka supaya server bisa memvalidasi daftar dan emot
  sesaat tetap cepat. Usul: biarkan terbuka di tahap 1 (isinya hanya "love"/"haha"), enkripsi di tahap 2.
- **Mac baru tidak bisa membaca riwayat E2EE** sebelum ia tertaut (wajar untuk E2EE). Perlu transfer riwayat
  dari Mac lama (lewat amplop ke Mac baru) atau cukup diberi keterangan "Pesan sebelum Mac ini tertaut tidak
  bisa dibaca di sini".
- **Server jahat menyisipkan Mac palsu**: tahap 1 mengandalkan TOFU + pemberitahuan "Mac baru" + nomor keamanan.
  Lebih kuat: Mac baru harus ditandatangani Mac lama milik pengguna yang sama (alur tautan lewat Mac, bukan
  hanya web). Perlu diputuskan sebelum tahap 2.
- **Cadangan kunci**: tidak ada (seperti WhatsApp tanpa cadangan). Semua Mac hilang = pesan E2EE lama hilang.

### Uji yang perlu ada

- Go: server menolak kiriman tanpa amplop untuk semua Mac tujuan; Mac A tidak menerima amplop Mac B; sekali lihat
  E2EE tetap terhapus di unduhan pertama; admin tidak punya rute ke kunci / amplop.
- Swift (CI macOS): uji enkripsi ↔ dekripsi bolak-balik, tanda tangan salah ditolak, amplop untuk Mac lain gagal
  dibuka; tangkapan layar `--demo` dengan gembok dan pemberitahuan kunci berubah.
