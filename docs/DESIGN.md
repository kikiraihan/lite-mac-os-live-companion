# Desain web Temani

Subjek: pet pixel kecil yang berjalan di tepi bawah layar Mac. Pembaca: orang yang ingin sesuatu yang lucu
menemani kerja, lalu mengajak teman. Tugas halaman: membuat pet, berteman, menghubungkan Mac.

## Gagasan

Halaman web adalah sebuah **desktop**: bilah menu gelap di atas (seperti menu bar Mac), dan **lantai** di
bawah tempat pet-mu benar-benar berjalan, bisa dielus dan diangkat — persis seperti nanti di Mac. Itu
satu-satunya hal yang ramai. Semua yang lain tenang dan rata kiri.

Ruang admin sengaja terlihat lain: rel samping gelap, lencana kuning "Admin", tanpa lantai, tabel rapat.

## Warna

| Nama | Hex | Dipakai untuk |
|---|---|---|
| Langit | `#E7ECFF` | latar halaman |
| Langit tua | `#CBD4FB` | lantai, garis halus |
| Tinta | `#2A2140` | teks, garis pixel, bilah menu (sama dengan warna garis sprite) |
| Kertas | `#FFFFFF` | permukaan |
| Stroberi | `#FF5A7A` | satu aksi utama per layar, hati |
| Lemon | `#FFD23C` | aksi sekunder penting, sorotan, lencana admin |
| Jeruk | `#F7A552` | merek (warna Mochi si kucing oren) |
| Daun / Merah | `#2F9E77` / `#C92A45` | berhasil / bahaya |

Teks di atas Stroberi dan Lemon selalu Tinta (kontras cukup), bukan putih.

## Huruf

- **Pixelify Sans** 700: judul dan angka besar, hanya ≥ 20px. Judulnya sendiri yang jadi hiasan.
- **Rubik** 400/500/600: semua teks lain. Bentuknya agak kotak-membulat, cocok di samping huruf pixel.
- Skala: 14 · 16 · 20 · 28 · 40 · 56. Label memakai huruf biasa (bukan kapital semua).

## Bentuk

- Tanpa `border-radius`. Kotak "pixel" = `box-shadow` 3px di empat sisi, sehingga sudutnya hilang satu
  piksel (`.px`). Tombol punya "tebal" 4px di bawah dan turun saat ditekan.
- Tidak ada bayangan lembut, gradasi, atau ikon hias. Sprite pet adalah ilustrasinya.
- Gerak: hanya pet (dan transisi `steps()` pendek pada tombol / sakelar). `prefers-reduced-motion` →
  pet diam di tempat.

## Kelas (`web/src/style.css`)

`.px` kotak · `.card` isi kotak · `.btn` (`.primary` stroberi, `.sun` lemon, `.danger`, `.small`, `.block`) ·
`.input` · `.field` (label + isian + keterangan) · `.switch` · `.tag` (`.ok` `.warn` `.bad`) ·
`.notice` (`.ok` `.bad`) · `.empty` · `table.data` · `.row` `.stack` `.grow` `.spread` · `.muted` `.small`.

## Tulisan

Bahasa Indonesia santai, kalimat aktif. Tombol menyebut hasilnya ("Simpan jadi pet-ku", "Minta ke Mac-ku",
"Panggil pulang"). Layar kosong mengajak bertindak. Galat menyebut apa yang salah dan jalan keluarnya.
