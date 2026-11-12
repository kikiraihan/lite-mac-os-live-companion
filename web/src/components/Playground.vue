<script setup>
// Lantai tempat pet berjalan sungguhan. Klik = elus, seret = angkat lalu jatuhkan.
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { loadSheet } from '../lib/sheet.js'
import { Actor, World } from '../lib/brain.js'

const props = defineProps({
  pets: { type: Array, default: () => [] }, // [{ id, name, sheet_url }]
  height: { type: Number, default: 104 },
  ground: { type: Number, default: 18 },    // jarak lantai dari tepi bawah
  scale: { type: Number, default: 2 },
})

const canvas = ref(null)
const world = new World()
let raf = 0, last = 0, width = 300, drag = null, down = null
const calm = window.matchMedia('(prefers-reduced-motion: reduce)')

function resize() {
  const c = canvas.value
  if (!c) return
  width = c.clientWidth
  const dpr = window.devicePixelRatio || 1
  c.width = Math.round(width * dpr)
  c.height = Math.round(props.height * dpr)
  world.width = width
  for (const a of world.actors) a.x = Math.min(a.x, width - a.w / 2)
}

async function sync() {
  const keep = new Map(world.actors.map((a) => [a.key, a]))
  const out = []
  for (const p of props.pets) {
    const key = p.id + '|' + p.sheet_url
    let a = keep.get(key)
    if (!a) {
      try {
        a = new Actor(await loadSheet(p.sheet_url), p.name, props.scale)
      } catch { continue }
      a.key = key
      a.x = 40 + Math.random() * Math.max(40, width - 80)
    }
    out.push(a)
  }
  world.actors = out
}

function tick(now) {
  raf = requestAnimationFrame(tick)
  const dt = Math.min(0.05, (now - last) / 1000 || 0)
  last = now
  world.calm = calm.matches
  world.update(dt)
  const c = canvas.value
  if (!c) return
  const ctx = c.getContext('2d')
  const dpr = window.devicePixelRatio || 1
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
  ctx.clearRect(0, 0, width, props.height)
  world.draw(ctx, props.height, props.ground)
}

function point(e) {
  const r = canvas.value.getBoundingClientRect()
  return { x: e.clientX - r.left, y: props.height - props.ground - (e.clientY - r.top) }
}
// Canvas tidak pernah menangkap pointer (pointer-events: none) supaya isi halaman di bawah lantai
// tetap bisa diklik; pointer dipantau di window dan hanya "dimakan" kalau mengenai seekor pet.
let swallow = false
function onDown(e) {
  if (!canvas.value) return
  const p = point(e)
  const a = [...world.actors].reverse().find((q) => q.hit(p.x, p.y))
  if (!a) return
  down = { a, x: p.x, y: p.y, moved: false }
  swallow = true
  e.preventDefault()
  e.stopPropagation()
}
function onMove(e) {
  if (!canvas.value) return
  const p = point(e)
  if (down) {
    if (!down.moved && Math.hypot(p.x - down.x, p.y - down.y) > 6) { down.moved = true; drag = down.a; drag.grab() }
    if (drag) {
      drag.x = Math.max(drag.w / 2, Math.min(width - drag.w / 2, p.x))
      drag.y = Math.max(0, Math.min(props.height - props.ground - drag.w * 0.5, p.y - drag.w * 0.4))
    }
  }
  const over = drag ? 'grabbing' : world.actors.some((q) => q.hit(p.x, p.y)) ? 'grab' : ''
  if (over !== cursor) { cursor = over; document.documentElement.style.cursor = over }
}
function onUp() {
  if (drag) drag.drop()
  else if (down) down.a.pet(world)
  drag = down = null
  setTimeout(() => { swallow = false }, 60)
}
function onClick(e) { // klik yang dimulai di atas pet tidak diteruskan ke tautan di bawahnya
  if (swallow) { swallow = false; e.preventDefault(); e.stopPropagation() }
}
let cursor = ''

watch(() => props.pets, sync, { deep: true })
onMounted(() => {
  resize()
  sync()
  window.addEventListener('resize', resize)
  window.addEventListener('pointerdown', onDown, true)
  window.addEventListener('pointermove', onMove)
  window.addEventListener('pointerup', onUp)
  window.addEventListener('pointercancel', onUp)
  window.addEventListener('click', onClick, true)
  raf = requestAnimationFrame(tick)
})
onBeforeUnmount(() => {
  cancelAnimationFrame(raf)
  window.removeEventListener('resize', resize)
  window.removeEventListener('pointerdown', onDown, true)
  window.removeEventListener('pointermove', onMove)
  window.removeEventListener('pointerup', onUp)
  window.removeEventListener('pointercancel', onUp)
  window.removeEventListener('click', onClick, true)
  document.documentElement.style.cursor = ''
})
</script>

<template>
  <canvas ref="canvas" class="playground" :style="{ height: height + 'px' }" role="img"
    aria-label="Pet-mu sedang berjalan-jalan. Klik untuk mengelus, seret untuk mengangkat."></canvas>
</template>

<style scoped>
.playground { width: 100%; pointer-events: none; }
</style>
