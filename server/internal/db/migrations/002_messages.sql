-- Pesan (chat) antar teman dari aplikasi Mac: ⌘-klik pet teman → jendela chat.
-- Dikirim real-time lewat WebSocket /api/app/ws; tabel ini riwayat + penanda belum dibaca.
CREATE TABLE messages (
    id         BIGSERIAL PRIMARY KEY,
    from_user  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    to_user    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    text       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    read_at    TIMESTAMPTZ
);
-- percakapan dua orang (arah mana pun), diurutkan dari yang terbaru
CREATE INDEX messages_pair_idx ON messages (LEAST(from_user, to_user), GREATEST(from_user, to_user), id DESC);
CREATE INDEX messages_unread_idx ON messages (to_user, from_user) WHERE read_at IS NULL;
