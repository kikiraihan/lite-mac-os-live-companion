// Package ai: klien provider gambar (kenari.id, OpenRouter, atau endpoint lain yang kompatibel
// OpenAI). Koneksi (base URL, API key, model) dikelola admin dan disimpan di database —
// lihat tabel ai_connections.
//
// Dua gaya permintaan, mengikuti konektor di Racik/Pancar:
//   - "chat"   : POST {base}/chat/completions dengan modalities ["image","text"]; gambar acuan
//     dikirim sebagai image_url (data URI). Dipakai OpenRouter dan model gambar via chat.
//   - "images" : POST {base}/images/edits (multipart, gaya OpenAI Images). Dipakai kenari.id.
package ai

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"net/textproto"
	"sort"
	"strings"
	"syscall"
	"time"
)

type Connection struct {
	ID, Name, Kind, BaseURL, APIKey, Model, Style string
}

type Image struct {
	Data []byte
	Mime string
}

// Ref: gambar acuan (foto pengguna, contoh tata letak).
type Ref struct {
	Name string
	Mime string
	Data []byte
}

// Preset: isian awal form koneksi di admin.
type Preset struct {
	Kind    string `json:"kind"`
	Title   string `json:"title"`
	BaseURL string `json:"base_url"`
	Style   string `json:"style"`
	Model   string `json:"image_model"`
	Hint    string `json:"hint"`
}

var Presets = []Preset{
	{"kenari", "kenari.id", "https://kenari.id/v1", "images", "gpt-image-2",
		"Ditagih Rupiah. Model gambar yang menerima foto acuan: gpt-image-2, nano-banana-2."},
	{"openrouter", "OpenRouter", "https://openrouter.ai/api/v1", "chat", "google/gemini-2.5-flash-image",
		"Kredit USD. Pilih model yang keluarannya gambar dan menerima gambar masukan."},
	{"custom", "Lainnya (kompatibel OpenAI)", "", "chat", "",
		"Endpoint apa pun yang punya /chat/completions atau /images/edits."},
}

// APIError: jawaban non-2xx dari provider.
type APIError struct {
	Status int
	Body   string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("provider menjawab %d: %s", e.Status, e.Body)
}

func truncate(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}

// NewClient: klien HTTP untuk provider. Alamat privat ditolak supaya URL gambar di jawaban
// provider (atau base URL yang keliru) tidak bisa menjangkau jaringan dalam server.
func NewClient(timeout time.Duration, allowPrivate bool) *http.Client {
	d := &net.Dialer{Timeout: 15 * time.Second}
	if !allowPrivate {
		d.Control = func(network, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			ip := net.ParseIP(host)
			if ip == nil || ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() {
				return fmt.Errorf("alamat %s tidak diizinkan", host)
			}
			return nil
		}
	}
	return &http.Client{Timeout: timeout, Transport: &http.Transport{DialContext: d.DialContext, MaxIdleConns: 10, IdleConnTimeout: 60 * time.Second}}
}

func (c Connection) request(ctx context.Context, method, path, contentType string, body io.Reader) (*http.Request, error) {
	base := strings.TrimRight(c.BaseURL, "/")
	if !strings.HasPrefix(base, "https://") && !strings.HasPrefix(base, "http://") {
		return nil, errors.New("base URL harus diawali https://")
	}
	req, err := http.NewRequestWithContext(ctx, method, base+path, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.APIKey)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if c.Kind == "openrouter" {
		req.Header.Set("X-Title", "Temu")
	}
	return req, nil
}

func do(client *http.Client, req *http.Request, out any) error {
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 40<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode >= 300 {
		return &APIError{Status: resp.StatusCode, Body: truncate(string(raw), 400)}
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("jawaban provider bukan JSON: %s", truncate(string(raw), 200))
	}
	return nil
}

// Generate membuat satu gambar dari prompt + gambar acuan.
func Generate(ctx context.Context, client *http.Client, c Connection, prompt string, refs []Ref) (*Image, error) {
	if c.Style == "images" {
		return generateImages(ctx, client, c, prompt, refs)
	}
	return generateChat(ctx, client, c, prompt, refs)
}

func generateChat(ctx context.Context, client *http.Client, c Connection, prompt string, refs []Ref) (*Image, error) {
	content := []map[string]any{{"type": "text", "text": prompt}}
	for _, r := range refs {
		content = append(content, map[string]any{"type": "image_url", "image_url": map[string]any{
			"url": "data:" + r.Mime + ";base64," + base64.StdEncoding.EncodeToString(r.Data)}})
	}
	body, _ := json.Marshal(map[string]any{
		"model":      c.Model,
		"messages":   []map[string]any{{"role": "user", "content": content}},
		"modalities": []string{"image", "text"},
	})
	req, err := c.request(ctx, http.MethodPost, "/chat/completions", "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content json.RawMessage `json:"content"`
				Images  []struct {
					ImageURL struct {
						URL string `json:"url"`
					} `json:"image_url"`
				} `json:"images"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := do(client, req, &out); err != nil {
		return nil, err
	}
	if len(out.Choices) == 0 {
		return nil, errors.New("provider tidak mengembalikan jawaban")
	}
	m := out.Choices[0].Message
	if len(m.Images) > 0 {
		return fetch(ctx, client, m.Images[0].ImageURL.URL)
	}
	// beberapa gateway menaruh gambar di content sebagai bagian image_url
	var parts []struct {
		Type     string `json:"type"`
		ImageURL struct {
			URL string `json:"url"`
		} `json:"image_url"`
	}
	if json.Unmarshal(m.Content, &parts) == nil {
		for _, p := range parts {
			if p.ImageURL.URL != "" {
				return fetch(ctx, client, p.ImageURL.URL)
			}
		}
	}
	var text string
	json.Unmarshal(m.Content, &text)
	return nil, fmt.Errorf("model tidak mengembalikan gambar (pastikan modelnya bisa menghasilkan gambar): %s", truncate(text, 200))
}

func generateImages(ctx context.Context, client *http.Client, c Connection, prompt string, refs []Ref) (*Image, error) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	mw.WriteField("model", c.Model)
	mw.WriteField("prompt", prompt)
	mw.WriteField("n", "1")
	mw.WriteField("size", "1024x1024")
	field := "image"
	if len(refs) > 1 {
		field = "image[]"
	}
	for _, r := range refs {
		h := textproto.MIMEHeader{}
		h.Set("Content-Disposition", fmt.Sprintf(`form-data; name="%s"; filename="%s"`, field, r.Name))
		h.Set("Content-Type", r.Mime)
		pw, err := mw.CreatePart(h)
		if err != nil {
			return nil, err
		}
		pw.Write(r.Data)
	}
	mw.Close()
	req, err := c.request(ctx, http.MethodPost, "/images/edits", mw.FormDataContentType(), &buf)
	if err != nil {
		return nil, err
	}
	var out struct {
		Data []struct {
			B64 string `json:"b64_json"`
			URL string `json:"url"`
		} `json:"data"`
	}
	if err := do(client, req, &out); err != nil {
		return nil, err
	}
	if len(out.Data) == 0 {
		return nil, errors.New("provider tidak mengembalikan gambar")
	}
	if out.Data[0].B64 != "" {
		return fetch(ctx, client, "data:image/png;base64,"+out.Data[0].B64)
	}
	return fetch(ctx, client, out.Data[0].URL)
}

// fetch: data URI atau URL http(s) → gambar.
func fetch(ctx context.Context, client *http.Client, u string) (*Image, error) {
	var data []byte
	switch {
	case strings.HasPrefix(u, "data:"):
		i := strings.Index(u, ",")
		if i < 0 {
			return nil, errors.New("data URI gambar tidak valid")
		}
		b, err := base64.StdEncoding.DecodeString(u[i+1:])
		if err != nil {
			return nil, errors.New("data gambar dari provider rusak")
		}
		data = b
	case strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://"):
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return nil, err
		}
		resp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 300 {
			return nil, fmt.Errorf("gagal mengunduh gambar hasil (%d)", resp.StatusCode)
		}
		if data, err = io.ReadAll(io.LimitReader(resp.Body, 30<<20)); err != nil {
			return nil, err
		}
	default:
		return nil, errors.New("provider tidak mengembalikan gambar")
	}
	mime := http.DetectContentType(data)
	if !strings.HasPrefix(mime, "image/") {
		return nil, errors.New("jawaban provider bukan gambar")
	}
	return &Image{Data: data, Mime: mime}, nil
}

// Model: entri daftar model provider.
type Model struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Image bool   `json:"image"` // diketahui bisa menghasilkan gambar
}

// ListModels: GET {base}/models. Juga dipakai sebagai tes koneksi (key salah → 401).
func ListModels(ctx context.Context, client *http.Client, c Connection) ([]Model, error) {
	req, err := c.request(ctx, http.MethodGet, "/models", "", nil)
	if err != nil {
		return nil, err
	}
	var out struct {
		Data []struct {
			ID           string `json:"id"`
			Name         string `json:"name"`
			Architecture struct {
				Output []string `json:"output_modalities"`
			} `json:"architecture"`
			Endpoints []string `json:"endpoints"`
			Type      string   `json:"type"`
		} `json:"data"`
	}
	if err := do(client, req, &out); err != nil {
		return nil, err
	}
	models := make([]Model, 0, len(out.Data))
	for _, m := range out.Data {
		img := m.Type == "image" || strings.Contains(strings.ToLower(m.ID), "image") || strings.Contains(strings.ToLower(m.ID), "banana")
		for _, o := range m.Architecture.Output {
			img = img || o == "image"
		}
		for _, e := range m.Endpoints {
			img = img || strings.Contains(e, "images")
		}
		name := m.Name
		if name == "" {
			name = m.ID
		}
		models = append(models, Model{ID: m.ID, Name: name, Image: img})
	}
	sort.SliceStable(models, func(i, j int) bool {
		if models[i].Image != models[j].Image {
			return models[i].Image
		}
		return models[i].ID < models[j].ID
	})
	return models, nil
}
