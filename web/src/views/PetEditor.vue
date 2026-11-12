<script setup>
// Editor piksel: 16 pose × 32×32. Dipakai untuk pet baru (/studio/gambar, opsional ?dari=template
// atau ?gen=hasil-generate) dan untuk mengubah pet yang sudah ada (/pet/:id).
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import PetSprite from '../components/PetSprite.vue'
import { api } from '../api.js'
import { fail, refreshFloor, toast } from '../store.js'
import { CELL, FRAMES, FRAME_LABELS, SIZE, blankSheet, loadSheet, sheetToDataURL } from '../lib/sheet.js'

const route = useRoute(), router = useRouter()
const petId = route.params.id || null
const genId = route.query.gen || null
const fromTemplate = route.query.dari || null

const sheet = blankSheet()               // sumber kebenaran: canvas 128×128
const sctx = sheet.getContext('2d', { willReadFrequently: true })
const board = ref(null)                  // canvas editor (diperbesar)
const rev = ref(0)                       // naik tiap sheet berubah → pratinjau menggambar ulang
const frame = ref(0)
const tool = ref('pencil')
const color = ref('#2a2140')
const palette = ref([])
const onion = ref(true)
const zoom = ref(14)
const preview = ref('idle')
const form = reactive({ name: '', bio: '' })
const state = reactive({ loading: true, saving: false, dirty: false, isNew: !petId })
const undo = []
const copyFrom = ref('')
const swapTo = ref('#ff5a7a')

const TOOLS = [
  { id: 'pencil', label: 'Pensil', key: 'B' },
  { id: 'eraser', label: 'Penghapus', key: 'E' },
  { id: 'fill', label: 'Ember', key: 'G' },
  { id: 'pick', label: 'Pipet', key: 'I' },
]
const PREVIEWS = [['idle', 'Diam'], ['walk', 'Jalan'], ['dance', 'Joget'], ['sleep', 'Tidur'], ['tour', 'Semua pose']]

const origin = computed(() => ({ x: (frame.value % 4) * CELL, y: Math.floor(frame.value / 4) * CELL }))

// ---------- warna ----------
const hex = (r, g, b) => '#' + [r, g, b].map((v) => v.toString(16).padStart(2, '0')).join('')
const rgbOf = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16))

function refreshPalette() {
  const d = sctx.getImageData(0, 0, SIZE, SIZE).data
  const count = new Map()
  for (let i = 0; i < d.length; i += 4) {
    if (d[i + 3] < 128) continue
    const h = hex(d[i], d[i + 1], d[i + 2])
    count.set(h, (count.get(h) || 0) + 1)
  }
  palette.value = [...count.entries()].sort((a, b) => b[1] - a[1]).slice(0, 28).map((e) => e[0])
}

// ---------- menggambar papan ----------
function paintBoard() {
  const c = board.value
  if (!c) return
  const z = zoom.value, px = CELL * z
  if (c.width !== px) c.width = c.height = px
  const ctx = c.getContext('2d')
  ctx.imageSmoothingEnabled = false
  for (let y = 0; y < CELL; y++) {       // kotak-kotak = transparan
    for (let x = 0; x < CELL; x++) {
      ctx.fillStyle = (x + y) % 2 ? '#eef0ff' : '#ffffff'
      ctx.fillRect(x * z, y * z, z, z)
    }
  }
  if (onion.value && frame.value !== 0) { // bayangan pose "Diam" sebagai patokan ukuran & posisi
    ctx.globalAlpha = 0.22
    ctx.drawImage(sheet, 0, 0, CELL, CELL, 0, 0, px, px)
    ctx.globalAlpha = 1
  }
  ctx.drawImage(sheet, origin.value.x, origin.value.y, CELL, CELL, 0, 0, px, px)
  ctx.fillStyle = 'rgba(42,33,64,0.10)'
  for (let i = 1; i < CELL; i++) {
    ctx.fillRect(i * z, 0, 1, px)
    ctx.fillRect(0, i * z, px, 1)
  }
  ctx.fillStyle = 'rgba(255,90,122,0.55)' // garis lantai: kaki pet menapak di baris terbawah
  ctx.fillRect(0, px - 2, px, 2)
}

function changed() {
  rev.value++
  state.dirty = true
  paintBoard()
}

function pushUndo() {
  undo.push(sctx.getImageData(0, 0, SIZE, SIZE))
  if (undo.length > 60) undo.shift()
}
function doUndo() {
  const img = undo.pop()
  if (!img) return
  sctx.putImageData(img, 0, 0)
  changed()
  refreshPalette()
}

// ---------- alat ----------
function setPixel(x, y, erase) {
  if (x < 0 || y < 0 || x >= CELL || y >= CELL) return
  const ox = origin.value.x + x, oy = origin.value.y + y
  sctx.clearRect(ox, oy, 1, 1)
  if (!erase) { sctx.fillStyle = color.value; sctx.fillRect(ox, oy, 1, 1) }
}
function line(x0, y0, x1, y1, erase) {  // Bresenham, supaya goresan cepat tidak putus-putus
  const dx = Math.abs(x1 - x0), dy = -Math.abs(y1 - y0), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
  let err = dx + dy
  for (;;) {
    setPixel(x0, y0, erase)
    if (x0 === x1 && y0 === y1) break
    const e2 = 2 * err
    if (e2 >= dy) { err += dy; x0 += sx }
    if (e2 <= dx) { err += dx; y0 += sy }
  }
}
function pixelAt(x, y) {
  const d = sctx.getImageData(origin.value.x + x, origin.value.y + y, 1, 1).data
  return d[3] < 128 ? null : hex(d[0], d[1], d[2])
}
function fill(x, y) {
  const img = sctx.getImageData(origin.value.x, origin.value.y, CELL, CELL)
  const d = img.data
  const at = (px, py) => { const i = (py * CELL + px) * 4; return d[i + 3] < 128 ? -1 : (d[i] << 16) | (d[i + 1] << 8) | d[i + 2] }
  const target = at(x, y)
  const [r, g, b] = rgbOf(color.value)
  if (target === ((r << 16) | (g << 8) | b)) return
  const stack = [[x, y]]
  while (stack.length) {
    const [cx, cy] = stack.pop()
    if (cx < 0 || cy < 0 || cx >= CELL || cy >= CELL || at(cx, cy) !== target) continue
    const i = (cy * CELL + cx) * 4
    d[i] = r; d[i + 1] = g; d[i + 2] = b; d[i + 3] = 255
    stack.push([cx + 1, cy], [cx - 1, cy], [cx, cy + 1], [cx, cy - 1])
  }
  sctx.putImageData(img, origin.value.x, origin.value.y)
}

let stroke = null
function cell(e) {
  const r = board.value.getBoundingClientRect()
  return { x: Math.floor(((e.clientX - r.left) / r.width) * CELL), y: Math.floor(((e.clientY - r.top) / r.height) * CELL) }
}
function onDown(e) {
  const p = cell(e)
  const t = e.button === 2 ? 'eraser' : tool.value
  if (t === 'pick') {
    const c = pixelAt(p.x, p.y)
    if (c) { color.value = c; tool.value = 'pencil' }
    return
  }
  pushUndo()
  if (t === 'fill') {
    fill(p.x, p.y)
    changed(); refreshPalette()
    return
  }
  stroke = { ...p, erase: t === 'eraser' }
  setPixel(p.x, p.y, stroke.erase)
  board.value.setPointerCapture(e.pointerId)
  changed()
}
function onMove(e) {
  if (!stroke) return
  const p = cell(e)
  if (p.x === stroke.x && p.y === stroke.y) return
  line(stroke.x, stroke.y, p.x, p.y, stroke.erase)
  stroke.x = p.x; stroke.y = p.y
  changed()
}
function onUp() {
  if (stroke) refreshPalette()
  stroke = null
}

// ---------- operasi pose ----------
function withFrame(fn) {
  pushUndo()
  const img = sctx.getImageData(origin.value.x, origin.value.y, CELL, CELL)
  const out = sctx.createImageData(CELL, CELL)
  fn(img.data, out.data)
  sctx.putImageData(out, origin.value.x, origin.value.y)
  changed()
}
function shift(dx, dy) {
  withFrame((src, dst) => {
    for (let y = 0; y < CELL; y++) for (let x = 0; x < CELL; x++) {
      const tx = x + dx, ty = y + dy
      if (tx < 0 || ty < 0 || tx >= CELL || ty >= CELL) continue
      const i = (y * CELL + x) * 4, j = (ty * CELL + tx) * 4
      for (let k = 0; k < 4; k++) dst[j + k] = src[i + k]
    }
  })
}
function mirror() {
  withFrame((src, dst) => {
    for (let y = 0; y < CELL; y++) for (let x = 0; x < CELL; x++) {
      const i = (y * CELL + x) * 4, j = (y * CELL + (CELL - 1 - x)) * 4
      for (let k = 0; k < 4; k++) dst[j + k] = src[i + k]
    }
  })
}
function clearFrame() { withFrame(() => {}); refreshPalette() }
function copyPose() {
  const from = FRAMES.indexOf(copyFrom.value)
  if (from < 0 || from === frame.value) return
  pushUndo()
  const img = sctx.getImageData((from % 4) * CELL, Math.floor(from / 4) * CELL, CELL, CELL)
  sctx.putImageData(img, origin.value.x, origin.value.y)
  copyFrom.value = ''
  changed()
}
// ganti satu warna di SEMUA pose — cara tercepat mewarnai ulang pet bawaan
function swapColor() {
  const [r, g, b] = rgbOf(color.value), [nr, ng, nb] = rgbOf(swapTo.value)
  pushUndo()
  const img = sctx.getImageData(0, 0, SIZE, SIZE), d = img.data
  let n = 0
  for (let i = 0; i < d.length; i += 4) {
    if (d[i + 3] >= 128 && d[i] === r && d[i + 1] === g && d[i + 2] === b) { d[i] = nr; d[i + 1] = ng; d[i + 2] = nb; n++ }
  }
  sctx.putImageData(img, 0, 0)
  changed(); refreshPalette()
  color.value = swapTo.value
  toast(n ? `${n} piksel diganti di semua pose` : 'Warna itu tidak dipakai di gambar ini', n ? 'ok' : 'bad')
}

// ---------- simpan ----------
async function save() {
  if (!form.name.trim()) return toast('Beri nama pet-mu dulu', 'bad')
  state.saving = true
  try {
    const data = sheetToDataURL(sheet)
    if (petId) {
      await api.patch('/pets/' + petId, { name: form.name, bio: form.bio, sheet: data })
      toast('Perubahan disimpan')
    } else {
      const body = { name: form.name, sheet: data }
      if (genId) body.generation_id = genId
      if (fromTemplate) body.template = fromTemplate
      await api.post('/pets', body)
      toast(`${form.name} sudah jadi pet-mu`)
    }
    state.dirty = false
    refreshFloor()
    router.push('/pet')
  } catch (e) { fail(e) }
  state.saving = false
}
function download() {
  const a = document.createElement('a')
  a.href = sheetToDataURL(sheet)
  a.download = (form.name || 'pet') + '-temu.png'
  a.click()
}

function onKey(e) {
  if (e.target.matches('input, textarea, select')) return
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'z') { e.preventDefault(); doUndo(); return }
  const t = TOOLS.find((x) => x.key.toLowerCase() === e.key.toLowerCase())
  if (t && !e.metaKey && !e.ctrlKey) tool.value = t.id
}
const warn = (e) => { if (state.dirty) e.preventDefault() }
function fitZoom() {
  zoom.value = Math.max(7, Math.min(16, Math.floor((Math.min(window.innerWidth - 48, 560)) / CELL)))
  paintBoard()
}

onMounted(async () => {
  window.addEventListener('keydown', onKey)
  window.addEventListener('beforeunload', warn)
  window.addEventListener('resize', fitZoom)
  try {
    let src = null
    if (petId) {
      const { pet } = await api.get('/pets/' + petId)
      if (!pet.mine) { router.replace('/pet'); return }
      form.name = pet.name; form.bio = pet.bio
      src = pet.sheet_url
    } else if (genId) {
      src = `/api/generate/${genId}/sheet.png`
    } else if (fromTemplate) {
      src = `/api/templates/${fromTemplate}.png`
    }
    if (src) sctx.drawImage(await loadSheet(src + (src.includes('?') ? '&' : '?') + 'edit=' + Date.now()), 0, 0)
  } catch (e) { fail(e) }
  state.loading = false
  refreshPalette()
  if (palette.value.length) color.value = palette.value[0]
  rev.value++
  fitZoom()
})
onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKey)
  window.removeEventListener('beforeunload', warn)
  window.removeEventListener('resize', fitZoom)
})
watch([frame, onion], paintBoard)
</script>

<template>
  <div class="editor">
    <div class="row spread top">
      <div>
        <h1>{{ state.isNew ? 'Gambar pet' : 'Ubah ' + (form.name || 'pet') }}</h1>
        <p class="muted">Pet menghadap kanan, kakinya menapak di garis merah. Pose "Diam" jadi patokan pose lain.</p>
      </div>
      <RouterLink to="/pet" class="small">Kembali tanpa menyimpan</RouterLink>
    </div>

    <div class="layout">
      <aside class="frames" aria-label="Pose">
        <button v-for="(f, i) in FRAMES" :key="f" :class="{ on: frame === i }" @click="frame = i" :aria-pressed="frame === i"
          :title="FRAME_LABELS[f]" :aria-label="'Pose ' + FRAME_LABELS[f]">
          <PetSprite :sheet="sheet" :frame="f" :scale="1.25" :rev="rev" />
        </button>
      </aside>

      <section class="work">
        <div class="row tools">
          <button v-for="t in TOOLS" :key="t.id" class="btn small" :class="{ sun: tool === t.id, pressed: tool === t.id }"
            :aria-pressed="tool === t.id" :title="`${t.label} (${t.key})`" @click="tool = t.id">{{ t.label }}</button>
          <span class="grow pose">Pose: <b>{{ FRAME_LABELS[FRAMES[frame]] }}</b></span>
          <button class="btn small" :disabled="!undo.length" @click="doUndo" title="Urungkan (⌘Z)">Urungkan</button>
        </div>

        <div class="px boardwrap" :style="{ width: CELL * zoom + 'px' }">
          <canvas ref="board" class="board" :class="tool" :style="{ width: CELL * zoom + 'px', height: CELL * zoom + 'px' }"
            @pointerdown.prevent="onDown" @pointermove="onMove" @pointerup="onUp" @pointercancel="onUp" @contextmenu.prevent
            :aria-label="`Kanvas pose ${FRAME_LABELS[FRAMES[frame]]}`"></canvas>
        </div>

        <div class="row swatches" aria-label="Warna">
          <label class="now" title="Pilih warna lain">
            <input type="color" v-model="color" />
            <i :style="{ background: color }"></i>
          </label>
          <button v-for="c in palette" :key="c" class="sw" :class="{ on: c === color }" :style="{ background: c }"
            :aria-label="'Warna ' + c" @click="color = c; if (tool !== 'fill') tool = 'pencil'"></button>
        </div>

        <div class="ops small">
          <div class="row">
            <span class="muted">Pose ini:</span>
            <button class="link" @click="shift(-1, 0)" aria-label="Geser kiri">←</button>
            <button class="link" @click="shift(0, -1)" aria-label="Geser atas">↑</button>
            <button class="link" @click="shift(0, 1)" aria-label="Geser bawah">↓</button>
            <button class="link" @click="shift(1, 0)" aria-label="Geser kanan">→</button>
            <button class="link" @click="mirror">Balik</button>
            <button class="link danger" @click="clearFrame">Kosongkan</button>
            <select v-model="copyFrom" @change="copyPose" aria-label="Salin dari pose lain">
              <option value="">Salin dari pose…</option>
              <option v-for="f in FRAMES" :key="f" :value="f" :disabled="FRAMES[frame] === f">{{ FRAME_LABELS[f] }}</option>
            </select>
          </div>
          <div class="row">
            <span class="muted">Semua pose:</span>
            <span>ganti warna terpilih jadi</span>
            <input type="color" v-model="swapTo" aria-label="Warna pengganti" />
            <button class="link" @click="swapColor">Ganti</button>
            <label class="row" style="gap: 6px; margin-left: auto"><input type="checkbox" v-model="onion" /> Bayangan pose Diam</label>
          </div>
        </div>
      </section>

      <aside class="side">
        <div class="px stagebox">
          <PetSprite :sheet="sheet" :anim="preview" :scale="4" :rev="rev" />
        </div>
        <div class="row small pv">
          <button v-for="[id, label] in PREVIEWS" :key="id" class="link" :class="{ cur: preview === id }" @click="preview = id">{{ label }}</button>
        </div>
        <label class="field"><span>Nama</span>
          <input class="input" v-model="form.name" maxlength="24" placeholder="Nama pet" />
        </label>
        <label v-if="!state.isNew" class="field"><span>Tentang dia</span>
          <input class="input" v-model="form.bio" maxlength="140" placeholder="Suka tidur siang" />
        </label>
        <button class="btn primary block" :disabled="state.saving || state.loading" @click="save">
          {{ state.saving ? 'Menyimpan…' : state.isNew ? 'Simpan jadi pet-ku' : 'Simpan perubahan' }}
        </button>
        <button class="link small" @click="download">Unduh sebagai PNG</button>
      </aside>
    </div>
  </div>
</template>

<style scoped>
.top { margin-bottom: 24px; align-items: flex-end; }
.layout { display: grid; grid-template-columns: 196px minmax(0, 1fr) 220px; gap: 28px; align-items: start; }
/* 4×4, sama dengan susunan pose di sprite sheet */
.frames { display: grid; grid-template-columns: repeat(4, 1fr); gap: 2px; }
.frames button { background: none; border: 3px solid transparent; padding: 1px; cursor: pointer; display: grid; justify-items: center; }
.frames button.on { border-color: var(--tinta); background: var(--kertas); }
.pose { text-align: right; padding-right: 8px; font-size: 14px; }
.tools { gap: 4px; margin-bottom: 10px; }
.boardwrap { line-height: 0; }
.board { touch-action: none; cursor: crosshair; image-rendering: pixelated; }
.board.pick { cursor: copy; }
.swatches { gap: 5px; margin-top: 14px; }
.now { position: relative; cursor: pointer; margin-right: 8px; }
.now input { position: absolute; inset: 0; opacity: 0; width: 100%; height: 100%; cursor: pointer; }
.now i { display: block; width: 36px; height: 36px; border: 3px solid var(--tinta); }
.sw { width: 24px; height: 24px; border: 2px solid var(--tinta); padding: 0; cursor: pointer; }
.sw.on { outline: 3px solid var(--stroberi); outline-offset: 1px; }
.ops { margin-top: 14px; display: grid; gap: 8px; }
.ops .row { gap: 12px; }
.ops input[type='color'] { width: 28px; height: 24px; padding: 0; border: 2px solid var(--tinta); background: none; }
.ops select { border: 2px solid var(--tinta); background: var(--kertas); padding: 2px 4px; }
.side { display: grid; gap: 14px; justify-items: start; }
.side .field, .side .btn.block { width: 100%; }
.stagebox { padding: 8px 20px 0; background: var(--langit); }
.pv { gap: 10px; }
.pv .cur { font-weight: 600; text-decoration: none; }
@media (max-width: 980px) {
  .layout { grid-template-columns: 1fr; }
  .frames { grid-template-columns: repeat(8, 44px); }
}
@media (max-width: 560px) { .frames { grid-template-columns: repeat(4, 44px); } }
</style>
