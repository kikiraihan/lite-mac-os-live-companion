#!/usr/bin/env python3
"""Buat ulang Resources/Reactions/*.png dari Microsoft Fluent Emoji Animated (lisensi MIT).

Sumber: https://github.com/microsoft/fluentui-emoji-animated (APNG 256×256, 24 fps).
Hasil: satu lembar sprite per emot, 8 kolom, tiap bingkai 128×128 (tajam di ±64 pt layar Retina),
palet 256 warna supaya kecil. Jumlah bingkai harus sama dengan `Reaction.art` di Sources/Temu/Reactions.swift.

    python3 scripts/fluent-reactions.py        # butuh Pillow & internet
"""
import io
import os
import sys
import urllib.parse
import urllib.request

from PIL import Image

BASE = "https://media.githubusercontent.com/media/microsoft/fluentui-emoji-animated/main/assets/"
SOURCES = {
    "clap": "Clapping hands/Default/animated/clapping_hands_animated_default.png",
    "like": "Thumbs up/Default/animated/thumbs_up_animated_default.png",
    "love": "Red heart/animated/red_heart_animated.png",
    "love2": "Sparkling heart/animated/sparkling_heart_animated.png",
    "haha": "Face with tears of joy/animated/face_with_tears_of_joy_animated.png",
    "wow": "Face with open mouth/animated/face_with_open_mouth_animated.png",
    "party": "Party popper/animated/party_popper_animated.png",
    "yay": "Partying face/animated/partying_face_animated.png",
}
SIDE, COLS = 128, 8
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "Reactions")


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, path in SOURCES.items():
        data = urllib.request.urlopen(BASE + urllib.parse.quote(path)).read()
        im = Image.open(io.BytesIO(data))
        frames = []
        for i in range(im.n_frames):
            im.seek(i)
            frames.append(im.convert("RGBA").resize((SIDE, SIDE), Image.LANCZOS))
        rows = (len(frames) + COLS - 1) // COLS
        sheet = Image.new("RGBA", (COLS * SIDE, rows * SIDE))
        for i, f in enumerate(frames):
            sheet.paste(f, ((i % COLS) * SIDE, (i // COLS) * SIDE))
        # satu palet untuk semua bingkai → warna tidak berkedip antar-bingkai
        sheet.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG) \
            .save(os.path.join(OUT, name + ".png"), optimize=True)
        print(f"{name}: {len(frames)} bingkai", file=sys.stderr)


if __name__ == "__main__":
    main()
