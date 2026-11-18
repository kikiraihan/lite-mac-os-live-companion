-- Status online teman (live.go): pemilik akun boleh menyembunyikannya.
-- true = teman selalu melihatnya offline, walaupun Temu sedang terbuka di Mac-nya.
ALTER TABLE users ADD COLUMN hide_presence BOOLEAN NOT NULL DEFAULT false;
