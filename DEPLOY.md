# Deploy Temani ke VPS

Server + web berjalan sebagai satu container (`temani-app`) dan satu PostgreSQL (`temani-db`). Hanya
`127.0.0.1:8093` yang dibuka di host; nginx host + Cloudflare yang menghadap internet.

Kalau VPS-nya sama dengan project lain (katilidev 8082, undangankami 8083, our-life-planner 8090, Racik 8091,
Pancar 8092): Temani memakai **8093**, folder `/var/www/temani`, project compose `temani` — tidak menyentuh yang lain.

```
push ke main
   ▼
CI (ci.yml): gofmt · vet · test + PostgreSQL · template sinkron · build web · docker build
   ▼ hijau, dan variable DEPLOY_ENABLED = true
Deploy (deploy.yml): SSH → /var/www/temani/scripts/deploy.sh
   ├─ tolak bila APP_SECRET kosong / bukan 64 hex
   ├─ backup PostgreSQL → backups/temani-predeploy-<ts>.sql.gz (10 terakhir disimpan)
   ├─ git reset --hard origin/main
   ├─ docker compose build → up -d   (migrasi SQL otomatis saat start)
   ├─ health check http://127.0.0.1:8093/api/health
   └─ gagal build / health → rollback otomatis ke commit sebelumnya
```

## 1. Persiapan sekali di VPS

```bash
sudo mkdir -p /var/www/temani && sudo chown $USER /var/www/temani
git clone https://github.com/kikiraihan/lite-mac-os-live-companion.git /var/www/temani
cd /var/www/temani && chmod +x scripts/*.sh

cp .env.example .env
openssl rand -hex 32        # → APP_SECRET (simpan salinannya TERPISAH dari backup database)
nano .env                   # isi APP_SECRET, DB_PASSWORD, PUBLIC_URL
chmod 600 .env

make up
make health                 # {"status":"ok",…}
make admin EMAIL=kamu@contoh.id PASSWORD='password-panjang-sekali'
```

Masuk admin di `https://<domain>/admin/login`, lalu:

1. **Koneksi AI → Tambah koneksi**: pilih kenari.id atau OpenRouter, tempel API key, simpan, klik **Tes koneksi**.
   Tanpa koneksi, pengguna tetap bisa membuat pet dari foto lewat cara manual (salin prompt ke ChatGPT).
2. **Pengaturan**: jatah generate per hari, buka/tutup pendaftaran.

## 2. nginx host + DNS

```bash
sudo cp deploy/nginx-temani.conf.example /etc/nginx/sites-available/temani
sudo nano /etc/nginx/sites-available/temani      # server_name
sudo ln -s /etc/nginx/sites-available/temani /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

Di Cloudflare: record `A` untuk subdomain → IP VPS (proxied), SSL mode Full. `PUBLIC_URL` di `.env` harus
`https://…` supaya cookie sesi memakai `Secure` + awalan `__Host-`.

## 3. Auto deploy dari GitHub Actions

Bawaan **mati**. Untuk menyalakan:

1. Di VPS, buat key khusus Actions dan kunci ke skrip gerbang (key ini tidak bisa membuka shell):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/temani_actions -N '' -C github-actions-temani
   echo "command=\"/var/www/temani/scripts/ci-deploy-gate.sh\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $(cat ~/.ssh/temani_actions.pub)" >> ~/.ssh/authorized_keys
   ```
2. Repo → Settings → Secrets and variables → Actions:
   - Secrets: `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY` (isi `~/.ssh/temani_actions`), opsional `SSH_PORT`,
     `SSH_KNOWN_HOSTS` (`ssh-keyscan -H <host>`), `APP_DIR` (bawaan `/var/www/temani`).
   - Variables: `DEPLOY_ENABLED` = `true`, opsional `PUBLIC_URL`.
3. Buat environment `production` (Settings → Environments); boleh diberi persetujuan manual.

## 4. Operasi harian

| Perintah | Guna |
|---|---|
| `make logs` | ikuti log |
| `make backup` | backup database ke `backups/` |
| `make restore FILE=…` | restore |
| `make deploy` | deploy manual (backup + pull + build + health + rollback) |
| `make rollback` | kembali ke commit sebelum deploy terakhir |
| `make admin EMAIL=… PASSWORD=…` | buat / reset superadmin |

Catatan:

- Rollback hanya memundurkan kode; migrasi SQL tidak ikut mundur. Kalau perlu, restore backup pre-deploy.
- `APP_SECRET` hilang / berubah → API key provider AI di database tidak bisa dibuka; isi ulang di admin.
- `AI_MOCK=true` membuat generate memakai gambar palsu. Hanya untuk demo.

## 5. Aplikasi Mac

Aplikasi Mac dirilis lewat GitHub Releases (workflow `mac.yml`), bukan lewat VPS. Alamat server bawaannya
`https://temani.katili.dev` (`Account.defaultServer` di `Sources/Temani/Client.swift`); ganti konstanta itu
kalau domainmu berbeda, atau minta pengguna mengisinya di Pengaturan → Akun.
