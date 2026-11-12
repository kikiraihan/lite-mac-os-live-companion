.PHONY: help check-env up down restart logs ps psql backup restore deploy rollback health admin version \
	dev-server dev-web build-web fmt fmt-check vet test test-integration sprites mac ci

COMPOSE ?= docker compose
BACKUP_DIR ?= backups
TIMESTAMP := $(shell date +%Y%m%d-%H%M%S)
APP_PORT_ENV = $(shell [ -f .env ] && grep -E '^[[:space:]]*APP_PORT[[:space:]]*=' .env | tail -1 | sed -E 's/^[^=]*=//; s/\#.*$$//' | tr -d '"'\''[:space:]')
APP_PORT ?= $(if $(APP_PORT_ENV),$(APP_PORT_ENV),8093)
TEST_DB ?= postgres://postgres:postgres@localhost:5432/postgres?sslmode=disable
DEV_DB ?= postgres://temu:temu@localhost:5432/temu?sslmode=disable

help: ## Daftar perintah
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

check-env:
	@if [ ! -f .env ]; then cp .env.example .env; echo ".env dibuat dari .env.example — isi APP_SECRET dan DB_PASSWORD, lalu jalankan ulang."; exit 1; fi

# ---- Docker (server) -------------------------------------------------------
up: check-env ## Build & jalankan stack
	$(COMPOSE) up -d --build --remove-orphans

down: ## Hentikan stack (volume aman)
	$(COMPOSE) down

restart: down up ## Restart stack

logs: ## Ikuti log
	$(COMPOSE) logs -f --tail=100

ps: ## Status container
	$(COMPOSE) ps

psql: ## psql ke database temu
	$(COMPOSE) exec db psql -U temu -d temu

backup: ## Backup DB ke backups/
	@mkdir -p $(BACKUP_DIR)
	$(COMPOSE) exec -T db pg_dump -U temu -d temu --clean --if-exists | gzip > $(BACKUP_DIR)/temu-$(TIMESTAMP).sql.gz
	@echo "Backup: $(BACKUP_DIR)/temu-$(TIMESTAMP).sql.gz"

restore: ## Restore DB: make restore FILE=backups/temu-xxx.sql.gz
	@if [ -z "$(FILE)" ]; then echo "make restore FILE=..."; exit 1; fi
	$(COMPOSE) stop app
	gzip -cd $(FILE) | $(COMPOSE) exec -T db psql -U temu -d temu -v ON_ERROR_STOP=1 -q
	$(COMPOSE) start app

admin: ## Buat / reset superadmin (login di /admin/login): make admin EMAIL=a@b.c PASSWORD=...
	$(COMPOSE) exec app temu admin:create "$(EMAIL)" "$(PASSWORD)"

deploy: check-env ## [VPS] backup + pull + build + up + health check + auto-rollback
	./scripts/deploy.sh

rollback: ## [VPS] kembali ke commit sebelum deploy terakhir (atau SHA=...)
	./scripts/rollback.sh $(SHA)

health: ## Cek health app
	@curl -fsS --max-time 5 http://127.0.0.1:$(APP_PORT)/api/health && echo

version: ## Commit yang ter-deploy
	@git log -1 --format='%h %s (%ci)'

# ---- Lokal (tanpa Docker) --------------------------------------------------
dev-server: ## Server lokal dengan provider AI palsu (butuh PostgreSQL di DEV_DB)
	cd server && AI_MOCK=1 DATABASE_URL="$(DEV_DB)" WEB_DIR=../web/dist go run ./cmd/server

dev-web: ## Vite dev server (proxy /api ke :8080)
	cd web && npm run dev

build-web: ## Build SPA
	cd web && npm ci && npm run build

fmt: ## gofmt
	cd server && gofmt -w .

fmt-check:
	@cd server && out=$$(gofmt -l .); if [ -n "$$out" ]; then echo "Belum di-gofmt:"; echo "$$out"; exit 1; fi; echo "gofmt OK"

vet:
	cd server && go vet ./...

test: ## Unit test (test integrasi dilewati tanpa PostgreSQL)
	cd server && go test ./...

test-integration: ## Semua test termasuk PostgreSQL: make test-integration TEST_DB=postgres://...
	cd server && TEMU_TEST_DATABASE_URL="$(TEST_DB)" go test -count=1 ./...

sprites: ## Render ulang pet bawaan dari Sprites.swift → template server + docs/sprites.png
	python3 scripts/preview-sprites.py

mac: ## [Mac] Build Temu.app
	./scripts/build.sh

ci: fmt-check vet test-integration build-web ## Semua cek CI server & web secara lokal
