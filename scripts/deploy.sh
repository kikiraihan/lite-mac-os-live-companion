#!/usr/bin/env bash
#
# Deploy script Temu yang dijalankan DI VPS (lewat `make deploy`, SSH manual, atau
# GitHub Actions). Diadaptasi dari Pancar/Racik. Alurnya:
#
#   1. pastikan .env ada, terisi aman, & repo bersih
#   2. backup PostgreSQL dulu (pg_dump, kalau db sedang jalan)
#   3. git fetch + reset --hard ke origin/<branch>
#   4. docker compose build + up -d
#   5. health check ke 127.0.0.1:$APP_PORT/api/health (app Go -> Postgres)
#   6. kalau health check gagal -> otomatis rollback ke commit sebelumnya
#
# Variabel yang bisa dioverride lewat environment:
#   DEPLOY_BRANCH   (default: main)
#   HEALTH_RETRIES  (default: 45)   percobaan health check
#   HEALTH_DELAY    (default: 2)    jeda detik antar percobaan
#   SKIP_BACKUP     (default: 0)    set 1 untuk lewati backup DB
#   NO_ROLLBACK     (default: 0)    set 1 untuk biarkan versi gagal tetap jalan
#   KEEP_BACKUPS    (default: 10)   jumlah backup pre-deploy yang disimpan
#
set -euo pipefail

# --- Jalankan dari salinan sementara -----------------------------------------
# `git reset --hard` di tengah eksekusi bisa mengubah file script yang sedang
# dibaca bash. Jadi begitu masuk, script menyalin dirinya ke /tmp lalu exec dari
# sana supaya isi script stabil selama deploy berlangsung.
if [ "${DEPLOY_SELF_COPY:-0}" != "1" ]; then
	_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
	_root="$(cd "$(dirname "$_self")/.." && pwd)"
	_copy="$(mktemp -t temu-deploy.XXXXXX)"
	cp "$_self" "$_copy"
	chmod +x "$_copy"
	DEPLOY_SELF_COPY=1 DEPLOY_APP_DIR="$_root" DEPLOY_SELF_TMP="$_copy" exec "$_copy" "$@"
fi
trap 'rm -f "${DEPLOY_SELF_TMP:-}"' EXIT

APP_DIR="${DEPLOY_APP_DIR:?DEPLOY_APP_DIR tidak terisi}"
cd "$APP_DIR"

BRANCH="${DEPLOY_BRANCH:-main}"
HEALTH_RETRIES="${HEALTH_RETRIES:-45}"
HEALTH_DELAY="${HEALTH_DELAY:-2}"
SKIP_BACKUP="${SKIP_BACKUP:-0}"
NO_ROLLBACK="${NO_ROLLBACK:-0}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"
PREV_FILE="$APP_DIR/.deploy-previous"

log()  { printf '\033[36m[deploy %s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[33m[deploy %s] WARN:\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\033[31m[deploy %s] ERROR:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

compose() { docker compose "$@"; }

# Baca satu variabel dari .env (tanpa men-source seluruh file).
env_get() {
	grep -E "^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=" .env | tail -1 \
		| sed -E 's/^[^=]*=//; s/[[:space:]]+#.*$//' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | tr -d '"'\'''
}

# Jangan pernah menunggu input user (deploy jalan non-interaktif lewat SSH dari
# GitHub Actions; prompt username/password git akan bikin job menggantung).
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}"

# --- 1. Pra-syarat ------------------------------------------------------------
[ -f .env ] || die ".env belum ada di $APP_DIR. Salin dari .env.example dan isi dulu (lihat DEPLOY.md)."
command -v git >/dev/null    || die "git tidak terpasang di server."
command -v curl >/dev/null   || die "curl tidak terpasang di server."
command -v docker >/dev/null || die "docker tidak terpasang di server."
docker compose version >/dev/null 2>&1 || die "plugin 'docker compose' tidak tersedia (butuh Compose v2)."

APP_PORT="$(env_get APP_PORT)"
APP_PORT="${APP_PORT:-8093}"

# Tolak deploy dengan secret kosong/salah format — APP_SECRET mengenkripsi API key
# provider AI yang tersimpan di database.
val="$(env_get APP_SECRET)"
if ! printf '%s' "$val" | grep -Eq '^[0-9a-fA-F]{64}$'; then
	die "APP_SECRET di .env harus 64 karakter hex. Isi dengan: openssl rand -hex 32"
fi
if [ "$(env_get DB_PASSWORD)" = "temu" ] || [ -z "$(env_get DB_PASSWORD)" ]; then
	warn "DB_PASSWORD masih bawaan. Port db tidak dibuka ke internet, tapi sebaiknya diganti."
fi
case "$(env_get AI_MOCK)" in
	1|true|TRUE|yes) warn "AI_MOCK aktif — semua hasil AI palsu. Matikan di production." ;;
esac

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	warn "Ada perubahan lokal yang belum di-commit di server:"
	git status --short --untracked-files=no
	warn "Perubahan ini akan DITIMPA oleh git reset --hard."
fi

# --- 2. Backup database -------------------------------------------------------
# Backup dilakukan sebelum kode baru masuk, karena backend menjalankan migrasi SQL
# otomatis saat start dan migrasi TIDAK ikut mundur saat rollback.
if [ "$SKIP_BACKUP" != "1" ] && [ -n "$(compose ps -q --status running db 2>/dev/null)" ]; then
	mkdir -p backups
	stamp="$(date +%Y%m%d-%H%M%S)"
	file="backups/temu-predeploy-$stamp.sql.gz"
	if compose exec -T db pg_dump -U temu -d temu --clean --if-exists | gzip > "$file" \
		&& [ "$(gzip -cd "$file" | head -c 1 | wc -c)" -gt 0 ]; then
		log "Backup DB -> $file ($(du -h "$file" | cut -f1))"
		# Simpan N backup pre-deploy terakhir saja.
		ls -1t backups/temu-predeploy-*.sql.gz 2>/dev/null | tail -n +"$((KEEP_BACKUPS + 1))" | xargs -r rm -f
	else
		rm -f "$file"
		warn "Backup DB gagal (db mungkin belum punya data). Lanjut deploy."
	fi
else
	log "Lewati backup DB."
fi

# --- 3. Ambil kode terbaru ----------------------------------------------------
OLD_SHA="$(git rev-parse HEAD)"
log "Commit saat ini : $(git log -1 --format='%h %s' "$OLD_SHA")"

log "git fetch origin $BRANCH ..."
if ! git fetch --prune origin "$BRANCH"; then
	remote_url="$(git remote get-url origin 2>/dev/null || echo '?')"
	warn "git fetch gagal. Remote saat ini: $remote_url"
	case "$remote_url" in
		https://*)
			warn "Remote memakai HTTPS. Kalau repo-nya private, server tidak punya kredensial"
			warn "dan git tidak bisa menanyakannya (deploy jalan non-interaktif)."
			warn "Solusi: pasang deploy key lalu pindah ke remote SSH — lihat langkah"
			warn "'Akses baca GitHub' di DEPLOY.md."
			;;
		git@*|ssh://*)
			ssh_host="${remote_url#git@}"; ssh_host="${ssh_host%%:*}"
			warn "Remote memakai SSH. Cek dari user ini: ssh -T git@${ssh_host}"
			warn "Pastikan deploy key masih aktif di repo GitHub, alias '${ssh_host}' ada di"
			warn "~/.ssh/config, dan host key GitHub ada di ~/.ssh/known_hosts."
			;;
	esac
	die "Tidak bisa mengambil kode terbaru dari origin/$BRANCH."
fi
NEW_SHA="$(git rev-parse "origin/$BRANCH")"

if [ "$OLD_SHA" = "$NEW_SHA" ]; then
	log "Sudah di commit terbaru ($(git rev-parse --short "$NEW_SHA")). Tetap rebuild & restart untuk memastikan container sinkron."
else
	log "Update ke     : $(git log -1 --format='%h %s' "$NEW_SHA")"
fi

echo "$OLD_SHA" > "$PREV_FILE"
git reset --hard "$NEW_SHA"

# --- 4 & 5. Build, jalankan, health check ------------------------------------
health_check() {
	local url="http://127.0.0.1:${APP_PORT}/api/health"
	local i
	for i in $(seq 1 "$HEALTH_RETRIES"); do
		if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
			log "Health check OK ($url) setelah ${i}x percobaan."
			return 0
		fi
		sleep "$HEALTH_DELAY"
	done
	return 1
}

bring_up() {
	# Build dulu baru up: selama build (yang paling lama) container lama tetap
	# melayani, downtime hanya saat container di-recreate.
	# Pakai && — di dalam `if ! bring_up` bash mematikan `set -e`, jadi kegagalan
	# build tidak boleh lolos ke `up`.
	log "docker compose build ..."
	compose build || return 1
	log "docker compose up -d ..."
	compose up -d --remove-orphans || return 1
}

rollback() {
	log "Rollback ke $(git rev-parse --short "$OLD_SHA") ..."
	git reset --hard "$OLD_SHA" || return 1
	bring_up
}

if ! bring_up; then
	warn "Build/start gagal."
	if [ "$NO_ROLLBACK" = "1" ]; then die "Deploy gagal saat build (rollback dimatikan)."; fi
	rollback || die "Rollback juga gagal. Perlu cek manual di server!"
	die "Deploy gagal saat build; sudah rollback ke commit sebelumnya."
fi

if ! health_check; then
	warn "Health check GAGAL setelah $((HEALTH_RETRIES * HEALTH_DELAY)) detik."
	compose ps
	compose logs --tail=80 app
	if [ "$NO_ROLLBACK" = "1" ]; then die "Health check gagal (rollback dimatikan)."; fi
	rollback || die "Rollback gagal di-build. Perlu cek manual di server!"
	if health_check; then
		die "Versi baru tidak sehat; sudah rollback dan versi lama jalan normal lagi."
	fi
	die "Versi baru tidak sehat DAN rollback juga tidak sehat. Perlu cek manual di server!"
fi

# --- 6. Bersih-bersih ---------------------------------------------------------
log "Hapus image dangling sisa build ..."
docker image prune -f >/dev/null || warn "docker image prune gagal (abaikan)."

compose ps
log "Deploy selesai: $(git log -1 --format='%h %s')"
