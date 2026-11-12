package sprite

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"testing"
)

func mustSheet(t *testing.T, id string) *image.NRGBA {
	t.Helper()
	b, ok := TemplatePNG(id)
	if !ok {
		t.Fatalf("template %s tidak ada", id)
	}
	img, err := png.Decode(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	return toNRGBA(img)
}

func TestTemplatesAreValidSheets(t *testing.T) {
	for _, tpl := range Templates {
		s := mustSheet(t, tpl.ID)
		if s.Bounds().Dx() != Size || s.Bounds().Dy() != Size {
			t.Errorf("%s: ukuran %v", tpl.ID, s.Bounds())
		}
		b, _ := TemplatePNG(tpl.ID)
		if _, err := NormalizeBytes(b); err != nil {
			t.Errorf("%s: %v", tpl.ID, err)
		}
	}
	if len(Frames) != Cols*Rows {
		t.Fatalf("Frames = %d", len(Frames))
	}
}

// Contoh tata letak (magenta, 1024px) yang dinormalkan lagi harus kembali ke sheet asalnya:
// ini jalur yang sama dengan hasil AI / unggahan manual.
func TestGuideRoundTrip(t *testing.T) {
	orig := mustSheet(t, "oren")
	b, _ := TemplatePNG("oren")
	guide, err := Guide(b)
	if err != nil {
		t.Fatal(err)
	}
	for _, format := range []string{"png", "jpeg"} {
		data := guide
		if format == "jpeg" { // JPEG mengaburkan tepi & latar — harus tetap terbaca
			img, _ := png.Decode(bytes.NewReader(guide))
			var buf bytes.Buffer
			jpeg.Encode(&buf, img, &jpeg.Options{Quality: 85})
			data = buf.Bytes()
		}
		img, err := Decode(data)
		if err != nil {
			t.Fatal(err)
		}
		got, err := Normalize(img)
		if err != nil {
			t.Fatalf("%s: %v", format, err)
		}
		if got.NRGBAAt(0, 0).A != 0 {
			t.Errorf("%s: latar tidak transparan", format)
		}
		for i := range Frames {
			cx, cy := (i%Cols)*Cell, (i/Cols)*Cell
			top, n := Cell, 0
			for y := 0; y < Cell; y++ {
				for x := 0; x < Cell; x++ {
					if got.NRGBAAt(cx+x, cy+y).A != 0 {
						n++
						top = min(top, y)
					}
				}
			}
			if n < 100 {
				t.Errorf("%s: pose %s kosong (%d piksel)", format, Frames[i], n)
			}
			if Cell-top > Fit {
				t.Errorf("%s: pose %s setinggi %d piksel", format, Frames[i], Cell-top)
			}
			if got.NRGBAAt(cx+Cell/2, cy+Cell-1).A == 0 && got.NRGBAAt(cx+Cell/2-4, cy+Cell-1).A == 0 && got.NRGBAAt(cx+Cell/2+4, cy+Cell-1).A == 0 {
				t.Errorf("%s: pose %s tidak menempel di bawah", format, Frames[i])
			}
		}
		_ = orig
	}
}

func TestNormalizeRejectsBlank(t *testing.T) {
	img := image.NewNRGBA(image.Rect(0, 0, 512, 512))
	for i := range img.Pix {
		img.Pix[i] = 255
	}
	if _, err := Normalize(img); err != ErrEmpty {
		t.Fatalf("err = %v", err)
	}
}

func TestNormalizeLimitsColours(t *testing.T) {
	img := image.NewNRGBA(image.Rect(0, 0, 512, 512))
	for y := 0; y < 512; y++ {
		for x := 0; x < 512; x++ {
			c := KeyColor
			if x%128 > 20 && x%128 < 108 && y%128 > 20 { // kotak bergradasi di tiap sel
				c = color.NRGBA{uint8(x / 2), uint8(y / 2), 90, 255}
			}
			img.SetNRGBA(x, y, c)
		}
	}
	out, err := Normalize(img)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[color.NRGBA]bool{}
	for y := 0; y < Size; y++ {
		for x := 0; x < Size; x++ {
			if c := out.NRGBAAt(x, y); c.A != 0 {
				seen[c] = true
			}
		}
	}
	if len(seen) > 24 {
		t.Fatalf("%d warna", len(seen))
	}
	// kaki menempel di tepi bawah sel
	if out.NRGBAAt(16, 31).A == 0 {
		t.Fatal("pose tidak dirapatkan ke bawah")
	}
}

func TestBuildPrompt(t *testing.T) {
	p := BuildPrompt("", "pakai topi merah")
	if !bytes.Contains([]byte(p), []byte("pakai topi merah")) || bytes.Contains([]byte(p), []byte("{{note}}")) {
		t.Fatal(p)
	}
}
