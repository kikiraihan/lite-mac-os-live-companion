// Package sprite: format gambar pet dan pengolah gambar mentah (hasil AI / unggahan) menjadi
// sprite sheet pixel art yang seragam.
//
// Format sheet: PNG 128×128, grid 4×4, tiap pose 32×32, pet menghadap KANAN, kaki menempel
// di tepi bawah sel, latar transparan. Urutan pose (kiri→kanan, atas→bawah) ada di Frames —
// urutan ini juga dipakai aplikasi Mac (Sprites.swift) dan web (web/src/lib/sheet.js).
package sprite

import (
	"bytes"
	"embed"
	"errors"
	"image"
	"image/color"
	"image/draw"
	_ "image/gif" // unggahan boleh GIF/JPEG/PNG
	_ "image/jpeg"
	"image/png"
	"sort"
	"strings"
)

const (
	Cell = 32
	Cols = 4
	Rows = 4
	Size = Cell * Cols // 128
	// Fit: sisi terpanjang pet hasil olahan, dalam piksel
	Fit = 24
)

// Frames: nama pose sesuai urutan sel.
var Frames = []string{
	"idle", "blink", "walk1", "walk2",
	"happy", "love", "surprise", "sad",
	"eat", "dizzy", "sit", "sleep",
	"jump", "wave", "dance1", "dance2",
}

// KeyColor: latar yang diminta ke AI (magenta) supaya mudah dibuang.
var KeyColor = color.NRGBA{255, 0, 255, 255}

var (
	ErrTooSmall = errors.New("gambar terlalu kecil (minimal 128×128)")
	ErrTooLarge = errors.New("gambar terlalu besar (maksimal 4096×4096)")
	ErrEmpty    = errors.New("tidak menemukan gambar pet — pastikan latarnya polos dan pose pertama (kiri atas) terisi")
)

//go:embed templates/*.png
var templateFS embed.FS

// Template: pet bawaan yang bisa dipakai sebagai titik awal.
type Template struct {
	ID, Title, DefaultName string
}

// Templates harus sama dengan Art.species di Sources/Temu/Sprites.swift
// (PNG-nya dibuat scripts/preview-sprites.py).
var Templates = []Template{
	{"oren", "Kucing Oren", "Mochi"},
	{"hitam", "Kucing Hitam", "Kopi"},
	{"kelinci", "Kelinci", "Bubu"},
	{"beruang", "Beruang", "Gembul"},
	{"rubah", "Rubah", "Sore"},
}

func TemplatePNG(id string) ([]byte, bool) {
	for _, t := range Templates {
		if t.ID == id {
			b, err := templateFS.ReadFile("templates/" + id + ".png")
			return b, err == nil
		}
	}
	return nil, false
}

func FindTemplate(id string) (Template, bool) {
	for _, t := range Templates {
		if t.ID == id {
			return t, true
		}
	}
	return Template{}, false
}

// Decode membaca PNG/JPEG/GIF dengan batas ukuran piksel.
func Decode(data []byte) (image.Image, error) {
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, errors.New("file bukan gambar PNG atau JPEG yang bisa dibaca")
	}
	if cfg.Width > 4096 || cfg.Height > 4096 {
		return nil, ErrTooLarge
	}
	if cfg.Width < Size || cfg.Height < Size {
		return nil, ErrTooSmall
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, errors.New("file bukan gambar PNG atau JPEG yang bisa dibaca")
	}
	return img, nil
}

func Encode(img image.Image) ([]byte, error) {
	var buf bytes.Buffer
	enc := png.Encoder{CompressionLevel: png.BestCompression}
	if err := enc.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// NormalizeBytes: gambar apa pun → sheet PNG 128×128.
func NormalizeBytes(data []byte) ([]byte, error) {
	img, err := Decode(data)
	if err != nil {
		return nil, err
	}
	out, err := Normalize(img)
	if err != nil {
		return nil, err
	}
	return Encode(out)
}

func toNRGBA(src image.Image) *image.NRGBA {
	b := src.Bounds()
	out := image.NewNRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(out, out.Bounds(), src, b.Min, draw.Src)
	return out
}

// Normalize mengubah gambar grid 4×4 (latar polos atau transparan) menjadi sheet 128×128:
// buang latar → cari kotak pembatas tiap pose → kecilkan dengan skala yang sama → rapatkan
// ke bawah-tengah sel → kurangi jumlah warna supaya tampil sebagai pixel art.
func Normalize(src image.Image) (*image.NRGBA, error) {
	px := toNRGBA(src)
	w, h := px.Bounds().Dx(), px.Bounds().Dy()
	if w < Size || h < Size {
		return nil, ErrTooSmall
	}
	if w == Size && h == Size { // sudah format kita (editor piksel / unduhan ulang)
		return cleanNative(px)
	}
	mask := foreground(px)
	cw, ch := w/Cols, h/Rows

	type box struct {
		x0, y0, x1, y1 int
		ok             bool
	}
	boxes := make([]box, Cols*Rows)
	maxW, maxH := 0, 0
	for i := range boxes {
		cx, cy := (i%Cols)*cw, (i/Cols)*ch
		b := box{x0: cw, y0: ch, x1: -1, y1: -1}
		n := 0
		for y := 0; y < ch; y++ {
			for x := 0; x < cw; x++ {
				if mask[(cy+y)*w+cx+x] {
					n++
					b.x0, b.y0 = min(b.x0, x), min(b.y0, y)
					b.x1, b.y1 = max(b.x1, x), max(b.y1, y)
				}
			}
		}
		if n*500 >= cw*ch { // ≥ 0,2% sel; di bawah itu dianggap noda
			b.ok = true
			b.x0, b.y0, b.x1, b.y1 = b.x0+cx, b.y0+cy, b.x1+cx+1, b.y1+cy+1
			maxW, maxH = max(maxW, b.x1-b.x0), max(maxH, b.y1-b.y0)
		}
		boxes[i] = b
	}
	if !boxes[0].ok {
		return nil, ErrEmpty
	}
	// skala bersama: pose terbesar muat di Fit×Fit, kira-kira seukuran pet bawaan (20×18)
	scale := min(Fit/float64(maxW), Fit/float64(maxH), 1)

	out := image.NewNRGBA(image.Rect(0, 0, Size, Size))
	for i, b := range boxes {
		if !b.ok {
			continue
		}
		tw := max(1, int(float64(b.x1-b.x0)*scale+0.5))
		th := max(1, int(float64(b.y1-b.y0)*scale+0.5))
		tw, th = min(tw, Cell), min(th, Cell)
		ox := (i%Cols)*Cell + (Cell-tw)/2
		oy := (i/Cols)*Cell + Cell - th
		for ty := 0; ty < th; ty++ {
			sy0 := b.y0 + ty*(b.y1-b.y0)/th
			sy1 := max(sy0+1, b.y0+(ty+1)*(b.y1-b.y0)/th)
			for tx := 0; tx < tw; tx++ {
				sx0 := b.x0 + tx*(b.x1-b.x0)/tw
				sx1 := max(sx0+1, b.x0+(tx+1)*(b.x1-b.x0)/tw)
				if c, ok := dominant(px, mask, w, sx0, sy0, sx1, sy1); ok {
					out.SetNRGBA(ox+tx, oy+ty, c)
				}
			}
		}
	}
	for i, b := range boxes { // pose yang kosong meniru pose pertama
		if !b.ok {
			copyCell(out, 0, i)
		}
	}
	quantize(out, 24)
	return out, nil
}

// cleanNative: sheet 128×128 — alpha dijadikan hitam-putih, lalu dicek tidak kosong.
func cleanNative(px *image.NRGBA) (*image.NRGBA, error) {
	any := false
	for i := 0; i < len(px.Pix); i += 4 {
		if px.Pix[i+3] >= 128 {
			px.Pix[i+3] = 255
			any = true
		} else {
			px.Pix[i], px.Pix[i+1], px.Pix[i+2], px.Pix[i+3] = 0, 0, 0, 0
		}
	}
	if !any {
		return nil, ErrEmpty
	}
	return px, nil
}

func copyCell(img *image.NRGBA, from, to int) {
	fx, fy := (from%Cols)*Cell, (from/Cols)*Cell
	tx, ty := (to%Cols)*Cell, (to/Cols)*Cell
	for y := 0; y < Cell; y++ {
		for x := 0; x < Cell; x++ {
			img.SetNRGBA(tx+x, ty+y, img.NRGBAAt(fx+x, fy+y))
		}
	}
}

func dist2(a, b color.NRGBA) int {
	dr, dg, db := int(a.R)-int(b.R), int(a.G)-int(b.G), int(a.B)-int(b.B)
	return dr*dr + dg*dg + db*db
}

// foreground: true untuk piksel yang termasuk gambar pet.
// Gambar yang sudah transparan → dari alpha. Selain itu warna latar diambil dari tepi gambar,
// lalu dibuang dengan flood fill dari tepi + semua piksel yang warnanya nyaris sama.
func foreground(px *image.NRGBA) []bool {
	w, h := px.Bounds().Dx(), px.Bounds().Dy()
	mask := make([]bool, w*h)
	transparent := 0
	for i := 0; i < w*h; i++ {
		if px.Pix[i*4+3] < 128 {
			transparent++
		}
	}
	if transparent*50 > w*h { // > 2% transparan
		for i := 0; i < w*h; i++ {
			mask[i] = px.Pix[i*4+3] >= 128
		}
		return mask
	}

	at := func(x, y int) color.NRGBA {
		i := (y*w + x) * 4
		return color.NRGBA{px.Pix[i], px.Pix[i+1], px.Pix[i+2], 255}
	}
	// warna latar = warna terbanyak di tepi (dikelompokkan per 16 tingkat)
	type acc struct{ n, r, g, b int }
	bins := map[int]*acc{}
	add := func(x, y int) {
		c := at(x, y)
		k := int(c.R>>4)<<8 | int(c.G>>4)<<4 | int(c.B>>4)
		a := bins[k]
		if a == nil {
			a = &acc{}
			bins[k] = a
		}
		a.n++
		a.r += int(c.R)
		a.g += int(c.G)
		a.b += int(c.B)
	}
	for x := 0; x < w; x++ {
		add(x, 0)
		add(x, h-1)
	}
	for y := 0; y < h; y++ {
		add(0, y)
		add(w-1, y)
	}
	var best *acc
	for _, a := range bins {
		if best == nil || a.n > best.n {
			best = a
		}
	}
	key := color.NRGBA{uint8(best.r / best.n), uint8(best.g / best.n), uint8(best.b / best.n), 255}

	const floodTol, nearTol = 80 * 80, 40 * 40
	bg := make([]bool, w*h)
	stack := make([]int, 0, 2*(w+h))
	push := func(x, y int) {
		i := y*w + x
		if !bg[i] && dist2(at(x, y), key) <= floodTol {
			bg[i] = true
			stack = append(stack, i)
		}
	}
	for x := 0; x < w; x++ {
		push(x, 0)
		push(x, h-1)
	}
	for y := 0; y < h; y++ {
		push(0, y)
		push(w-1, y)
	}
	for len(stack) > 0 {
		i := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		x, y := i%w, i/w
		if x > 0 {
			push(x-1, y)
		}
		if x < w-1 {
			push(x+1, y)
		}
		if y > 0 {
			push(x, y-1)
		}
		if y < h-1 {
			push(x, y+1)
		}
	}
	for i := 0; i < w*h; i++ {
		mask[i] = !bg[i] && dist2(at(i%w, i/w), key) > nearTol
	}
	return mask
}

// dominant: warna terbanyak di sebuah blok sumber (bukan rata-rata, supaya tepi tetap tegas).
// ok=false kalau kurang dari separuh blok adalah gambar pet.
func dominant(px *image.NRGBA, mask []bool, w, x0, y0, x1, y1 int) (color.NRGBA, bool) {
	type acc struct{ n, r, g, b int }
	var bins [4096]*acc
	used := make([]int, 0, 16)
	fg, total := 0, 0
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			total++
			if !mask[y*w+x] {
				continue
			}
			fg++
			i := (y*w + x) * 4
			k := int(px.Pix[i]>>4)<<8 | int(px.Pix[i+1]>>4)<<4 | int(px.Pix[i+2]>>4)
			if bins[k] == nil {
				bins[k] = &acc{}
				used = append(used, k)
			}
			a := bins[k]
			a.n++
			a.r += int(px.Pix[i])
			a.g += int(px.Pix[i+1])
			a.b += int(px.Pix[i+2])
		}
	}
	if total == 0 || fg*2 < total {
		return color.NRGBA{}, false
	}
	var best *acc
	for _, k := range used {
		if best == nil || bins[k].n > best.n {
			best = bins[k]
		}
	}
	return color.NRGBA{uint8(best.r / best.n), uint8(best.g / best.n), uint8(best.b / best.n), 255}, true
}

// quantize: median cut — seluruh sheet memakai paling banyak n warna.
func quantize(img *image.NRGBA, n int) {
	type rgb [3]uint8
	count := map[rgb]int{}
	for i := 0; i < len(img.Pix); i += 4 {
		if img.Pix[i+3] != 0 {
			count[rgb{img.Pix[i], img.Pix[i+1], img.Pix[i+2]}]++
		}
	}
	if len(count) <= n {
		return
	}
	colors := make([]rgb, 0, len(count))
	for c := range count {
		colors = append(colors, c)
	}
	sort.Slice(colors, func(i, j int) bool { // urutan tetap → hasil deterministik
		a, b := colors[i], colors[j]
		return a[0] != b[0] && a[0] < b[0] || a[0] == b[0] && (a[1] != b[1] && a[1] < b[1] || a[1] == b[1] && a[2] < b[2])
	})
	boxes := [][]rgb{colors}
	for len(boxes) < n {
		// belah kotak dengan rentang warna terlebar
		bi, bch, brange := -1, 0, 0
		for i, b := range boxes {
			if len(b) < 2 {
				continue
			}
			for ch := 0; ch < 3; ch++ {
				lo, hi := 255, 0
				for _, c := range b {
					lo, hi = min(lo, int(c[ch])), max(hi, int(c[ch]))
				}
				if hi-lo > brange {
					bi, bch, brange = i, ch, hi-lo
				}
			}
		}
		if bi < 0 {
			break
		}
		b := boxes[bi]
		sort.SliceStable(b, func(i, j int) bool { return b[i][bch] < b[j][bch] })
		// titik belah = median berbobot jumlah piksel
		total := 0
		for _, c := range b {
			total += count[c]
		}
		cut, run := 1, 0
		for i, c := range b[:len(b)-1] {
			run += count[c]
			if run*2 >= total {
				cut = i + 1
				break
			}
		}
		boxes[bi] = b[:cut]
		boxes = append(boxes, b[cut:])
	}
	remap := map[rgb]rgb{}
	for _, b := range boxes {
		var r, g, bl, t int
		for _, c := range b {
			k := count[c]
			r, g, bl, t = r+int(c[0])*k, g+int(c[1])*k, bl+int(c[2])*k, t+k
		}
		avg := rgb{uint8(r / t), uint8(g / t), uint8(bl / t)}
		for _, c := range b {
			remap[c] = avg
		}
	}
	for i := 0; i < len(img.Pix); i += 4 {
		if img.Pix[i+3] != 0 {
			c := remap[rgb{img.Pix[i], img.Pix[i+1], img.Pix[i+2]}]
			img.Pix[i], img.Pix[i+1], img.Pix[i+2] = c[0], c[1], c[2]
		}
	}
}

// Guide: gambar contoh tata letak 1024×1024 berlatar magenta, dibuat dari sebuah sheet.
// Dilampirkan ke AI (dan diunduh pengguna untuk cara manual) supaya susunan 16 posenya sama.
func Guide(sheetPNG []byte) ([]byte, error) {
	src, err := png.Decode(bytes.NewReader(sheetPNG))
	if err != nil {
		return nil, err
	}
	sheet := toNRGBA(src)
	const out, cell, zoom = 1024, 256, 6 // 32×6 = 192 → di tengah sel 256
	img := image.NewNRGBA(image.Rect(0, 0, out, out))
	draw.Draw(img, img.Bounds(), &image.Uniform{KeyColor}, image.Point{}, draw.Src)
	pad := (cell - Cell*zoom) / 2
	for y := 0; y < Size; y++ {
		for x := 0; x < Size; x++ {
			c := sheet.NRGBAAt(x, y)
			if c.A < 128 {
				continue
			}
			c.A = 255
			bx, by := (x/Cell)*cell+pad+(x%Cell)*zoom, (y/Cell)*cell+pad+(y%Cell)*zoom
			for dy := 0; dy < zoom; dy++ {
				for dx := 0; dx < zoom; dx++ {
					img.SetNRGBA(bx+dx, by+dy, c)
				}
			}
		}
	}
	return Encode(img)
}

// DefaultPrompt: instruksi untuk model gambar (bisa diubah di admin). {{note}} = catatan pengguna.
const DefaultPrompt = `Create a pixel art sprite sheet of a small, cute chibi desktop pet based on the person or subject in the attached PHOTO.

Use the attached LAYOUT image as the exact template: a 4x4 grid of 16 equal square cells on a flat pure magenta (#FF00FF) background. Redraw every cell with the new character in the same pose, same position and same size as the layout. Keep the character facing right, standing on the bottom edge of its cell, never crossing into a neighbouring cell.

Cells, left to right, top to bottom:
1 idle standing, 2 idle with eyes closed (blink), 3 walking step A, 4 walking step B,
5 happy (smiling, eyes closed in joy), 6 in love (heart eyes), 7 surprised, 8 sad,
9 eating (mouth open), 10 dizzy (X eyes), 11 sitting or lying down relaxed, 12 sleeping,
13 jumping, 14 waving hello, 15 dance pose A, 16 dance pose B.

Character rules: keep the recognisable features of the photo (hair style and colour, glasses, skin tone, signature clothing colour), big head and tiny body, the same character and colours in all 16 cells.
Style rules: chunky retro pixel art like a 32x32 game sprite, dark 1-pixel outline, flat colours with at most 16 colours, no gradients, no anti-aliasing, no shadows, no text, no numbers, no grid lines, no borders. The background must be flat pure magenta #FF00FF everywhere.
{{note}}`

// BuildPrompt mengisi catatan pengguna ke templat prompt.
func BuildPrompt(tpl, note string) string {
	if strings.TrimSpace(tpl) == "" {
		tpl = DefaultPrompt
	}
	note = strings.TrimSpace(note)
	if note != "" {
		note = "Extra wishes from the user: " + note
	}
	if strings.Contains(tpl, "{{note}}") {
		return strings.TrimSpace(strings.ReplaceAll(tpl, "{{note}}", note))
	}
	return strings.TrimSpace(tpl + "\n" + note)
}
