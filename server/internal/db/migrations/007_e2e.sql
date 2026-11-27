-- Enkripsi ujung ke ujung (e2e.go). Server hanya menyimpan kunci PUBLIK tiap Mac dan ciphertext;
-- kunci privat tidak pernah keluar dari Mac (Keychain). Pesan lama tetap teks biasa (e2e = NULL).
CREATE TABLE device_keys (
    device_id  UUID PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    agree_pub  BYTEA NOT NULL, -- X25519, untuk membuka amplop kunci pesan
    sign_pub   BYTEA NOT NULL, -- Ed25519, tanda tangan pesan dari Mac ini
    sig        BYTEA NOT NULL, -- tanda tangan sign_pub atas agree_pub
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- {"v":1,"from_device":…,"ct":…,"keys":{device_id: amplop},"sig":…}; NULL = pesan teks biasa
ALTER TABLE messages ADD COLUMN e2e JSONB;
