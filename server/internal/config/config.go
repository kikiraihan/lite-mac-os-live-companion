// Package config membaca konfigurasi dari environment (lihat .env.example).
package config

import (
	"encoding/hex"
	"errors"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Env         string
	Addr        string
	PublicURL   string
	DatabaseURL string
	WebDir      string
	TrustProxy  bool
	// AppSecret: 32 byte; dipakai untuk mengenkripsi API key provider AI di database.
	AppSecret  []byte
	SessionTTL time.Duration
	AITimeout  time.Duration
	// AIMock: provider palsu untuk dev/CI (tanpa API key).
	AIMock bool
	// MacDownloadURL: tautan unduh aplikasi Mac yang ditampilkan di web.
	MacDownloadURL string
}

func env(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func envBool(k string) bool {
	v := strings.ToLower(env(k, ""))
	return v == "1" || v == "true" || v == "yes"
}

func Load() (Config, error) {
	c := Config{
		Env:            env("APP_ENV", "development"),
		Addr:           env("APP_ADDR", ":8080"),
		PublicURL:      strings.TrimRight(env("PUBLIC_URL", "http://localhost:8080"), "/"),
		DatabaseURL:    env("DATABASE_URL", "postgres://temu:temu@localhost:5432/temu?sslmode=disable"),
		WebDir:         env("WEB_DIR", "../web/dist"),
		TrustProxy:     envBool("TRUST_PROXY"),
		AIMock:         envBool("AI_MOCK"),
		MacDownloadURL: env("MAC_DOWNLOAD_URL", "https://github.com/kikiraihan/lite-mac-os-live-companion/releases/latest"),
	}
	days, _ := strconv.Atoi(env("SESSION_DAYS", "30"))
	if days < 1 {
		days = 30
	}
	c.SessionTTL = time.Duration(days) * 24 * time.Hour
	sec, _ := strconv.Atoi(env("AI_TIMEOUT_SEC", "180"))
	if sec < 10 {
		sec = 180
	}
	c.AITimeout = time.Duration(sec) * time.Second

	secret := env("APP_SECRET", "")
	if secret == "" {
		if c.Env == "production" {
			return c, errors.New("APP_SECRET wajib diisi di production (openssl rand -hex 32)")
		}
		secret = strings.Repeat("0", 64) // hanya untuk dev
	}
	b, err := hex.DecodeString(secret)
	if err != nil || len(b) != 32 {
		return c, errors.New("APP_SECRET harus 64 karakter hex (openssl rand -hex 32)")
	}
	c.AppSecret = b
	return c, nil
}
