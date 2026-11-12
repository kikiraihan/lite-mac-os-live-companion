#!/usr/bin/env bash
#
# Gerbang SSH untuk GitHub Actions (forced command di ~/.ssh/authorized_keys).
#
# Key SSH milik GitHub Actions dipasang dengan:
#   command="/var/www/temu/scripts/ci-deploy-gate.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... github-actions-temu
#
# Akibatnya key itu TIDAK bisa membuka shell atau menjalankan perintah lain: apa pun yang
# dikirim workflow masuk ke $SSH_ORIGINAL_COMMAND dan hanya bentuk persis dari
# .github/workflows/deploy.yml yang diterima:
#   cd '<folder ini>' && DEPLOY_BRANCH='main' SKIP_BACKUP='0|1' ./scripts/deploy.sh
# Branch selain `main` ditolak. Kalau key bocor, penyerang hanya bisa memicu deploy `main`.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CMD="${SSH_ORIGINAL_COMMAND:-}"
ALLOWED_BRANCH="${TEMU_DEPLOY_BRANCH:-main}"

re="^cd '([^']+)' && DEPLOY_BRANCH='([A-Za-z0-9._/-]+)' SKIP_BACKUP='([01])' \./scripts/deploy\.sh$"
if [[ ! "$CMD" =~ $re ]]; then
	echo "ci-deploy-gate: perintah ditolak." >&2
	logger -t temu-ci-gate "DITOLAK: ${CMD:0:200}" 2>/dev/null || true
	exit 1
fi
dir="${BASH_REMATCH[1]}"
branch="${BASH_REMATCH[2]}"
skip="${BASH_REMATCH[3]}"

if [ "$dir" != "$APP_DIR" ]; then
	echo "ci-deploy-gate: folder '$dir' bukan folder Temu ($APP_DIR)." >&2
	exit 1
fi
if [ "$branch" != "$ALLOWED_BRANCH" ]; then
	echo "ci-deploy-gate: hanya branch '$ALLOWED_BRANCH' yang boleh di-deploy (diminta: '$branch')." >&2
	exit 1
fi

logger -t temu-ci-gate "deploy branch=$branch skip_backup=$skip" 2>/dev/null || true
cd "$APP_DIR"
exec env DEPLOY_BRANCH="$branch" SKIP_BACKUP="$skip" ./scripts/deploy.sh
