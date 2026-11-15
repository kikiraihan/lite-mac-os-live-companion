#!/usr/bin/env python3
"""Lagu latar teaser Temu: chiptune orisinal 32 detik, 120 BPM, C mayor (dibuat dari nol, bebas lisensi).

Pakai: python3 video/src/music.py <keluaran.wav>   (butuh numpy)

Satu birama = 2 detik, jadi pergantian adegan video jatuh dekat awal birama. Efek suara kecil
(lompat, klik, hati, gelembung) ditaruh di detik yang sama dengan kejadian di teaser.html.
"""
import sys
import wave

import numpy as np

SR = 44100
BEAT = 0.5           # 120 BPM
BAR = 4 * BEAT
LENGTH = 32.0
N = int(SR * LENGTH)
L = np.zeros(N)
R = np.zeros(N)


def hz(name):
    """'C5' → frekuensi. Hanya natural dan # (cukup untuk lagu ini)."""
    steps = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}
    n = steps[name[0]] + (1 if '#' in name else 0)
    octave = int(name[-1])
    return 440.0 * 2 ** ((n + 12 * (octave + 1) - 69) / 12)


def env(n, a=0.005, d=0.08, s=0.6, r=0.06):
    """ADSR sederhana (detik) untuk n sampel."""
    t = np.arange(n) / SR
    dur = n / SR
    e = np.where(t < a, t / a, s + (1 - s) * np.exp(-(t - a) / max(d, 1e-4)))
    rel = np.clip((dur - t) / r, 0, 1)
    return e * rel


def square(f, n, duty=0.5):
    ph = (np.arange(n) * f / SR) % 1.0
    return np.where(ph < duty, 1.0, -1.0)


def triangle(f, n):
    ph = (np.arange(n) * f / SR) % 1.0
    return 4 * np.abs(ph - 0.5) - 1


def soften(x, k=0.25):
    """Low-pass satu kutub supaya kotak 8-bit tidak terlalu tajam."""
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += k * (v - acc)
        y[i] = acc
    return y


def add(sig, start, gain=1.0, pan=0.0):
    i = int(start * SR)
    if i >= N:
        return
    sig = sig[: N - i]
    L[i:i + len(sig)] += sig * gain * (1 - max(pan, 0))
    R[i:i + len(sig)] += sig * gain * (1 + min(pan, 0))


CHORDS = {
    'C': ['C', 'E', 'G'], 'Am': ['A', 'C', 'E'], 'F': ['F', 'A', 'C'], 'G': ['G', 'B', 'D'],
}

# Melodi per birama: (nada, panjang dalam per-delapan). 'R' = diam. Satu birama = 8 per-delapan.
P1 = [
    [('E5', 2), ('G5', 2), ('A5', 1), ('G5', 1), ('E5', 2)],
    [('C5', 2), ('E5', 2), ('D5', 1), ('C5', 1), ('A4', 2)],
    [('C5', 2), ('F5', 2), ('E5', 1), ('F5', 1), ('A5', 2)],
    [('G5', 3), ('D5', 1), ('B4', 2), ('R', 2)],
]
P2 = [
    [('E5', 1), ('G5', 1), ('C6', 2), ('B5', 1), ('A5', 1), ('G5', 2)],
    [('A5', 2), ('E5', 2), ('G5', 2), ('E5', 2)],
    [('F5', 2), ('A5', 1), ('G5', 1), ('F5', 2), ('E5', 1), ('D5', 1)],
    [('D5', 2), ('E5', 1), ('D5', 1), ('B4', 2), ('G4', 2)],
]
END = [('C6', 8)]

# Susunan lagu: (akor, melodi, drum, keras-lembut)
#   0–4 d   pembuka: arpeggio saja      4–22 d  lagu penuh
#   22–26 d tenang (adegan privasi)     26–32 d penutup, berakhir di C
SONG = [
    ('C', None, False, .7), ('G', None, False, .8),
    ('C', P1[0], True, 1), ('Am', P1[1], True, 1), ('F', P1[2], True, 1), ('G', P1[3], True, 1),
    ('C', P2[0], True, 1), ('Am', P2[1], True, 1), ('F', P2[2], True, 1), ('G', P2[3], True, 1),
    ('C', P1[0], True, 1), ('Am', P1[1], False, .7), ('F', None, False, .6),
    ('C', P2[0], True, 1), ('G', P2[3], True, 1), ('C', END, False, 1),
]

for b, (chord, mel, drums, vol) in enumerate(SONG):
    t0 = b * BAR
    tones = CHORDS[chord]
    last = b == len(SONG) - 1

    # bass segitiga: akar di ketukan 1 dan 3 (birama terakhir: satu nada panjang)
    root = hz(tones[0] + '2') if tones[0] in 'AB' else hz(tones[0] + '3')
    for k in ([0] if last else [0, 2]):
        n = int(SR * (BAR if last else 2 * BEAT) * .95)
        add(triangle(root, n) * env(n, d=.3, s=.5, r=.1 if not last else 1.2), t0 + k * BEAT, .32 * vol)

    # arpeggio akor (kotak 25%, pelan, sedikit ke kiri)
    if last:
        for i, nm in enumerate(tones + ['C']):
            n = int(SR * (BAR - i * .06))
            o = '5' if i == 3 else '4'
            add(soften(square(hz(nm + o), n, .25)) * env(n, d=.6, s=.35, r=1.3), t0 + i * .06, .07, -.3)
    else:
        pattern = [0, 1, 2, 1, 0, 1, 2, 1]
        for i, p in enumerate(pattern):
            nm = tones[p]
            o = '5' if (nm in 'C' and p > 0) else '4'
            n = int(SR * BEAT / 2 * .9)
            add(soften(square(hz(nm + o), n, .25)) * env(n, d=.06, s=.25, r=.03), t0 + i * BEAT / 2, .075 * vol, -.3)

    # melodi (kotak 50%, sedikit ke kanan, vibrato tipis di nada panjang)
    if mel:
        pos = 0
        for nm, ln in mel:
            if nm != 'R':
                dur = ln * BEAT / 2
                n = int(SR * dur * (1 if last else .92))
                f = hz(nm)
                t = np.arange(n) / SR
                vib = 1 + .004 * np.sin(2 * np.pi * 5.5 * t) * np.clip(t / .25, 0, 1)
                ph = np.cumsum(f * vib / SR) % 1.0
                sig = soften(np.where(ph < .5, 1.0, -1.0), .2)
                e = env(n, d=.12, s=.55, r=.05 if not last else 1.4)
                add(sig * e, t0 + pos * BEAT / 2, .13 * vol, .25)
                # gema pelan setengah ketuk kemudian, supaya terasa hangat
                add(sig * e, t0 + pos * BEAT / 2 + .375, .035 * vol, -.4)
            pos += ln

    # drum: kick 1 & 3, snare 2 & 4, hi-hat per-delapan
    if drums:
        rng = np.random.default_rng(b)
        for k in range(4):
            if k % 2 == 0:
                n = int(SR * .18)
                t = np.arange(n) / SR
                f = 50 + 110 * np.exp(-t * 30)
                kick = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 18)
                add(kick, t0 + k * BEAT, .42)
            else:
                n = int(SR * .12)
                sn = soften(rng.uniform(-1, 1, n), .5) * np.exp(-np.arange(n) / SR * 32)
                add(sn, t0 + k * BEAT, .12)
        for k in range(8):
            n = int(SR * .03)
            hh = rng.uniform(-1, 1, n) * np.exp(-np.arange(n) / SR * 140)
            hh = hh - soften(hh, .3)   # high-pass kasar
            add(hh, t0 + k * BEAT / 2, .05 if k % 2 else .035, .2 if k % 2 else -.2)


# ---- Efek suara, disamakan dengan linimasa teaser ----
def blip(f0, f1, dur, gain, at, duty=.5, pan=0.0):
    n = int(SR * dur)
    t = np.arange(n) / SR
    f = f0 * (f1 / f0) ** (t / dur)
    ph = np.cumsum(f / SR) % 1.0
    sig = soften(np.where(ph < duty, 1.0, -1.0), .3) * env(n, a=.002, d=dur / 2, s=.4, r=dur / 3)
    add(sig, at, gain, pan)


def sparkle(at, gain=.05):
    for i, nm in enumerate(['C6', 'E6', 'G6', 'C7']):
        blip(hz(nm), hz(nm), .09, gain * (1 - i * .15), at + i * .07, .25, .3)


def click(at):
    n = int(SR * .025)
    add(np.sin(2 * np.pi * 1800 * np.arange(n) / SR) * np.exp(-np.arange(n) / SR * 200), at, .12)


blip(300, 900, .22, .07, 2.6)          # Mochi melompat
blip(300, 900, .22, .05, 3.2)
click(7.9)                              # kursor mengelus
sparkle(8.2)                            # hati naik
for i in range(16):                     # 16 pose muncul
    blip(hz('G5') * 2 ** (i / 24), hz('G5') * 2 ** (i / 24), .04, .025, 13.3 + i * .07, .25)
click(18.45)                            # tombol Izinkan
blip(500, 1100, .09, .06, 20.1, .25)    # gelembung sapaan
sparkle(20.5)
blip(250, 750, .3, .06, 26.7)           # judul penutup muncul

# ---- Mix akhir ----
fade_in = np.clip(np.arange(N) / (SR * .05), 0, 1)
fade_out = np.clip((LENGTH - np.arange(N) / SR) / 1.0, 0, 1)
mix = np.stack([L, R], axis=1) * (fade_in * fade_out)[:, None]
mix = np.tanh(mix * 1.1) / np.tanh(1.1)          # pembatas lembut
mix *= 0.85 / max(1e-9, np.abs(mix).max())       # puncak sekitar −1,4 dBFS

out = sys.argv[1] if len(sys.argv) > 1 else 'temu-teaser.wav'
with wave.open(out, 'wb') as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((mix * 32767).astype('<i2').tobytes())
print('lagu →', out)
