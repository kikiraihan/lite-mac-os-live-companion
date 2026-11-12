# Runbook untuk AI agent: memasang Temu di VM katili.dev

> **Untuk siapa:** AI agent (Claude Code, dll.) yang bekerja **di dalam VM produksi** dan diminta
> memasang server + web Temu di `https://temu.katili.dev`. Ikuti urutan langkah apa adanya. Setiap
> langkah punya **cek**: jangan lanjut kalau cek gagal. Berhenti dan laporkan ke manusia.
>
> Dokumen pendamping untuk manusia: [`DEPLOY.md`](DEPLOY.md). Kalau keduanya berbeda, agent memakai
> runbook ini lalu melaporkan perbedaannya.
>
> Aplikasi Mac **tidak** dipasang di VM. Aplikasi itu dirilis lewat GitHub Releases (workflow `mac.yml`)
> dan menghubungi server ini di `https://temu.katili.dev`.

---

## 0. Aturan keras (berlaku sepanjang tugas)

VM ini **dipakai bersama** aplikasi produksi lain: **katilidev** (katili.dev), **AI Todo**
(`mac-os-ai-todo`), **our-life-planner** (web Jadwal), dan mungkin juga Racik / Pancar / undangankami.
Kesalahan pada aplikasi lain = gangguan layanan nyata.

**JANGAN:**

1. Menjalankan `docker compose down/stop/restart/up/build/pull` atau `make …` di folder project **lain**
   (mis. `/var/www/katilidev`, `/var/www/ai-todo`, `/var/www/our-life-planner`, `/var/www/racik`, `/var/www/pancar`).
2. `docker system prune`, `docker volume prune`, `docker network prune`, `docker volume rm`, atau
   menghapus image / container / volume / network yang namanya **tidak** berawalan `temu`.
3. Membaca, menyalin, atau mengubah `.env` project lain. Temu tidak butuh satu pun nilai dari project lain.
4. Mengedit server block nginx milik project lain atau `/etc/nginx/nginx.conf`. Temu hanya menambah
   **satu file baru**: `/etc/nginx/sites-available/temu.katili.dev`.
5. Me-restart / menghentikan nginx host. Yang boleh hanya `sudo nginx -t` lalu `sudo systemctl reload nginx`,
   dan **hanya kalau `nginx -t` sukses**.
6. Memakai port yang sudah `LISTEN` (§2.1).
7. Mengarang secret yang harus dari manusia (§3), atau mencetak secret (`APP_SECRET`, `DB_PASSWORD`,
   password admin, private key) ke output / log / laporan. Saat melapor, tulis "terisi" / "kosong".
8. Membuka port ke internet (`0.0.0.0`). Semua port Temu hanya di `127.0.0.1`.
9. Menjalankan `docker compose down -v` atau menghapus volume `temu_pgdata` setelah ada data.
10. Menyalakan `AI_MOCK=true` di production.

**BOLEH tanpa bertanya:** membaca status (`docker ps`, `ss`, `free`, `df`, `nginx -T`, `dig`), membuat folder
`/var/www/temu`, membuat `.env` Temu, `make up` / `make ps` / `make health` / `make logs` / `make admin` di folder
Temu, membuat file site nginx baru milik Temu, `nginx -t` + reload.

**Wajib bertanya dulu:** `certbot`, mengubah DNS / Cloudflare, menambah swap, mengubah crontab, menambah baris di
`~/.ssh/authorized_keys` (§9), apa pun yang butuh `sudo` selain yang disebut di atas.

---

## 1. Peta VM

Perkiraan dari `docker-compose.yml` tiap project. **Cocokkan dengan keadaan nyata di §2** — kalau berbeda,
keadaan nyata yang dipakai, dan catat di laporan.

| App | Folder (perkiraan) | Domain | Port host `127.0.0.1` |
|---|---|---|---|
| katilidev | `/var/www/katilidev` | katili.dev | 8082 (+ pgsql 5433) |
| our-life-planner (Jadwal) | `/var/www/our-life-planner` | jadwal.katili.dev | 8090 |
| AI Todo (`mac-os-ai-todo`) | `/var/www/ai-todo` | todo.katili.dev | 8095 (default `APP_PORT`) |
| Racik / Pancar / undangankami (kalau ada) | `/var/www/…` | `*.katili.dev` | 8091 / 8092 / 8083 |
| **Temu** | **`/var/www/temu`** | **temu.katili.dev** | **8093** (app); db **acak** |

Temu = project compose `temu`, container **`temu-app`** dan **`temu-db`**, network `temu_temu-network`,
volume `temu_pgdata`. Hanya **satu** port tetap yang dipublish: `APP_PORT` → container app `:8080`.
Postgres dipublish ke `127.0.0.1:<acak>` (biarkan `DB_HOST_PORT` kosong). Port 80/443 milik nginx host.

---

## 2. Pre-flight (hanya membaca)

```bash
whoami && hostname
docker version --format '{{.Server.Version}}' && docker compose version
groups | grep -qw docker && echo "docker tanpa sudo: OK" || echo "PERLU grup docker"
free -h; df -h /; nproc
```

**STOP bila:** Docker / Compose v2 tidak ada, sisa disk `/` < 5 GB, atau RAM available < 1 GB (build image
Temu butuh Node + Go; laporkan dan tanyakan apakah boleh menambah swap).

### 2.1 Port

```bash
sudo ss -ltnp | awk 'NR==1 || /127.0.0.1:|0.0.0.0:|\[::\]:|\*:/'
for p in 8093 8094 8096 8097 8098 8099; do ss -ltn "sport = :$p" | grep -q LISTEN && echo "$p: TERPAKAI" || echo "$p: bebas"; done
```

- Pakai **8093** bila bebas; kalau terpakai, port bebas **pertama** dari daftar di atas (8095 dilewati, itu milik AI Todo).
- Tetapkan sekali dan pakai di semua langkah berikutnya (`.env` `APP_PORT` **dan** `proxy_pass` nginx §7):

  ```bash
  export TEMU_PORT=8093   # ganti bila 8093 terpakai
  ```

  Shell berganti? Ambil lagi dari `.env`: `export TEMU_PORT=$(grep -E '^APP_PORT=' /var/www/temu/.env | cut -d= -f2)`.

### 2.2 Container & nginx yang sudah ada

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker ps -a --format '{{.Names}}' | grep -E '^temu' || echo "belum ada container temu"
sudo nginx -t
ls /etc/nginx/sites-enabled/
sudo nginx -T 2>/dev/null | grep -n "server_name" | grep -i "temu" || echo "belum ada server block temu"
```

- Sudah ada container `temu-*` → Temu pernah dipasang. **Jangan pasang ulang dari nol**; lanjut ke §10 (update) atau laporkan.
- **STOP bila** `nginx -t` sudah gagal **sebelum** Anda mengubah apa pun (laporkan; jangan perbaiki config project lain).

Catat hasil `curl` app lain sebagai pembanding sebelum & sesudah:

```bash
for p in 8082 8090 8095; do curl -s -o /dev/null -m 5 -w "$p: %{http_code}\n" http://127.0.0.1:$p/ || echo "$p: tidak menjawab"; done
```

---

## 3. Yang harus diminta ke manusia

Tanyakan **sekaligus dalam satu pesan**:

| Kebutuhan | Status | Catatan |
|---|---|---|
| Email superadmin | **wajib** | Akun admin Temu terpisah dari akun pengguna (boleh email sama) |
| Password superadmin awal | **wajib** | Atau izin agent membuat password acak dan memberikannya **hanya** di pesan ke manusia |
| Izin `certbot` untuk `temu.katili.dev` | wajib sebelum §7.3 | |
| DNS `temu.katili.dev` | info | Cek sendiri `dig +short temu.katili.dev`; kalau kosong minta manusia membuat record Cloudflare |
| API key provider AI (kenari.id / OpenRouter) | opsional, **bukan di `.env`** | Diisi manusia sendiri lewat `/admin/koneksi` setelah server jalan. Jangan minta key ini dikirim ke agent |

Yang **dibuat agent sendiri** (jangan ditanyakan): `APP_SECRET`, `DB_PASSWORD`.

> Repo `kikiraihan/lite-mac-os-live-companion` **public**, jadi clone lewat HTTPS tanpa deploy key.
> Kalau suatu hari repo dijadikan private, buat deploy key read-only dengan alias host sendiri
> (`Host github-temu`), **jangan** `Host github.com` di `~/.ssh/config` (bisa merusak project lain).

---

## 4. Ambil kode

```bash
sudo mkdir -p /var/www/temu && sudo chown "$USER":"$USER" /var/www/temu
test -d /var/www/temu/.git || git clone https://github.com/kikiraihan/lite-mac-os-live-companion.git /var/www/temu
cd /var/www/temu && git checkout main && git pull --ff-only
chmod +x scripts/*.sh
git log -1 --format='%h %s'
```

**Cek:** `git remote get-url origin` = `https://github.com/kikiraihan/lite-mac-os-live-companion.git`, dan
`GIT_TERMINAL_PROMPT=0 git fetch origin main` berhasil tanpa meminta apa pun (deploy otomatis memakai ini).

---

## 5. Buat `.env` Temu

> **Kalau `/var/www/temu/.env` sudah ada: JANGAN jalankan blok ini.** `APP_SECRET` baru membuat API key provider
> AI yang tersimpan di database tidak bisa dibuka. Langsung ke **Cek** di bawah.

```bash
cd /var/www/temu
test ! -f .env || { echo ".env SUDAH ADA — hentikan blok ini"; false; }
cp .env.example .env
chmod 600 .env

setenv() { # setenv KEY VALUE — ganti / isi satu baris di .env tanpa mencetak nilainya
  python3 - "$1" "$2" <<'PY'
import sys, re
k, v = sys.argv[1], sys.argv[2]
s = open('.env').read()
if re.search(rf'(?m)^{re.escape(k)}=', s):
    s = re.sub(rf'(?m)^{re.escape(k)}=.*$', lambda m: f'{k}={v}', s)
else:
    s += f'\n{k}={v}\n'
open('.env', 'w').write(s)
PY
}

setenv APP_ENV production
setenv PUBLIC_URL https://temu.katili.dev
setenv APP_PORT "${TEMU_PORT:-8093}"
setenv TRUST_PROXY true
setenv APP_SECRET "$(openssl rand -hex 32)"
setenv DB_PASSWORD "$(openssl rand -hex 24)"
setenv AI_MOCK false
```

**Cek** (tanpa mencetak secret):

```bash
v=$(grep -E '^APP_SECRET=' .env | cut -d= -f2-); [[ "$v" =~ ^[0-9a-f]{64}$ ]] && echo "APP_SECRET OK" || echo "APP_SECRET SALAH"
grep -E '^(APP_ENV|PUBLIC_URL|APP_PORT|TRUST_PROXY|AI_MOCK|SESSION_DAYS|MAC_DOWNLOAD_URL)=' .env
v=$(grep -E '^DB_PASSWORD=' .env | cut -d= -f2-); [ -n "$v" ] && [ "$v" != "ganti-password-db" ] && echo "DB_PASSWORD OK" || echo "DB_PASSWORD SALAH"
```

> **`APP_SECRET` wajib dicadangkan oleh manusia** (password manager), terpisah dari backup database. Tanpa nilai
> ini, API key provider AI di database harus diisi ulang. `DB_PASSWORD` hanya berlaku saat volume database
> pertama kali dibuat — jangan diganti setelahnya. Sampaikan keduanya di laporan (tanpa nilainya).

---

## 6. Build & jalankan

```bash
cd /var/www/temu
make up            # docker compose up -d --build --remove-orphans (hanya project temu)
make ps
make health        # {"status":"ok",...}
```

- Build pertama 3–10 menit (npm + Go). Jangan dihentikan selama `docker compose` masih berjalan.
- `make health` gagal → `make logs` (Ctrl-C setelah ±50 baris). Penyebab umum: `APP_SECRET` salah format,
  port terpakai, RAM habis (`dmesg | grep -i oom`).

**Cek isolasi & port:**

```bash
docker ps --filter name=temu --format 'table {{.Names}}\t{{.Ports}}'
# harus: temu-app 127.0.0.1:<APP_PORT>->8080 ; temu-db 127.0.0.1:<acak>->5432 — tidak ada 0.0.0.0
curl -fsS http://127.0.0.1:${TEMU_PORT:-8093}/api/health
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:${TEMU_PORT:-8093}/            # 200 (halaman depan)
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:${TEMU_PORT:-8093}/api/admin/overview   # 401
# app lain masih sehat (bandingkan dengan §2.2):
for p in 8082 8090 8095; do curl -s -o /dev/null -m 5 -w "$p: %{http_code}\n" http://127.0.0.1:$p/; done
```

---

## 7. nginx host + HTTPS

### 7.1 Server block (file baru)

```bash
sudo tee /etc/nginx/sites-available/temu.katili.dev >/dev/null <<NGINX
server {
	listen 80;
	listen [::]:80;
	server_name temu.katili.dev;

	# foto untuk generate maks. 8 MB, gambar hasil manual 12 MB (default nginx 1m → 413)
	client_max_body_size 14m;

	location / {
		proxy_pass http://127.0.0.1:${TEMU_PORT:-8093};
		proxy_http_version 1.1;
		proxy_set_header Host              \$host;
		proxy_set_header X-Real-IP         \$remote_addr;
		proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;
		proxy_read_timeout 60s;
	}
}
NGINX
sudo ln -sf /etc/nginx/sites-available/temu.katili.dev /etc/nginx/sites-enabled/temu.katili.dev
sudo nginx -t && sudo systemctl reload nginx
```

**`nginx -t` gagal:** hapus symlink yang barusan dibuat (`sudo rm /etc/nginx/sites-enabled/temu.katili.dev`),
jalankan `sudo nginx -t` lagi sampai kembali normal, lalu laporkan. Jangan reload dalam keadaan gagal.
Peringatan `conflicting server name "temu.katili.dev"` → sudah ada blok lain untuk domain ini: STOP dan laporkan.

### 7.2 DNS

```bash
dig +short temu.katili.dev
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: temu.katili.dev" http://127.0.0.1/    # 200 lewat nginx host
```

`dig` kosong → minta manusia membuat record Cloudflare **A `temu` → IP publik VM** (sama seperti subdomain lain;
SSL/TLS mode **Full (strict)**).

### 7.3 Sertifikat (setelah izin manusia)

```bash
sudo certbot --nginx -d temu.katili.dev
sudo nginx -T 2>/dev/null | grep -A14 "server_name temu.katili.dev" | grep -E "listen 443|client_max_body_size|proxy_pass"
```

Pastikan blok **443** hasil certbot tetap memuat `client_max_body_size` dan `proxy_pass`. Certbot gagal karena
record Cloudflare *proxied* → minta manusia men-set record ke **DNS only** sementara, ulangi, lalu kembalikan ke proxied.

---

## 8. Inisialisasi aplikasi

```bash
cd /var/www/temu
make admin EMAIL="<email dari manusia>" PASSWORD="<password dari manusia>"
curl -fsS https://temu.katili.dev/api/health
curl -s -o /dev/null -w "%{http_code}\n" https://temu.katili.dev/                      # 200
curl -s -o /dev/null -w "%{http_code}\n" https://temu.katili.dev/admin/login           # 200
curl -s -o /dev/null -w "%{http_code}\n" https://temu.katili.dev/api/admin/overview    # 401
curl -s https://temu.katili.dev/api/templates | head -c 120; echo                     # daftar 5 pet bawaan
curl -sI https://temu.katili.dev/ | grep -iE "content-security-policy|strict-transport" # header keamanan ada
```

> `make admin` menampilkan email & password di riwayat shell. Setelahnya jalankan `history -d $(history 1 | awk '{print $1}')`
> atau minta manusia menjalankan perintah itu sendiri.

Lalu sampaikan ke manusia — dikerjakan **di browser**, bukan oleh agent:

1. Masuk `https://temu.katili.dev/admin/login`.
2. **Koneksi AI → Tambah koneksi**: pilih *kenari.id* (gaya `images`, model mis. `gpt-image-2`) atau *OpenRouter*
   (gaya `chat`, model gambar yang menerima gambar masukan), tempel API key, simpan, klik **Tes koneksi**.
   Tanpa koneksi, pengguna tetap bisa membuat pet dari foto lewat cara manual (salin prompt ke ChatGPT).
3. **Pengaturan**: jatah generate per hari, buka / tutup pendaftaran.
4. Daftar akun pengguna di `https://temu.katili.dev/daftar`, lalu coba **Hubungkan akun…** dari aplikasi Mac.

### 8.1 Backup terjadwal (tanya dulu sebelum mengubah crontab)

```cron
47 3 * * * cd /var/www/temu && make backup >/dev/null 2>&1 && ls -1t backups/temu-2*.sql.gz | tail -n +15 | xargs -r rm -f
```

Cek dulu `crontab -l`: pilih menit yang tidak sama dengan backup project lain (supaya tidak bersamaan).

---

## 9. CI/CD (GitHub Actions → VM)

Alur yang sudah ada di repo:

```
PR / push branch ──▶ ci.yml   : gofmt · go vet · go test + PostgreSQL · govulncheck · template sprite sinkron
                                · npm audit · vite build · docker build · compose config
PR / push Sources/ ─▶ mac.yml : build Temu.app universal (macOS) · uji jalan · di main + versi baru → GitHub Release
push ke main ──────▶ deploy.yml: ci.yml (harus hijau) → [hanya bila variable DEPLOY_ENABLED=true]
                                SSH ke VM → scripts/ci-deploy-gate.sh → scripts/deploy.sh
                                (backup DB · git reset ke origin/main · build · up · health check · auto-rollback)
```

Bagian VM dikerjakan agent; bagian GitHub dikerjakan manusia (agent tidak punya akses ke pengaturan repo).
Kerjakan **setelah §6–§8 berhasil** (deploy manual sudah sehat).

### 9.1 Prasyarat VM

```bash
cd /var/www/temu
GIT_TERMINAL_PROMPT=0 git fetch origin main && echo "fetch OK"   # deploy.sh melakukan ini tanpa interaksi
docker ps >/dev/null && echo "docker tanpa sudo OK"              # deploy.sh tidak memakai sudo
test -x scripts/ci-deploy-gate.sh && test -x scripts/deploy.sh && echo "skrip OK"
git status --porcelain --untracked-files=no                      # harus kosong (deploy memakai reset --hard)
whoami                                                           # = SSH_USER untuk GitHub
```

**STOP bila** `git fetch` meminta sesuatu atau `docker ps` butuh sudo.

### 9.2 Key SSH khusus GitHub Actions (terkunci ke deploy Temu)

Key ini **terpisah** dari key project lain (katilidev, AI Todo, our-life-planner, …).

```bash
mkdir -p ~/temu-ci && chmod 700 ~/temu-ci
test -f ~/temu-ci/github_actions_temu || ssh-keygen -t ed25519 -C "github-actions-temu" -f ~/temu-ci/github_actions_temu -N ""
PUB="$(cat ~/temu-ci/github_actions_temu.pub)"
echo "$PUB"     # public key boleh ditampilkan
```

**Minta izin manusia**, lalu pasang dengan *forced command*. Key ini hanya bisa menjalankan
`scripts/ci-deploy-gate.sh`, yang hanya menerima perintah deploy persis dari `deploy.yml` untuk branch `main`
(tidak bisa membuka shell, forward port, atau menjalankan perintah lain):

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
grep -qF "$(cut -d' ' -f2 ~/temu-ci/github_actions_temu.pub)" ~/.ssh/authorized_keys \
  || echo "command=\"/var/www/temu/scripts/ci-deploy-gate.sh\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $PUB" >> ~/.ssh/authorized_keys
grep -c "github-actions-temu" ~/.ssh/authorized_keys     # 1
```

> Jangan ubah / hapus baris lain di `authorized_keys` (milik manusia dan project lain).

**Uji gerbang dari VM sendiri** (tidak benar-benar deploy — perintahnya sengaja salah):

```bash
OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/temu-ci/known_hosts_test -o BatchMode=yes"
ssh -i ~/temu-ci/github_actions_temu $OPTS "$(whoami)@127.0.0.1" "ls /" ; echo "exit=$?"
# harus: "ci-deploy-gate: perintah ditolak." dan exit=1
ssh -i ~/temu-ci/github_actions_temu $OPTS "$(whoami)@127.0.0.1" \
  "cd '/var/www/temu' && DEPLOY_BRANCH='fitur' SKIP_BACKUP='1' ./scripts/deploy.sh" ; echo "exit=$?"
# harus: "hanya branch 'main' yang boleh di-deploy" dan exit=1
rm -f ~/temu-ci/known_hosts_test
```

sshd tidak mengizinkan SSH ke 127.0.0.1 → lewati uji ini dan catat di laporan.

### 9.3 Nilai untuk GitHub

```bash
echo "SSH_USER = $(whoami)"
echo "SSH_PORT = $(sudo sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"   # kosong → 22
echo "APP_DIR  = /var/www/temu"
curl -s -4 https://ifconfig.me; echo "   ← IP publik VM (konfirmasi ke manusia)"
ssh-keyscan -p "${SSH_PORT:-22}" -H <IP-PUBLIK-VM> 2>/dev/null                   # → SSH_KNOWN_HOSTS (aman ditampilkan)
```

**Private key tidak boleh dicetak oleh agent.** Minta manusia menampilkannya sendiri di terminal VM lalu
menempelkannya ke GitHub:

```
cat ~/temu-ci/github_actions_temu
```

Checklist untuk manusia — **di GitHub**, repo `kikiraihan/lite-mac-os-live-companion`:

| # | Tempat | Isi |
|---|---|---|
| 1 | Settings → Secrets and variables → Actions → **Secrets** → *New repository secret* | `SSH_HOST` = IP publik VM |
| 2 | 〃 | `SSH_USER` = output `whoami` |
| 3 | 〃 | `SSH_PRIVATE_KEY` = isi `~/temu-ci/github_actions_temu` (termasuk baris BEGIN / END) |
| 4 | 〃 | `SSH_KNOWN_HOSTS` = output `ssh-keyscan -H` |
| 5 | 〃 (opsional) | `SSH_PORT` bila bukan 22, `APP_DIR` bila bukan `/var/www/temu` |
| 6 | Settings → Secrets and variables → Actions → **Variables** | `DEPLOY_ENABLED` = `true` (tanpa ini job deploy selalu dilewati) |
| 7 | 〃 (opsional) | `PUBLIC_URL` = `https://temu.katili.dev` (hanya untuk ringkasan job) |
| 8 | Settings → Environments → `production` | Dibuat otomatis saat deploy pertama; disarankan *Required reviewers* supaya deploy produksi butuh persetujuan |
| 9 | Settings → Branches → aturan untuk `main` (disarankan) | *Require status checks*: `Server (Go + PostgreSQL)`, `Web (Vue)`, `Docker image & compose`, `Template pet sinkron dengan Sprites.swift`, dan `build` (Mac app) |
| 10 | Settings → Actions → General → *Workflow permissions* | **Read and write** — dibutuhkan `mac.yml` untuk membuat tag & GitHub Release aplikasi Mac |

Setelah manusia mengonfirmasi secret tersimpan, **hapus private key dari VM** (GitHub sudah menyimpannya; public
key di `authorized_keys` tetap):

```bash
shred -u ~/temu-ci/github_actions_temu 2>/dev/null || rm -f ~/temu-ci/github_actions_temu
ls ~/temu-ci/
```

### 9.4 Uji pipeline pertama

Minta manusia: GitHub → Actions → **Deploy ke VPS** → *Run workflow* (branch `main`), atau merge PR ke `main`
yang menyentuh `server/` / `web/`. Pantau di VM:

```bash
cd /var/www/temu
journalctl -t temu-ci-gate --since "15 min ago" --no-pager 2>/dev/null | tail -5   # "deploy branch=main ..."
ls -1t backups/temu-predeploy-*.sql.gz 2>/dev/null | head -1                       # backup baru
git log -1 --format='%h %s'                                                       # = commit terbaru main
make health
```

| Gagal di job | Penyebab | Perbaikan |
|---|---|---|
| Job deploy *skipped* | variable `DEPLOY_ENABLED` belum `true` | §9.3 langkah 6 |
| `Permission denied (publickey)` | `SSH_PRIVATE_KEY` / `SSH_USER` salah, atau baris `authorized_keys` tidak ada | §9.2–§9.3 |
| `Host key verification failed` | `SSH_KNOWN_HOSTS` salah IP / port | ulangi `ssh-keyscan` |
| `ci-deploy-gate: perintah ditolak` | perintah SSH di `deploy.yml` tidak cocok dengan regex gerbang | samakan keduanya |
| macet di `git fetch` | remote meminta kredensial | `git remote get-url origin` harus URL HTTPS publik (§4) |

### 9.5 Rilis aplikasi Mac (cek, tidak mengubah VM)

Web menautkan tombol "Unduh untuk Mac" ke `MAC_DOWNLOAD_URL` (bawaan: halaman *latest release* GitHub).

```bash
curl -s https://api.github.com/repos/kikiraihan/lite-mac-os-live-companion/releases/latest | grep -E '"tag_name"|"name": "Temu' | head -3
```

Saat runbook ini ditulis sudah ada rilis `v1.0.0`. Kosong / 404 → belum ada rilis: sampaikan ke manusia bahwa
rilis dibuat otomatis oleh `mac.yml` hanya pada **push / merge ke `main`** yang menyentuh `Sources/` atau `VERSION`
dengan versi yang belum punya tag (*Run workflow* manual hanya membangun, tidak merilis). Pastikan langkah 10 di §9.3
sudah diatur.

### 9.6 Mencabut akses CI/CD

```bash
sed -i.bak '/github-actions-temu/d' ~/.ssh/authorized_keys && grep -c github-actions-temu ~/.ssh/authorized_keys  # 0
```

Lalu minta manusia menghapus secret `SSH_PRIVATE_KEY` dan men-set `DEPLOY_ENABLED` = `false` di GitHub.

---

## 10. Update (bila Temu sudah terpasang)

```bash
cd /var/www/temu
make deploy     # backup DB → git reset ke origin/main → build → up → health check → auto-rollback
make version
```

Setelah CI/CD aktif, update cukup lewat merge ke `main`; `make deploy` manual hanya untuk darurat.

---

## 11. Rollback / mencabut Temu (hanya Temu)

```bash
cd /var/www/temu
make rollback                       # kode ke commit sebelum deploy terakhir (migrasi SQL tidak ikut mundur)
make restore FILE=backups/temu-predeploy-<timestamp>.sql.gz   # bila data juga perlu dikembalikan
# Mencabut total (TANYA DULU):
docker compose down                 # container temu saja, volume tetap
sudo rm /etc/nginx/sites-enabled/temu.katili.dev && sudo nginx -t && sudo systemctl reload nginx
```

---

## 12. Troubleshooting

| Gejala | Penyebab umum | Tindakan |
|---|---|---|
| `make up` → `port is already allocated` | `APP_PORT` bentrok | port bebas (§2.1); ubah `APP_PORT` di `.env` **dan** `proxy_pass` nginx; `make up` |
| log `APP_SECRET wajib diisi` / `harus 64 karakter hex` | `.env` | perbaiki §5 (jangan ganti nilai yang sudah dipakai) |
| Build berhenti / `Killed` | RAM habis | `dmesg \| grep -i oom`; laporkan, tanyakan swap |
| Browser 413 saat unggah foto | `client_max_body_size` hilang di blok 443 | tambahkan di blok 443 file Temu, `nginx -t`, reload |
| Browser 502 | app mati / port nginx salah | `make ps`, cocokkan `proxy_pass` dengan `APP_PORT` |
| Login berhasil tapi langsung keluar lagi | `PUBLIC_URL` bukan `https://…` atau situs dibuka lewat http | cookie sesi memakai `__Host-` + `Secure`: pastikan `PUBLIC_URL=https://temu.katili.dev` dan akses lewat HTTPS |
| Semua pengguna kena "Terlalu banyak permintaan" | IP pengguna terbaca sebagai IP Cloudflare/nginx | `TRUST_PROXY=true` di `.env`, lalu `make up` |
| Admin: koneksi AI "API key tidak bisa dibuka" | `APP_SECRET` berubah | isi ulang API key di `/admin/koneksi` |
| Aplikasi Mac: "Server tidak bisa dihubungi" | DNS / sertifikat / nginx | `curl -fsS https://temu.katili.dev/api/health` dari luar VM |

---

## 13. Format laporan akhir ke manusia

```
Temu terpasang: <ya/tidak/sebagian>
Commit: <hash + pesan>
Port: app 127.0.0.1:<APP_PORT>, db 127.0.0.1:<acak> — app lain tetap sehat: 8082 <kode>, 8090 <kode>, 8095 <kode>
Container: temu-app <status>, temu-db <status>
Health lokal: <ok/gagal>   Health https: <ok/gagal>
nginx: /etc/nginx/sites-available/temu.katili.dev, nginx -t <ok>, certbot <ok/belum>, DNS <ok/belum>
Secret: APP_SECRET dibuat (WAJIB DICADANGKAN), DB_PASSWORD dibuat
Superadmin: <email> dibuat — langkah berikut di browser: Koneksi AI, Pengaturan
Backup terjadwal: <terpasang jam … / belum, menunggu izin>
CI/CD: key Actions dgn forced command <ya/tidak>, uji gerbang <ok/dilewati>, secret & DEPLOY_ENABLED di GitHub <dikonfirmasi/belum>,
       deploy pertama via Actions <ok/belum>, private key dihapus dari VM <ya/tidak>
Rilis aplikasi Mac: <tag terbaru / belum ada>
Belum selesai / butuh manusia: <daftar>
```
