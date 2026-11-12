// Package security: hashing password (argon2id), token acak, enkripsi rahasia (AES-GCM),
// dan rate limiter sederhana.
package security

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"
)

const (
	argonTime    = 3
	argonMemory  = 64 * 1024
	argonThreads = 2
	argonKeyLen  = 32
)

func HashPassword(pw string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(pw), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	return fmt.Sprintf("$argon2id$v=19$m=%d,t=%d,p=%d$%s$%s", argonMemory, argonTime, argonThreads,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(key)), nil
}

func CheckPassword(hash, pw string) bool {
	parts := strings.Split(hash, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return false
	}
	var m, t uint32
	var p uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &m, &t, &p); err != nil {
		return false
	}
	salt, err1 := base64.RawStdEncoding.DecodeString(parts[4])
	want, err2 := base64.RawStdEncoding.DecodeString(parts[5])
	if err1 != nil || err2 != nil {
		return false
	}
	got := argon2.IDKey([]byte(pw), salt, t, m, p, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1
}

// dummyHash dipakai saat email tidak terdaftar supaya waktu respons login tidak
// membocorkan apakah sebuah email punya akun.
var dummyHash, _ = HashPassword("temu-dummy-password")

func DummyCheck(pw string) { CheckPassword(dummyHash, pw) }

func ValidatePassword(pw string) error {
	n := utf8.RuneCountInString(pw)
	if n < 8 {
		return errors.New("minimal 8 karakter")
	}
	if n > 200 {
		return errors.New("terlalu panjang")
	}
	return nil
}

// RandomToken: n byte acak, base64url tanpa padding.
func RandomToken(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// RandomCode: kode pendek yang mudah dibaca (tanpa 0/O/1/I), mis. untuk undangan & tautan Mac.
func RandomCode(n int) string {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return string(b)
}

// SHA256 hex — token sesi & perangkat hanya disimpan dalam bentuk hash.
func SHA256(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// Seal mengenkripsi rahasia (API key provider) dengan AES-256-GCM; nonce di depan.
func Seal(key []byte, plain string) ([]byte, error) {
	blk, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(blk)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return gcm.Seal(nonce, nonce, []byte(plain), nil), nil
}

func Open(key, sealed []byte) (string, error) {
	blk, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(blk)
	if err != nil {
		return "", err
	}
	if len(sealed) < gcm.NonceSize() {
		return "", errors.New("data rahasia rusak")
	}
	out, err := gcm.Open(nil, sealed[:gcm.NonceSize()], sealed[gcm.NonceSize():], nil)
	return string(out), err
}

// MaskKey: "sk-or-v1-abcd…wxyz" untuk ditampilkan di admin (key asli tidak pernah dikirim balik).
func MaskKey(k string) string {
	if len(k) <= 8 {
		return strings.Repeat("•", len(k))
	}
	return k[:4] + "…" + k[len(k)-4:]
}

// Limiter: token bucket per kunci (IP / email), di memori.
type Limiter struct {
	mu     sync.Mutex
	rate   float64 // token per menit
	burst  float64
	bucket map[string]*bucket
}

type bucket struct {
	tokens float64
	last   time.Time
}

func NewLimiter(perMinute, burst float64) *Limiter {
	return &Limiter{rate: perMinute, burst: burst, bucket: map[string]*bucket{}}
}

func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	b := l.bucket[key]
	if b == nil {
		if len(l.bucket) > 50000 { // jangan tumbuh tanpa batas
			l.bucket = map[string]*bucket{}
		}
		b = &bucket{tokens: l.burst, last: now}
		l.bucket[key] = b
	}
	b.tokens += now.Sub(b.last).Minutes() * l.rate
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}
