#!/bin/bash
# Membuat dist/install-Temani.command: installer satu file
# (source Swift + Info.plist ditanam di dalamnya, compile di Mac pengguna)
set -e
cd "$(dirname "$0")/.."
mkdir -p dist
OUT="dist/install-Temani.command"

{
cat <<'HEAD'
#!/bin/bash
# ============================================================
#  Installer Temani
#  Jalankan:  bash install-Temani.command
#  (compile + pasang ke /Applications + jalankan otomatis)
# ============================================================
set -e
clear
echo "=========================================="
echo "   Installer Temani"
echo "=========================================="

# 1. Cek versi macOS (butuh 13 Ventura ke atas)
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 13 ]; then
  echo "❌ Butuh macOS 13 (Ventura) atau lebih baru. Versi Anda: $(sw_vers -productVersion)"
  read -n 1 -s -r -p "Tekan tombol apa saja untuk keluar..."; exit 1
fi

# 2. Cek compiler Swift (Xcode Command Line Tools)
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "⚠️  Xcode Command Line Tools belum terpasang."
  echo "   Jendela instalasi Apple akan muncul — klik 'Install' dan tunggu sampai selesai."
  echo "   Setelah itu, jalankan installer ini lagi."
  xcode-select --install 2>/dev/null || true
  read -n 1 -s -r -p "Tekan tombol apa saja untuk keluar..."; exit 0
fi

# 3. Siapkan folder kerja sementara
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
APP="Temani.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 4. Source code aplikasi (satu heredoc per file .swift)
HEAD
for f in Sources/Temani/*.swift; do
  echo "cat > $(basename "$f") <<'SWIFT_EOF'"
  cat "$f"
  echo "SWIFT_EOF"
done
echo ""
echo "cat > \"\$APP/Contents/Info.plist\" <<'PLIST'"
cat Resources/Info.plist
echo "PLIST"
cat <<'TAIL'

echo "▶ Compile (± 30 detik)..."
swiftc -O -swift-version 5 *.swift -o "$APP/Contents/MacOS/Temani"

echo "▶ Codesign (ad-hoc)..."
codesign --force --sign - "$APP"

# 5. Tutup versi lama (kalau ada), lalu pasang
pkill -x Temani 2>/dev/null || true
DEST="/Applications"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/"
xattr -cr "$DEST/$APP" 2>/dev/null || true

echo "▶ Menjalankan Temani..."
open "$DEST/$APP"

echo ""
echo "✅ Selesai! Temani terpasang di: $DEST/$APP"
echo "   • Lihat ikonnya di menu bar (kanan atas)."
echo "   • Tahan ⌘ lalu seret ikon ke dekat jam supaya tidak tersembunyi."
echo "   • Klik ikon pet → Pengaturan… → 'Buka saat login' agar otomatis jalan."
echo "   • Klik ikon pet → 'Hubungkan akun…' untuk memakai pet buatanmu sendiri."
echo ""
read -n 1 -s -r -p "Tekan tombol apa saja untuk menutup jendela ini..."
TAIL
} > "$OUT"

chmod +x "$OUT"
echo "✅ $OUT"
