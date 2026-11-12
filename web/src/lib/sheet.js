// Format sprite sheet pet: PNG 128×128, grid 4×4, tiap pose 32×32, menghadap kanan.
// Urutan pose harus sama dengan server (internal/sprite) dan aplikasi Mac (Skin.swift).

export const CELL = 32
export const SIZE = 128
export const FRAMES = ['idle', 'blink', 'walk1', 'walk2', 'happy', 'love', 'surprise', 'sad',
  'eat', 'dizzy', 'sit', 'sleep', 'jump', 'wave', 'dance1', 'dance2']
export const FRAME_LABELS = {
  idle: 'Diam', blink: 'Kedip', walk1: 'Jalan 1', walk2: 'Jalan 2', happy: 'Senang', love: 'Sayang',
  surprise: 'Kaget', sad: 'Sedih', eat: 'Makan', dizzy: 'Pusing', sit: 'Rebahan', sleep: 'Tidur',
  jump: 'Lompat', wave: 'Melambai', dance1: 'Joget 1', dance2: 'Joget 2',
}

// Urutan [pose, milidetik] untuk tiap animasi pratinjau
export const ANIMS = {
  idle: [['idle', 2200], ['blink', 150], ['idle', 900], ['blink', 150]],
  walk: [['walk1', 170], ['walk2', 170]],
  happy: [['happy', 380], ['jump', 300]],
  sleep: [['sleep', 1200], ['sit', 120]],
  dance: [['dance1', 240], ['dance2', 240]],
  wave: [['wave', 300], ['happy', 300]],
  tour: FRAMES.map((f) => [f, 650]),
}

const cache = new Map()

export function blankSheet() {
  const c = document.createElement('canvas')
  c.width = c.height = SIZE
  return c
}

/** Muat sheet dari URL (dengan cookie sesi) → canvas 128×128. Hasilnya di-cache per URL. */
export function loadSheet(url) {
  if (!cache.has(url)) {
    cache.set(url, fetch(url, { credentials: 'same-origin' })
      .then((r) => { if (!r.ok) throw new Error('sheet ' + r.status); return r.blob() })
      .then((b) => createImageBitmap(b))
      .then((bmp) => {
        const c = blankSheet()
        c.getContext('2d').drawImage(bmp, 0, 0, SIZE, SIZE)
        return c
      })
      .catch((e) => { cache.delete(url); throw e }))
  }
  return cache.get(url)
}

/** Gambar satu pose. (x, y) = pojok kiri atas; scale = piksel layar per piksel art. */
export function drawFrame(ctx, sheet, frame, x, y, scale, flip = false) {
  const i = typeof frame === 'number' ? frame : Math.max(0, FRAMES.indexOf(frame))
  const sx = (i % 4) * CELL, sy = Math.floor(i / 4) * CELL
  ctx.imageSmoothingEnabled = false
  if (flip) {
    ctx.save()
    ctx.translate(x + CELL * scale, y)
    ctx.scale(-1, 1)
    ctx.drawImage(sheet, sx, sy, CELL, CELL, 0, 0, CELL * scale, CELL * scale)
    ctx.restore()
  } else {
    ctx.drawImage(sheet, sx, sy, CELL, CELL, x, y, CELL * scale, CELL * scale)
  }
}

export function sheetToDataURL(canvas) {
  return canvas.toDataURL('image/png')
}

/** Pose pada waktu t (ms) untuk sebuah animasi */
export function frameAt(anim, t) {
  const seq = ANIMS[anim] || ANIMS.idle
  const total = seq.reduce((n, s) => n + s[1], 0)
  let r = t % total
  for (const [f, d] of seq) {
    if (r < d) return f
    r -= d
  }
  return seq[0][0]
}
