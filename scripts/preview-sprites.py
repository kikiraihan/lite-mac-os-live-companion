#!/usr/bin/env python3
"""Render sprite bawaan dari Sources/Temu/Sprites.swift (satu-satunya sumber gambar).

Hasil:
  server/internal/sprite/templates/<id>.png  sheet 128×128 (4×4 pose, 32×32) untuk server & web
  docs/sprites.png                           lembar pratinjau (diperbesar) untuk README

Jalankan ulang setiap kali gambar di Sprites.swift berubah:  python3 scripts/preview-sprites.py
Butuh Pillow (pip install pillow).
"""
import re
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = (ROOT / "Sources/Temu/Sprites.swift").read_text()

ART = {}
for name, body in re.findall(r'static let (\w+) = """\n(.*?)\n\s*"""', SRC, re.S):
    ART[name] = [line.strip() for line in body.split("\n") if line.strip()]


def grid(name):
    rows = [list(r) for r in ART[name]]
    w = max(len(r) for r in rows)
    return [r + ["."] * (w - len(r)) for r in rows]


def hexrgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


SPECIES = []
for line in ART["species"]:
    sid, title, default, ears, tail, cols = line.split("|")
    o, b, l, p, e = [hexrgb(h) for h in cols.split()]
    pal = {"o": o, "b": b, "l": l, "p": p, "e": e, "w": (255, 255, 255), "r": (230, 60, 80), "T": o, "t": b}
    SPECIES.append(dict(id=sid, title=title, ears=ears, tail=tail == "1", pal=pal))

EARS = {"cat": "earsCat", "bunny": "earsBunny", "bear": "earsBear"}
FEET = {"stand": "feetStand", "walkA": "feetWalkA", "walkB": "feetWalkB"}


def compose(pose, face, sp):
    """Harus sama dengan Sprites.compose di Sprites.swift."""
    g = grid("loaf") if pose == "loaf" else grid("body") + grid(FEET[pose])
    top = next(i for i, r in enumerate(g) if "o" in r)
    ears = grid(EARS[sp["ears"]])
    for i, row in enumerate(ears):
        y = top - len(ears) + 1 + i
        if not 0 <= y < len(g):
            continue
        for x, c in enumerate(row):
            if c == "." or (c == "o" and g[y][x] == "b"):
                continue
            g[y][x] = c
    for i, row in enumerate(grid("face" + face)):
        y = top + 4 + i
        for x, c in enumerate(row):
            if g[y][x + 3] not in "o.":
                g[y][x + 3] = c
    if not sp["tail"]:
        g = [["." if c in "Tt" else c for c in r] for r in g]
    return g


# 16 pose sheet → (pose, wajah, geser ke atas) — sama dengan Skin.builtin di Sprites.swift
FRAMES = [
    ("stand", "Normal", 0), ("stand", "Blink", 0), ("walkA", "Normal", 0), ("walkB", "Normal", 0),
    ("stand", "Happy", 0), ("stand", "Love", 0), ("stand", "Surprise", 0), ("stand", "Sad", 0),
    ("stand", "Munch", 0), ("stand", "Dizzy", 0), ("loaf", "Normal", 0), ("loaf", "Sleep", 0),
    ("walkA", "Happy", 4), ("stand", "Happy", 1), ("walkA", "Happy", 0), ("walkB", "Happy", 2),
]
CELL = 32


def sheet(sp):
    im = Image.new("RGBA", (CELL * 4, CELL * 4), (0, 0, 0, 0))
    for i, (pose, face, lift) in enumerate(FRAMES):
        g = compose(pose, face, sp)
        ox = (i % 4) * CELL + (CELL - len(g[0])) // 2
        oy = (i // 4) * CELL + CELL - len(g) - lift
        for y, row in enumerate(g):
            for x, c in enumerate(row):
                if c != ".":
                    im.putpixel((ox + x, oy + y), sp["pal"][c] + (255,))
    return im


def main():
    out = ROOT / "server/internal/sprite/templates"
    out.mkdir(parents=True, exist_ok=True)
    zoom = 4
    preview = Image.new("RGBA", (CELL * 16 * zoom, CELL * len(SPECIES) * zoom), (238, 240, 255, 255))
    for j, sp in enumerate(SPECIES):
        s = sheet(sp)
        s.save(out / f"{sp['id']}.png", optimize=True)
        for i in range(16):
            cell = s.crop(((i % 4) * CELL, (i // 4) * CELL, (i % 4 + 1) * CELL, (i // 4 + 1) * CELL))
            cell = cell.resize((CELL * zoom, CELL * zoom), Image.NEAREST)
            preview.alpha_composite(cell, (i * CELL * zoom, j * CELL * zoom))
    (ROOT / "docs").mkdir(exist_ok=True)
    preview.save(ROOT / "docs/sprites.png", optimize=True)
    print(f"{len(SPECIES)} template → {out.relative_to(ROOT)}, pratinjau → docs/sprites.png")


if __name__ == "__main__":
    sys.exit(main())
