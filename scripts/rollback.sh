#!/usr/bin/env bash
#
# Rollback manual ke commit sebelum deploy terakhir.
# Dijalankan DI VPS: ./scripts/rollback.sh  (atau `make rollback`)
#
# Bisa juga ke commit tertentu: ./scripts/rollback.sh <sha>
#
# Catatan: rollback hanya memundurkan KODE. Migrasi SQL yang sudah dijalankan versi
# baru tidak ikut mundur — kalau perlu, restore backup pre-deploy:
#   make restore FILE=backups/temu-predeploy-<timestamp>.sql.gz
#
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

PREV_FILE="$APP_DIR/.deploy-previous"
TARGET="${1:-}"

if [ -z "$TARGET" ]; then
	[ -f "$PREV_FILE" ] || {
		echo "Tidak ada catatan deploy sebelumnya ($PREV_FILE)." >&2
		echo "Sebutkan commit tujuan: ./scripts/rollback.sh <sha>" >&2
		exit 1
	}
	TARGET="$(cat "$PREV_FILE")"
fi

git rev-parse --verify "$TARGET^{commit}" >/dev/null 2>&1 || {
	echo "Commit '$TARGET' tidak ditemukan di repo ini." >&2
	exit 1
}

echo "Rollback dari $(git log -1 --format='%h %s') ke $(git log -1 --format='%h %s' "$TARGET")"
git reset --hard "$TARGET"
docker compose build
docker compose up -d --remove-orphans
docker compose ps
echo "Rollback selesai."
