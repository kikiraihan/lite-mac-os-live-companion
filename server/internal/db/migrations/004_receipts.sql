-- Status pesan seperti WhatsApp (messages.go): ✓ terkirim (baris ada), ✓✓ diterima (delivered_at:
-- Mac penerima sudah menerimanya), ✓✓ biru dibaca (read_at).
ALTER TABLE messages ADD COLUMN delivered_at TIMESTAMPTZ;
-- pesan lama yang sudah dibaca pasti sudah diterima
UPDATE messages SET delivered_at = read_at WHERE read_at IS NOT NULL;
CREATE INDEX messages_undelivered_idx ON messages (to_user) WHERE delivered_at IS NULL;
