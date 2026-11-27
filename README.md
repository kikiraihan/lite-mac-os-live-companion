# Temu

**A little way to be together.**

*Temu* — bertemu, terhubung, menghadirkan diri. Temu menaruh versi pixel kecil dirimu (atau pet-mu) di layar
Mac orang terdekatmu: pasangan, sahabat, keluarga. Dia jalan-jalan di tepi bawah layar, ketiduran, joget
sendiri, bersin, mengejar kupu-kupu, kadang pulang membawa bunga, dan menyampaikan sapaanmu. Ikonnya di menu
bar ikut bergerak. Jauh, tapi rasanya tetap di sebelah.

Buat dirimu versi pixel dari foto (atau gambar sendiri), undang dia, dan begitu dia mengizinkan, kamu ikut
hidup di desktop-nya.

![Pet bawaan dalam 16 pose](docs/sprites.png)

> **Cuma mainan.** Aplikasi Mac-nya tidak membaca layar, ketikan, atau berkas, dan tidak meminta izin
> Aksesibilitas atau Perekaman Layar. Lihat [Keamanan](#keamanan).

## Isi repo

| Bagian | Folder | Teknologi |
|---|---|---|
| Aplikasi Mac (menu bar + pet di desktop) | `Sources/Temu/` | Swift + AppKit, tanpa dependensi |
| Server (API, admin, worker generate) | `server/` | Go + PostgreSQL |
| Web pengguna & ruang admin | `web/` | Vue 3 + Vite |

## Yang bisa dilakukan

**Pet di Mac**

- Berjalan, berlari, rebahan, tidur (lebih sering di malam hari), melompat, joget, melambai.
- Kejutan: bersin, tersandung, mengejar kupu-kupu, main bola, pergi lalu pulang membawa hadiah yang bisa diklik.
- Klik = dielus. Klik dua kali = lompat + lelucon. Seret = diangkat, lepas = jatuh (kalau tinggi, pusing).
- Menu: beri makan, ajak main bola, panggil ke layar tempat kursor berada, sembunyikan dari desktop.
- Pengingat lembut (minum air, regangkan badan) kalau dinyalakan.
- Tanpa akun pun jalan: pilih salah satu dari lima pet bawaan di Pengaturan.

**Akun & web**

- Tiga cara membuat pet: pilih bawaan, gambar di editor piksel (16 pose × 32×32), atau dari foto.
- Dari foto: otomatis lewat AI yang diatur admin (kenari.id / OpenRouter), atau manual — salin prompt +
  contoh tata letak ke ChatGPT, lalu unggah hasilnya. Server memotong, membuang latar, dan merapikannya jadi pixel art.
- Teman: undang lewat tautan atau nama pengguna. Minta pet teman; setelah diizinkan, pet itu ikut tampil di Mac-mu.
- Sapa teman: pet di Mac-nya yang menyampaikan pesanmu.
- Chat dari Mac: **klik ikon Temu di menu bar** → popover yang langsung berisi obrolan (deretan teman di atas,
  avatarnya pet mereka), dengan aksi pet (kasih makan, main bola, panggil, tampil/sembunyi), status akun, web,
  dan pengaturan di bawahnya. **⌘-klik pet teman** di desktop membuka obrolan dengannya. Klik kanan ikon tetap
  membuka menu lengkap. Pesan sampai real-time lewat WebSocket; ada titik merah di ikon menu bar saat ada pesan
  belum dibaca, dan bunyi pesan yang bisa diatur / dimatikan di Pengaturan → Umum → Pesan.
- Kirim gambar & file di obrolan (tombol 📎, maksimal 10 MB): tersimpan di server **sehari**, lalu terhapus
  otomatis. Pilihan **sekali lihat** (seperti WhatsApp): hanya penerima yang bisa membuka, sekali saja, dan isinya
  langsung dihapus dari server begitu dibuka. Bisa juga **⌘V (atau ⌃V)** di kolom tulis: gambar di clipboard
  (mis. tangkapan layar) atau file yang disalin di Finder tampil di pratinjau dulu — gambar bisa dipotong / diputar,
  tombol **1** (transparan → putih) menyalakan sekali lihat — lalu dikirim; teks ditempel seperti biasa. Gambar yang
  dipilih lewat 📎 juga lewat pratinjau yang sama.

**Admin** (`/admin`, akun & sesi terpisah dari pengguna)

- Ringkasan, pengguna (nonaktifkan), pet (sembunyikan), riwayat generate, jejak audit, akun admin.
- **Koneksi AI**: tambah / ubah / tes koneksi ke kenari.id, OpenRouter, atau endpoint kompatibel OpenAI;
  ambil daftar model dari provider; atur prioritas cadangan. API key disimpan terenkripsi.
- Pengaturan: buka/tutup pendaftaran, jatah generate harian, batas pet, prompt generate.

## Pasang aplikasi Mac

1. Unduh `Temu.zip` dari [Releases](../../releases/latest), ekstrak, pindahkan `Temu.app` ke **Applications**.
2. Sekali saja (aplikasi belum dinotarisasi Apple):
   ```bash
   xattr -cr /Applications/Temu.app
   ```
   ```bash
   open /Applications/Temu.app
   ```
3. Klik ikon pet di menu bar → **Hubungkan akun…** untuk memakai pet buatanmu. Browser terbuka dengan sebuah
   kode; setujui di sana. Password tidak pernah diketik di aplikasi.

Atau build sendiri:

```bash
./scripts/build.sh
```

```bash
cp -R build/Temu.app /Applications/
```

Syarat: macOS 13 (Ventura) ke atas, Apple Silicon atau Intel.

## Menjalankan server & web

Dengan Docker (lihat [DEPLOY.md](DEPLOY.md) untuk VPS, atau [AGENT_SETUP_VM.md](AGENT_SETUP_VM.md) kalau dipasang oleh AI agent):

```bash
cp .env.example .env
```

```bash
make up
```

```bash
make admin EMAIL=kamu@contoh.id PASSWORD='password-panjang'
```

Lokal tanpa Docker (butuh PostgreSQL):

```bash
make build-web
```

```bash
make dev-server
```

`make dev-server` memakai `AI_MOCK=1`, jadi generate dari foto bisa dicoba tanpa API key. Untuk mengembangkan
web dengan hot reload, jalankan `make dev-web` di terminal lain (port 5173, `/api` diteruskan ke :8080).

Aplikasi Mac bawaan menunjuk ke `https://temu.katili.dev`. Untuk server sendiri: Pengaturan → Akun → Alamat server.

## Cara kerja singkat

```
Sprites.swift (teks → piksel) ──make sprites──► template PNG server + docs/sprites.png

web  ──cookie sesi + CSRF──►  /api/…          pengguna
web  ──cookie admin + CSRF──► /api/admin/…    admin (tabel, sesi, cookie sendiri)
Mac  ──token perangkat─────►  /api/app/…      daftar pet yang tampil di Mac + sapaan + pesan
Mac  ◄──WebSocket (token)───  /api/app/ws     kabar real-time: pesan baru, sudah dibaca, sapaan

foto ─► provider AI (koneksi admin) ─► gambar grid 4×4 ─► sprite.Normalize ─► sheet 128×128 ─► pet
```

Format pet di semua tempat: PNG 128×128, grid 4×4, tiap pose 32×32, menghadap kanan. Urutan pose:
diam, kedip, jalan 1, jalan 2, senang, sayang, kaget, sedih, makan, pusing, rebahan, tidur, lompat,
melambai, joget 1, joget 2.

## Keamanan

- Aplikasi Mac hanya: menggambar sprite di jendela transparan, membaca **posisi** kursor, dan (bila akun
  terhubung) mengambil gambar pet + sapaan teman dari server, serta mengirim / menerima pesan dengan teman.
  Tidak ada izin sistem yang diminta (⌘ dibaca dari event klik pada pet itu sendiri, bukan dari keyboard global).
- Pesan hanya bisa dikirim / dibaca antara dua akun yang berteman; putus teman = tidak bisa mengirim lagi.
- Token perangkat disimpan di Keychain, hanya berlaku untuk `/api/app/*`, dan bisa dicabut dari web (halaman Mac).
- Foto untuk generate dihapus dari server begitu prosesnya selesai.
- Password di-hash argon2id. Sesi admin terpisah, `SameSite=Strict`, maksimal 12 jam, semua tindakannya dicatat.
- API key provider AI dienkripsi AES-256-GCM dengan `APP_SECRET` dan tidak pernah dikirim balik ke browser.

## Rilis & CI

| Workflow | Kapan | Apa |
|---|---|---|
| `mac.yml` | push yang menyentuh `Sources/`, `Resources/` | build universal di macOS, uji jalan; di `main` dengan versi baru → tag `v<versi>` + Release |
| `ci.yml` | push / PR yang menyentuh `server/`, `web/` | gofmt, vet, test + PostgreSQL, cek template sinkron, build web, build image |
| `deploy.yml` | push ke `main` | CI lalu deploy SSH ke VPS (hanya kalau variable `DEPLOY_ENABLED=true`) |

Merilis aplikasi Mac: naikkan `VERSION` dan `Resources/Info.plist` (aturan di [AGENTS.md](AGENTS.md)), merge ke `main`.

## Uninstall

Ikon pet → **Pengaturan… → Tentang → Uninstall…**. Manual:

```bash
pkill -x Temu
```

```bash
defaults delete id.local.temu
```

```bash
security delete-generic-password -s id.local.temu -a device-token
```

Lalu seret `Temu.app` ke Tong Sampah.
