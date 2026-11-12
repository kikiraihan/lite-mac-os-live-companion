// Otak kecil pet untuk web: jalan-jalan di lantai, rebahan, tidur, joget, bereaksi saat dielus
// atau diangkat. Versi ringkas dari perilaku aplikasi Mac (Sources/LiteCompanion/Pet.swift).

import { CELL, drawFrame } from './sheet.js'
import { LINES, pick } from './lines.js'

const rnd = (a, b) => a + Math.random() * (b - a)

// partikel pixel kecil: 1 = terisi
const SHAPES = {
  heart: { color: '#ff5a7a', rows: ['0110110', '1111111', '1111111', '0111110', '0011100', '0001000'] },
  z: { color: '#5a64b4', rows: ['1111', '0010', '0100', '1111'] },
  note: { color: '#2a2140', rows: ['00110', '00101', '00100', '00100', '11100', '11100'] },
  star: { color: '#ffd23c', rows: ['0001000', '0011100', '1111111', '0111110', '0110110', '0100010'] },
}

export class Actor {
  constructor(sheet, name, scale) {
    this.sheet = sheet
    this.name = name
    this.scale = scale
    this.x = 0; this.y = 0; this.vy = 0
    this.facing = Math.random() < 0.5 ? 1 : -1
    this.act = 'idle'; this.t = 0; this.dur = rnd(0.5, 2)
    this.blink = rnd(2, 5)
    this.bubble = null
    this.held = false
  }

  get w() { return CELL * this.scale }

  say(text, seconds = 2.6) { this.bubble = { text, until: seconds } }

  start(act, dur) { this.act = act; this.t = 0; this.dur = dur }

  next(world) {
    const r = Math.random()
    if (world.calm) return this.start(r < 0.6 ? 'idle' : 'sit', rnd(3, 7))
    if (r < 0.30) this.start('idle', rnd(1.5, 4))
    else if (r < 0.66) { this.facing = Math.random() < 0.5 ? 1 : -1; this.start('walk', rnd(1.5, 5)) }
    else if (r < 0.76) this.start('sit', rnd(3, 7))
    else if (r < 0.83) this.start('sleep', rnd(6, 12))
    else if (r < 0.90) { this.vy = 330; this.start('jump', 1) }
    else if (r < 0.95) this.start('dance', rnd(2, 4))
    else { this.start('wave', 1.6); if (Math.random() < 0.6) this.say(pick(LINES.hello)) }
    if (this.act === 'idle' && Math.random() < 0.12) this.say(pick(LINES.idle))
  }

  // dielus
  pet(world) {
    if (this.act === 'sleep') { this.say(pick(LINES.wake)); this.start('surprise', 1.2); return }
    this.start('love', 1.4)
    this.say(pick(LINES.pet), 1.6)
    for (let i = 0; i < 3; i++) world.spawn('heart', this.x + rnd(-10, 10), this.y + this.w * 0.7, rnd(-20, 20), rnd(40, 70))
  }

  grab() { this.held = true; this.start('held', 999); this.vy = 0 }

  drop() {
    this.held = false
    this.start('fall', 999)
  }

  update(dt, world) {
    this.t += dt
    if (this.bubble && (this.bubble.until -= dt) <= 0) this.bubble = null
    const half = this.w / 2
    switch (this.act) {
      case 'walk':
        this.x += this.facing * 13 * this.scale * dt
        if (this.x < half) { this.x = half; this.facing = 1 }
        if (this.x > world.width - half) { this.x = world.width - half; this.facing = -1 }
        break
      case 'jump':
      case 'fall':
        this.vy -= 1500 * dt
        this.y += this.vy * dt
        if (this.y <= 0) {
          const hard = this.act === 'fall' && this.vy < -520
          this.y = 0; this.vy = 0
          if (hard) { this.start('dizzy', 1.8); this.say(pick(LINES.drop), 1.6); world.spawn('star', this.x, this.w * 0.8, 30, 60) }
          else this.start('idle', rnd(0.6, 1.4))
        }
        return
      case 'sleep':
        if (Math.floor(this.t / 1.3) !== Math.floor((this.t - dt) / 1.3)) world.spawn('z', this.x + this.facing * half * 0.5, this.w * 0.6, 8 * this.facing, 26)
        break
      case 'dance':
        if (Math.floor(this.t / 0.5) !== Math.floor((this.t - dt) / 0.5)) {
          this.facing *= -1
          world.spawn('note', this.x + rnd(-14, 14), this.w * 0.8, rnd(-14, 14), 46)
        }
        break
      case 'held':
        return
    }
    if (this.t >= this.dur) this.next(world)
  }

  frame() {
    const t = this.t
    switch (this.act) {
      case 'walk': return Math.floor(t / 0.17) % 2 ? 'walk2' : 'walk1'
      case 'sit': return 'sit'
      case 'sleep': return 'sleep'
      case 'jump': return 'jump'
      case 'dance': return Math.floor(t / 0.24) % 2 ? 'dance2' : 'dance1'
      case 'wave': return Math.floor(t / 0.3) % 2 ? 'happy' : 'wave'
      case 'love': return 'love'
      case 'surprise': case 'held': case 'fall': return 'surprise'
      case 'dizzy': return 'dizzy'
      default: return (t % this.blink) > this.blink - 0.15 ? 'blink' : 'idle'
    }
  }

  hit(px, py) {
    const half = this.w / 2
    return px > this.x - half * 0.7 && px < this.x + half * 0.7 && py > this.y && py < this.y + this.w * 0.75
  }
}

export class World {
  constructor() {
    this.width = 300
    this.actors = []
    this.particles = []
    this.calm = false
  }

  spawn(kind, x, y, vx, vy) {
    if (this.particles.length < 40) this.particles.push({ kind, x, y, vx, vy, life: 1.4 })
  }

  update(dt) {
    for (const a of this.actors) a.update(dt, this)
    for (const p of this.particles) { p.x += p.vx * dt; p.y += p.vy * dt; p.life -= dt }
    this.particles = this.particles.filter((p) => p.life > 0)
  }

  // (0,0) dunia = kiri bawah lantai; `ground` = jarak lantai dari tepi bawah canvas
  draw(ctx, height, ground) {
    for (const a of [...this.actors].sort((p, q) => (p.held ? 1 : 0) - (q.held ? 1 : 0))) {
      drawFrame(ctx, a.sheet, a.frame(), Math.round(a.x - a.w / 2), Math.round(height - ground - a.y - a.w), a.scale, a.facing < 0)
    }
    for (const p of this.particles) {
      const s = SHAPES[p.kind]
      ctx.globalAlpha = Math.min(1, p.life * 1.6)
      ctx.fillStyle = s.color
      s.rows.forEach((row, j) => [...row].forEach((c, i) => {
        if (c === '1') ctx.fillRect(Math.round(p.x) + i * 2, Math.round(height - ground - p.y) + j * 2, 2, 2)
      }))
    }
    ctx.globalAlpha = 1
    for (const a of this.actors) if (a.bubble) drawBubble(ctx, a.bubble.text, a.x, height - ground - a.y - a.w * 0.82, this.width)
  }
}

function drawBubble(ctx, text, cx, bottom, maxX) {
  ctx.font = '500 13px Rubik, system-ui, sans-serif'
  const w = Math.ceil(ctx.measureText(text).width) + 16, h = 24
  const x = Math.max(4, Math.min(maxX - w - 4, Math.round(cx - w / 2))), y = Math.round(bottom - h - 8)
  ctx.fillStyle = '#2a2140'
  ctx.fillRect(x, y - 2, w, h + 4); ctx.fillRect(x - 2, y, w + 4, h)
  ctx.fillRect(Math.round(cx) - 3, y + h + 2, 6, 3); ctx.fillRect(Math.round(cx) - 1, y + h + 5, 3, 3)
  ctx.fillStyle = '#fff'
  ctx.fillRect(x, y, w, h)
  ctx.fillRect(Math.round(cx) - 1, y + h, 3, 3)
  ctx.fillStyle = '#2a2140'
  ctx.textBaseline = 'middle'
  ctx.fillText(text, x + 8, y + h / 2 + 1)
}
