# AGENTS.md

Panduan untuk agen AI (Claude Code, dsb.) yang bekerja di repo ini.

## Proyek

**Temu** — *A little way to be together.* Versi pixel kecil dirimu / pet-mu yang hidup di layar Mac orang
terdekat (pasangan, sahabat), dengan akun, pertemanan, pet buatan sendiri, dan sapaan. Kesan yang dijaga:
hadir dan hangat, bukan mengawasi.

| Bagian | Folder | Isi |
|---|---|---|
| Aplikasi Mac | `Sources/Temu/`, `Resources/` | Swift + AppKit tanpa dependensi; ikon menu bar + pet di desktop |
| Server | `server/` | Go + PostgreSQL: API pengguna, API admin, API aplikasi Mac, worker generate |
| Web | `web/` | Vue 3 + Vite: sisi pengguna dan ruang admin (satu SPA, dua sesi terpisah) |

Rancangan visual web: `docs/DESIGN.md`. Deploy: `DEPLOY.md`.

## Cek sebelum commit

```bash
cd server && gofmt -l . && go vet ./... && TEMU_TEST_DATABASE_URL=postgres://… go test -count=1 ./...
cd web && npm run build
python3 scripts/preview-sprites.py     # hanya kalau gambar di Sprites.swift berubah
```

Tidak ada Mac di lingkungan agen cloud: kode Swift baru benar-benar dikompilasi oleh workflow
`.github/workflows/mac.yml` (macOS) di setiap push yang menyentuh `Sources/`. Setelah push, **lihat hasil
workflow itu** dan perbaiki kalau merah; jangan menganggap kode Swift benar sebelum CI hijau.

## Satu format pet di tiga tempat

Pet = sprite sheet PNG **128×128**, grid 4×4, tiap pose 32×32, menghadap kanan, kaki di tepi bawah sel.
Urutan 16 pose sama persis di:

- `server/internal/sprite/sprite.go` (`Frames`)
- `web/src/lib/sheet.js` (`FRAMES`)
- `Sources/Temu/Sprites.swift` (`enum Frame`) dan `scripts/preview-sprites.py` (`FRAMES`)

Mengubah urutan / jumlah pose = mengubah keempatnya sekaligus, dan pet lama di database jadi salah.

Gambar pet bawaan hanya ditulis di **`Sources/Temu/Sprites.swift`** (teks, 1 karakter = 1 piksel).
`server/internal/sprite/templates/*.png` dan `docs/sprites.png` adalah hasil render — jangan diedit tangan,
jalankan `make sprites`. CI menolak kalau keduanya tidak sinkron.

## Aturan yang tidak boleh dilonggarkan

- **Aplikasi Mac hanya mainan.** Tidak boleh membaca layar, ketikan, clipboard, berkas pengguna, atau daftar
  jendela/aplikasi lain; tidak boleh meminta izin Aksesibilitas / Perekaman Layar / Input Monitoring; tidak
  menjalankan perintah shell selain yang sudah ada (ganti .app saat update). Posisi kursor
  (`NSEvent.mouseLocation`) boleh. Fitur "lucu" yang butuh izin sistem = tolak, tawarkan alternatif.
- **Aplikasi Mac tidak pernah memegang password.** Hanya token perangkat dari alur kode
  (`/api/app/link/*`), disimpan di Keychain. Token itu hanya untuk `/api/app/*`.
- **Admin dan pengguna terpisah total**: tabel (`admins` vs `users`), sesi, cookie, CSRF, endpoint login.
  Jangan membuat jalan pintas (mis. kolom `is_admin` di `users`, atau sesi pengguna yang diterima `/api/admin`).
- **Setiap query data pengguna memakai id pemanggil** (`who(r).UserID`). Pet orang lain hanya terlihat oleh
  teman pemiliknya (`canSeePet`).
- **API key provider AI** hanya masuk lewat admin, disimpan terenkripsi (`security.Seal`, `APP_SECRET`),
  tidak pernah dikirim balik ke klien dan tidak di-log.
- **Foto pengguna dihapus** begitu generate selesai / gagal (`photo=NULL`). Jangan menambah penyimpanan foto.
- Semua endpoint yang mengubah data lewat sesi cookie wajib CSRF (`s.user` / `s.admin` sudah mengurusnya).
- CSP tanpa script inline; jangan pakai `v-html`.

## Prinsip desain

- **Aplikasi Mac**: gaya Apple (HIG) — kontrol bawaan sistem, satu baris = judul + keterangan + satu kontrol
  (`Form` di `Settings.swift`), label pendek berbahasa Indonesia, aksi yang menghapus selalu dikonfirmasi.
- **Web**: ikuti `docs/DESIGN.md`. Jangan menambah warna, font, radius, atau bayangan baru; pakai kelas di
  `web/src/style.css` (`.px`, `.btn`, `.input`, `.tag`, `.notice`, `.empty`). Satu-satunya hal yang ramai
  adalah pet-nya.
- Teks antarmuka: bahasa Indonesia santai, kalimat aktif, tombol menyebut apa yang terjadi
  ("Simpan jadi pet-ku", bukan "Submit"). Pesan galat menjelaskan apa yang salah dan cara memperbaikinya.

## Versioning (wajib di setiap PR yang mengubah aplikasi Mac)

Versi `a.b.c` disimpan di `VERSION` dan `Resources/Info.plist` (`CFBundleShortVersionString` harus sama;
`CFBundleVersion` selalu +1). CI menolak kalau keduanya berbeda.

| Bagian | Naik ketika |
|---|---|
| `a` | breaking change (mis. format sheet berubah) |
| `b` | fitur baru, atau perubahan gaya besar |
| `c` | perbaikan bug, atau perubahan gaya kecil |

Merge ke `main` dengan versi yang belum punya tag → rilis `v<versi>` (Temu.zip + installer). Tanpa naik
versi → tidak ada rilis. PR yang hanya mengubah server / web / dokumentasi / CI tidak menaikkan versi.
Sebutkan versi baru di deskripsi PR.
