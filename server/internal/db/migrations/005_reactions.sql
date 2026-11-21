-- Emot lewat pet (messages.go, reactions): pesan yang berisi satu emot dari baki emot obrolan.
-- `text` tetap berisi emojinya, jadi aplikasi lama menampilkannya sebagai pesan biasa;
-- aplikasi baru memutar animasinya di atas pet pengirim.
ALTER TABLE messages ADD COLUMN reaction TEXT;
