# Video teaser

`web/public/videos/temu-teaser.mp4` — teaser 32 detik, 1920×1080, 30 fps, tanpa suara. Tampil di landing page
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
(butuh Node + Playwright/Chromium + ffmpeg):

```bash
node video/src/render.js
```

Poster (frame penutup):

```bash
ffmpeg -y -ss 30.5 -i web/public/videos/temu-teaser.mp4 -frames:v 1 -vf scale=1280:-1 -q:v 4 web/public/videos/temu-teaser.jpg
```
