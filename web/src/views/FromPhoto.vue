<script setup>
// Pet dari foto: otomatis lewat AI yang diatur admin, atau manual lewat ChatGPT milik pengguna.
import { onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import PetSprite from '../components/PetSprite.vue'
import { api } from '../api.js'
import { fail, refreshFloor, toast } from '../store.js'

const router = useRouter()
const info = ref(null)
const mode = ref('ai')
const photo = ref(null), photoURL = ref(''), note = ref('')
const job = reactive({ id: '', status: '', sheet_url: '', error: '' })
const name = ref(''), saving = ref(false), busy = ref(false), copied = ref(false)
let timer = 0

onMounted(async () => {
  try {
    info.value = await api.get('/generate/info')
    if (!info.value.ai_available) mode.value = 'manual'
  } catch (e) { fail(e) }
})
onBeforeUnmount(() => { clearTimeout(timer); if (photoURL.value) URL.revokeObjectURL(photoURL.value) })

function pickPhoto(e) {
  const f = e.target.files[0]
  if (!f) return
  if (photoURL.value) URL.revokeObjectURL(photoURL.value)
  photo.value = f
  photoURL.value = URL.createObjectURL(f)
}
function reset() {
  clearTimeout(timer)
  Object.assign(job, { id: '', status: '', sheet_url: '', error: '' })
}

async function generate() {
  if (!photo.value) return toast('Pilih fotonya dulu', 'bad')
  busy.value = true
  reset()
  try {
    const form = new FormData()
    form.append('photo', photo.value)
    form.append('note', note.value)
    const r = await api.upload('/generate', form)
    job.id = r.id; job.status = r.status
    info.value.used_today++
    poll()
  } catch (e) { fail(e) }
  busy.value = false
}
async function poll() {
  try {
    const r = await api.get('/generate/' + job.id)
    Object.assign(job, { status: r.status, sheet_url: r.sheet_url || '', error: r.error || '' })
    if (r.status === 'queued' || r.status === 'running') timer = setTimeout(poll, 2500)
  } catch (e) {
    job.status = 'failed'; job.error = e.message
  }
}
async function uploadManual(e) {
  const f = e.target.files[0]
  if (!f) return
  busy.value = true
  reset()
  try {
    const form = new FormData()
    form.append('image', f)
    const r = await api.upload('/generate/manual', form)
    Object.assign(job, { id: r.id, status: 'done', sheet_url: r.sheet_url })
  } catch (err) { fail(err) }
  e.target.value = ''
  busy.value = false
}
async function copyPrompt() {
  try {
    await navigator.clipboard.writeText(info.value.prompt)
    copied.value = true
    setTimeout(() => { copied.value = false }, 2000)
  } catch { toast('Tidak bisa menyalin otomatis. Blok teksnya lalu salin manual.', 'bad') }
}
async function save() {
  if (!name.value.trim()) return toast('Beri nama pet-mu dulu', 'bad')
  saving.value = true
  try {
    await api.post('/pets', { name: name.value, generation_id: job.id })
    toast(`${name.value} sudah jadi pet-mu`)
    refreshFloor()
    router.push('/pet')
  } catch (e) { fail(e) }
  saving.value = false
}
</script>

<template>
  <div class="stack" style="--gap: 28px">
    <div>
      <h1>Pet dari foto</h1>
      <p class="muted measure">Hasilnya pet pixel dengan 16 pose. Fotomu hanya dipakai untuk menggambar, lalu dihapus dari server.</p>
    </div>

    <div class="row tabs" role="tablist">
      <button role="tab" :aria-selected="mode === 'ai'" :class="{ on: mode === 'ai' }" @click="mode = 'ai'">Otomatis</button>
      <button role="tab" :aria-selected="mode === 'manual'" :class="{ on: mode === 'manual' }" @click="mode = 'manual'">Lewat ChatGPT sendiri</button>
    </div>

    <div class="cols">
      <section v-if="mode === 'ai'" class="stack">
        <p v-if="info && !info.ai_available" class="notice">
          Generate otomatis belum dinyalakan admin. Pakai tab "Lewat ChatGPT sendiri", hasilnya sama.
        </p>
        <template v-else>
          <label class="px drop" :class="{ has: photoURL }">
            <input type="file" accept="image/png,image/jpeg" @change="pickPhoto" />
            <img v-if="photoURL" :src="photoURL" alt="Foto yang dipilih" />
            <span v-else><b>Pilih foto</b><br /><small class="muted">Wajah terlihat jelas, satu orang, PNG atau JPEG, maksimal 8 MB.</small></span>
          </label>
          <label class="field"><span>Permintaan tambahan</span>
            <input class="input" v-model="note" maxlength="200" placeholder="Pakai hoodie hijau dan bawa kopi" />
            <small>Boleh dikosongkan.</small>
          </label>
          <div class="row">
            <button class="btn primary" :disabled="busy || job.status === 'queued' || job.status === 'running'" @click="generate">Gambar pet-ku</button>
            <span v-if="info" class="small muted">Sisa jatah hari ini: {{ Math.max(0, info.daily_limit - info.used_today) }} dari {{ info.daily_limit }}</span>
          </div>
        </template>
      </section>

      <section v-else class="stack">
        <ol class="steps">
          <li>
            <b>Unduh contoh tata letak.</b> Gambar ini memberi tahu AI susunan 16 posenya.
            <div><a class="btn small" href="/api/generate/guide.png?download=1">Unduh contoh tata letak</a></div>
          </li>
          <li>
            <b>Salin prompt.</b>
            <textarea v-if="info" class="input mono" readonly rows="6" :value="info.prompt" aria-label="Prompt"></textarea>
            <div><button class="btn small" @click="copyPrompt">{{ copied ? 'Tersalin' : 'Salin prompt' }}</button></div>
          </li>
          <li>
            <b>Buka ChatGPT</b> (atau AI gambar lain). Lampirkan <i>fotomu</i> dan <i>contoh tata letak</i>, tempel prompt, lalu kirim.
            Simpan gambar hasilnya.
          </li>
          <li>
            <b>Unggah hasilnya ke sini.</b> Kami potong, buang latarnya, dan rapikan jadi pixel art.
            <div><label class="btn small sun"><input type="file" accept="image/png,image/jpeg" hidden @change="uploadManual" />{{ busy ? 'Merapikan…' : 'Unggah gambar hasil' }}</label></div>
          </li>
        </ol>
      </section>

      <aside class="px result" aria-live="polite">
        <template v-if="job.status === 'done'">
          <div class="row show">
            <PetSprite :src="job.sheet_url" anim="tour" :scale="4" />
            <PetSprite :src="job.sheet_url" anim="walk" :scale="2" />
            <PetSprite :src="job.sheet_url" anim="dance" :scale="2" />
          </div>
          <label class="field"><span>Namanya siapa?</span>
            <input class="input" v-model="name" maxlength="24" placeholder="Nama pet" />
          </label>
          <button class="btn primary block" :disabled="saving" @click="save">Simpan jadi pet-ku</button>
          <div class="row small">
            <RouterLink :to="{ path: '/studio/gambar', query: { gen: job.id } }">Rapikan di editor dulu</RouterLink>
            <button class="link" @click="reset">Buang, coba lagi</button>
          </div>
        </template>
        <template v-else-if="job.status === 'queued' || job.status === 'running'">
          <PetSprite src="/api/templates/oren.png" anim="dance" :scale="4" />
          <h3>Sedang digambar…</h3>
          <p class="muted small">Biasanya 30 detik sampai 2 menit. Halaman ini boleh ditinggal terbuka.</p>
        </template>
        <template v-else-if="job.status === 'failed'">
          <PetSprite src="/api/templates/oren.png" frame="sad" :scale="4" />
          <h3>Belum berhasil</h3>
          <p class="small">{{ job.error }}</p>
        </template>
        <template v-else>
          <PetSprite src="/api/templates/oren.png" frame="sit" :scale="4" />
          <p class="muted small">Hasilnya muncul di sini, lengkap dengan animasinya.</p>
        </template>
      </aside>
    </div>
  </div>
</template>

<style scoped>
.tabs { gap: 0; border-bottom: 3px solid var(--tinta); }
.tabs button { background: none; border: 0; padding: 8px 16px; cursor: pointer; font-weight: 500; }
.tabs button.on { background: var(--tinta); color: #fff; }
.cols { display: grid; grid-template-columns: minmax(0, 1fr) 300px; gap: 32px; align-items: start; }
.drop { display: grid; place-items: center; min-height: 180px; padding: 16px; cursor: pointer; text-align: center; position: relative; }
.drop input { position: absolute; inset: 0; opacity: 0; cursor: pointer; }
.drop img { max-height: 240px; max-width: 100%; }
.drop:has(input:focus-visible) { outline: 3px solid #4d7dff; outline-offset: 4px; }
.steps { margin: 0; padding-left: 22px; display: grid; gap: 18px; }
.steps li::marker { font-family: var(--pixel); font-weight: 700; font-size: 20px; }
.steps li > div { margin-top: 8px; }
.steps textarea { margin-top: 8px; }
.result { padding: 20px; display: grid; gap: 12px; justify-items: start; }
.result .field, .result .btn.block { width: 100%; }
.show { align-items: flex-end; gap: 4px; }
@media (max-width: 860px) { .cols { grid-template-columns: 1fr; } }
</style>
