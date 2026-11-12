// Temu — server web (API + SPA) dan worker generate dalam satu proses.
//
//	server                                   jalankan server
//	server admin:create EMAIL PASSWORD [NAMA] buat / reset superadmin (login di /admin/login)
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/app"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/config"
	"github.com/kikiraihan/lite-mac-os-live-companion/server/internal/db"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	conn, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()
	if err := db.Migrate(ctx, conn); err != nil {
		log.Fatal(err)
	}
	srv := app.New(conn, cfg)

	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "admin:create":
			if len(os.Args) < 4 {
				log.Fatal("pakai: server admin:create EMAIL PASSWORD [NAMA]")
			}
			name := ""
			if len(os.Args) > 4 {
				name = os.Args[4]
			}
			req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "/", nil)
			if err := srv.CreateAdmin(req, os.Args[2], os.Args[3], name); err != nil {
				log.Fatal(err)
			}
			fmt.Printf("Superadmin %s siap. Masuk di %s/admin/login\n", os.Args[2], cfg.PublicURL)
			return
		case "serve":
		default:
			log.Fatalf("perintah tidak dikenal: %s", os.Args[1])
		}
	}

	go srv.RunWorker(ctx)
	hs := &http.Server{Addr: cfg.Addr, Handler: srv.Routes(), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 120 * time.Second}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		hs.Shutdown(sctx)
	}()
	log.Printf("Temu mendengarkan di %s (%s)", cfg.Addr, cfg.PublicURL)
	if err := hs.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
