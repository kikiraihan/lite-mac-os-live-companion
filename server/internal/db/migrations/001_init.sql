-- Temani — skema awal.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------- pengguna ----------------
CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email         TEXT NOT NULL,
    name          TEXT NOT NULL,
    -- nama pengguna unik (huruf kecil, angka, garis bawah) untuk dicari teman
    handle        TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    disabled_at   TIMESTAMPTZ,
    last_seen_at  TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_email_key ON users (lower(email));
CREATE UNIQUE INDEX users_handle_key ON users (lower(handle));

CREATE TABLE sessions (
    id_hash    TEXT PRIMARY KEY,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ip         TEXT NOT NULL DEFAULT '',
    user_agent TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX sessions_user_idx ON sessions (user_id);

-- ---------------- admin (terpisah total dari pengguna) ----------------
CREATE TABLE admins (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email         TEXT NOT NULL,
    name          TEXT NOT NULL DEFAULT '',
    password_hash TEXT NOT NULL,
    -- superadmin boleh mengelola akun admin lain
    super         BOOLEAN NOT NULL DEFAULT false,
    disabled_at   TIMESTAMPTZ,
    last_login_at TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX admins_email_key ON admins (lower(email));

CREATE TABLE admin_sessions (
    id_hash    TEXT PRIMARY KEY,
    admin_id   UUID NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
    ip         TEXT NOT NULL DEFAULT '',
    user_agent TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE audit_log (
    id         BIGSERIAL PRIMARY KEY,
    admin_id   UUID REFERENCES admins(id) ON DELETE SET NULL,
    action     TEXT NOT NULL,
    target     TEXT NOT NULL DEFAULT '',
    meta       JSONB NOT NULL DEFAULT '{}',
    ip         TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------- pet ----------------
-- sheet = PNG 128×128 (4×4 pose, tiap pose 32×32) — lihat internal/sprite.
CREATE TABLE pets (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    bio        TEXT NOT NULL DEFAULT '',
    sheet      BYTEA NOT NULL,
    sheet_ver  INT NOT NULL DEFAULT 1,
    -- template | drawn | ai | upload
    origin     TEXT NOT NULL DEFAULT 'template',
    -- tampil di Mac pemiliknya
    on_mac     BOOLEAN NOT NULL DEFAULT true,
    -- disembunyikan admin (moderasi)
    hidden_at  TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX pets_owner_idx ON pets (owner_id);

-- ---------------- pertemanan ----------------
CREATE TABLE friendships (
    user_a     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user_b     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_a, user_b),
    CHECK (user_a < user_b)
);
CREATE INDEX friendships_b_idx ON friendships (user_b);

CREATE TABLE friend_invites (
    code       TEXT PRIMARY KEY,
    from_user  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    uses       INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE friend_requests (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    from_user  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    to_user    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (from_user, to_user)
);

-- Pet titipan: teman meminta pet kita untuk ditampilkan di Mac-nya (tautan hidup, bukan salinan).
CREATE TABLE pet_shares (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pet_id     UUID NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
    to_user    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- requested | approved
    status     TEXT NOT NULL DEFAULT 'requested',
    on_mac     BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_at TIMESTAMPTZ,
    UNIQUE (pet_id, to_user)
);
CREATE INDEX pet_shares_to_idx ON pet_shares (to_user);

-- Sapaan antar teman; muncul sebagai balon kata pet di Mac penerima.
CREATE TABLE nudges (
    id         BIGSERIAL PRIMARY KEY,
    from_user  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    to_user    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    text       TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    seen_at    TIMESTAMPTZ
);
CREATE INDEX nudges_to_idx ON nudges (to_user) WHERE seen_at IS NULL;

-- ---------------- aplikasi Mac ----------------
CREATE TABLE devices (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name         TEXT NOT NULL DEFAULT 'Mac',
    token_hash   TEXT NOT NULL UNIQUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ
);

-- Menghubungkan Mac: aplikasi membuat kode, pengguna menyetujuinya di web, aplikasi mengambil token.
CREATE TABLE device_links (
    code        TEXT PRIMARY KEY,
    poll_hash   TEXT NOT NULL UNIQUE,
    device_name TEXT NOT NULL DEFAULT 'Mac',
    user_id     UUID REFERENCES users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at  TIMESTAMPTZ NOT NULL
);

-- ---------------- AI ----------------
-- Koneksi ke provider AI, dikelola dari admin. API key dienkripsi (AES-GCM, APP_SECRET).
CREATE TABLE ai_connections (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT NOT NULL,
    -- kenari | openrouter | custom
    kind          TEXT NOT NULL,
    base_url      TEXT NOT NULL,
    api_key_enc   BYTEA NOT NULL,
    image_model   TEXT NOT NULL,
    -- chat   : POST /chat/completions + modalities (OpenRouter)
    -- images : POST /images/edits multipart (gaya OpenAI Images; kenari)
    style         TEXT NOT NULL DEFAULT 'chat',
    enabled       BOOLEAN NOT NULL DEFAULT true,
    -- makin kecil makin dulu dicoba
    priority      INT NOT NULL DEFAULT 100,
    last_test_at  TIMESTAMPTZ,
    last_test_ok  BOOLEAN,
    last_test_msg TEXT NOT NULL DEFAULT '',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE generations (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- ai | manual
    mode          TEXT NOT NULL,
    -- queued | running | done | failed
    status        TEXT NOT NULL DEFAULT 'queued',
    -- foto pengguna: dihapus begitu proses selesai
    photo         BYTEA,
    photo_mime    TEXT NOT NULL DEFAULT '',
    note          TEXT NOT NULL DEFAULT '',
    connection_id UUID REFERENCES ai_connections(id) ON DELETE SET NULL,
    provider      TEXT NOT NULL DEFAULT '',
    model         TEXT NOT NULL DEFAULT '',
    error         TEXT NOT NULL DEFAULT '',
    result_sheet  BYTEA,
    duration_ms   INT NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at   TIMESTAMPTZ
);
CREATE INDEX generations_user_idx ON generations (user_id, created_at DESC);
CREATE INDEX generations_status_idx ON generations (status) WHERE status IN ('queued','running');

CREATE TABLE settings (
    key   TEXT PRIMARY KEY,
    value JSONB NOT NULL
);
