# Video teaser

`web/public/videos/temu-teaser.mp4` — teaser 32 detik, 1920×1080, 30 fps, dengan lagu (lihat `src/music.py` di bawah). Tampil di landing page
(`web/src/views/Landing.vue`, poster `web/public/videos/temu-teaser.jpg`).

| Detik | Adegan |
|---|---|
| 0–4 | "Temu — A little way to be together." Mochi berjalan masuk di lantai lalu melompat |
| 4–10,6 | Di layar Mac tiruan: jalan-jalan, rebahan, ketiduran, dielus (kursor + hati), joget |
| 10,6–16,6 | Editor piksel 32×32 melukis Sore si rubah, lalu lembar 16 pose muncul; tiga cara membuat pet |
| 16,6–22,6 | Undangan "Raka ingin ikut tampil di Mac-mu" → Izinkan → Kopi datang membawa sapaan |
| 22,6–26,6 | "Hanya kehadiran, bukan pengawasan": menu aplikasi + janji privasi, pet tidur di lantai |
| 26,6–32 | Penutup: lima pet bawaan berkumpul dan joget + temu.katili.dev |

## Render ulang

Sumber animasi ada di `src/teaser.html`. Gambar pet diambil langsung dari `server/internal/sprite/templates/*.png`, jadi
kalau pet bawaan di `Sprites.swift` berubah (`make sprites`), render ulang videonya. Font (Pixelify Sans, Rubik) diambil
dari Google Fonts, jadi butuh koneksi internet. Buka langsung di browser untuk pratinjau. Untuk membuat MP4
(butuh Node + Playwright/Chromium + ffmpeg, dan python3 + numpy untuk lagunya):

```bash
node video/src/render.js
```

Poster (frame penutup):

```bash
ffmpeg -y -ss 30.5 -i web/public/videos/temu-teaser.mp4 -frames:v 1 -vf scale=1280:-1 -q:v 4 web/public/videos/temu-teaser.jpg
```

## Versi portrait + lagu

`web/public/videos/temu-teaser-portrait.mp4` — teaser yang sama dalam 1080×1920 (9:16, untuk Reels / TikTok / Shorts /
Status WhatsApp), 32 detik, 30 fps, **dengan lagu**. Sumbernya `src/teaser-portrait.html` (linimasa sama dengan
`teaser.html`, tata letak disusun ke bawah; kalau adegan diubah, ubah keduanya).

Lagunya chiptune orisinal 120 BPM di C mayor yang dibuat dari kode (`src/music.py`, butuh `numpy`), jadi bebas
lisensi. Strukturnya mengikuti video: pembuka arpeggio (0–4 dtk), lagu penuh (4–22), tenang di adegan privasi
(22–26), penutup yang berakhir di akor C (26–32). Ada efek suara kecil yang pas dengan kejadian di layar: lompat,
klik kursor, hati, 16 pose muncul, gelembung sapaan.

```bash
node video/src/render.js portrait
```

Poster:

```bash
ffmpeg -y -ss 30.5 -i web/public/videos/temu-teaser-portrait.mp4 -frames:v 1 -vf scale=720:-1 -q:v 4 web/public/videos/temu-teaser-portrait.jpg
```
