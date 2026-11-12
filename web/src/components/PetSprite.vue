<script setup>
// Satu pet yang dianimasikan di tempat (kartu, daftar, pratinjau).
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { CELL, drawFrame, frameAt, loadSheet } from '../lib/sheet.js'

const props = defineProps({
  src: String,                               // URL sheet, atau
  sheet: Object,                             // canvas sheet langsung (editor)
  anim: { type: String, default: 'idle' },   // nama animasi di ANIMS
  frame: String,                             // pose tetap (mengalahkan anim)
  scale: { type: Number, default: 3 },
  flip: Boolean,
  rev: { type: Number, default: 0 },         // naikkan untuk menggambar ulang sheet yang diedit
})

const canvas = ref(null)
let img = null, timer = 0, lastFrame = ''
const t0 = performance.now() - Math.random() * 2000 // supaya deretan pet tidak berkedip serempak
const still = window.matchMedia('(prefers-reduced-motion: reduce)')

function paint(force) {
  const c = canvas.value
  if (!c || !img) return
  const f = props.frame || (still.matches ? 'idle' : frameAt(props.anim, performance.now() - t0))
  if (!force && f === lastFrame) return
  lastFrame = f
  const dpr = Math.ceil(window.devicePixelRatio || 1)
  const px = CELL * props.scale * dpr
  if (c.width !== px) c.width = c.height = px
  const ctx = c.getContext('2d')
  ctx.clearRect(0, 0, px, px)
  drawFrame(ctx, img, f, 0, 0, props.scale * dpr, props.flip)
}

async function load() {
  img = props.sheet || null
  if (!img && props.src) {
    try { img = await loadSheet(props.src) } catch { img = null }
  }
  paint(true)
}

watch(() => [props.src, props.sheet], load)
watch(() => [props.rev, props.frame, props.anim, props.scale, props.flip], () => paint(true))
onMounted(() => {
  load()
  timer = setInterval(() => paint(false), 80)
})
onBeforeUnmount(() => clearInterval(timer))
</script>

<template>
  <canvas ref="canvas" class="sprite" :style="{ width: 32 * scale + 'px', height: 32 * scale + 'px' }" aria-hidden="true"></canvas>
</template>
