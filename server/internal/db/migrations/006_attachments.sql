-- Lampiran di obrolan (attachments.go): gambar / file, disimpan di server paling lama sehari.
-- Data tinggal di message_files (dihapus saat kedaluwarsa atau saat pesan sekali lihat dibuka);
-- keterangannya tetap di messages supaya obrolan bisa menulis "Foto · sudah dihapus".
-- `text` berisi label ("📷 Foto", "📎 laporan.pdf"), jadi aplikasi lama menampilkannya sebagai pesan biasa.
ALTER TABLE messages
    ADD COLUMN attach_kind       TEXT,        -- 'image' | 'file'; NULL = bukan lampiran
    ADD COLUMN attach_name       TEXT,
    ADD COLUMN attach_mime       TEXT,
    ADD COLUMN attach_size       INT,
    ADD COLUMN attach_once       BOOLEAN NOT NULL DEFAULT false, -- sekali lihat / sekali unduh
    ADD COLUMN attach_expires_at TIMESTAMPTZ,
    ADD COLUMN attach_opened_at  TIMESTAMPTZ; -- pesan sekali lihat sudah dibuka penerimanya

CREATE TABLE message_files (
    message_id BIGINT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
    data       BYTEA NOT NULL
);
-- pembersih (RunCleanup) mencari lampiran yang sudah lewat masanya
CREATE INDEX messages_attach_expires_idx ON messages (attach_expires_at) WHERE attach_expires_at IS NOT NULL;
