<script setup>
// Koneksi ke provider AI (kenari.id, OpenRouter, atau endpoint kompatibel OpenAI).
// API key hanya dikirim saat disimpan; server tidak pernah mengembalikannya.
import { onMounted, reactive, ref } from 'vue'
import Modal from '../../components/Modal.vue'
import { adminApi } from '../../api.js'
import { fail, toast } from '../../store.js'
import { when } from '../../lib/format.js'

const rows = ref([]), presets = ref([]), mock = ref(false), loading = ref(true)
const editing = ref(null) // null | { id?, …form }
const form = reactive({ name: '', kind: 'kenari', base_url: '', api_key: '', image_model: '', style: 'images', enabled: true, priority: 100 })
const models = ref([]), modelsBusy = ref(false), saving = ref(false), testing = ref('')
const removing = ref(null)

async function load() {
  try {
    const d = await adminApi.get('/connections')
    rows.value = d.data; presets.value = d.presets; mock.value = d.ai_mock
  } catch (e) { fail(e) }
  loading.value = false
}
onMounted(load)

const preset = (kind) => presets.value.find((p) => p.kind === kind) || {}
function applyPreset() {
  const p = preset(form.kind)
  form.base_url = p.base_url || ''
  form.style = p.style || 'chat'
  form.image_model = p.image_model || ''
  if (!form.name || presets.value.some((x) => x.title === form.name)) form.name = p.kind === 'custom' ? '' : p.title
}
function open(row) {
  models.value = []
  if (row) {
    Object.assign(form, { name: row.name, kind: row.kind, base_url: row.base_url, api_key: '', image_model: row.image_model, style: row.style, enabled: row.enabled, priority: row.priority })
    editing.value = { id: row.id, masked: row.api_key_masked }
  } else {
    Object.assign(form, { name: '', kind: 'kenari', api_key: '', enabled: true, priority: 100 })
    applyPreset()
    editing.value = {}
  }
}
async function save() {
  saving.value = true
  try {
    if (editing.value.id) await adminApi.patch('/connections/' + editing.value.id, form)
    else await adminApi.post('/connections', form)
    toast('Koneksi disimpan')
    editing.value = null
    await load()
  } catch (e) { fail(e) }
  saving.value = false
}
async function test(row) {
  testing.value = row.id
  try {
    const r = await adminApi.post(`/connections/${row.id}/test`)
    toast(r.message, r.ok ? 'ok' : 'bad')
    await load()
  } catch (e) { fail(e) }
  testing.value = ''
}
async function loadModels() {
  modelsBusy.value = true
  try {
    models.value = (await adminApi.get(`/connections/${editing.value.id}/models`)).data
    if (!models.value.length) toast('Provider tidak mengembalikan daftar model', 'bad')
  } catch (e) { fail(e) }
  modelsBusy.value = false
}
async function toggle(row) {
  try {
    await adminApi.patch('/connections/' + row.id, { ...row, api_key: '', enabled: !row.enabled })
    await load()
  } catch (e) { fail(e) }
}
async function remove() {
  try {
    await adminApi.del('/connections/' + removing.value.id)
    toast('Koneksi dihapus')
    removing.value = null
    await load()
  } catch (e) { fail(e) }
}
</script>

<template>
  <div class="stack" style="--gap: 24px">
    <div class="row spread">
      <div>
        <h1>Koneksi AI</h1>
        <p class="muted measure">Dipakai untuk menggambar pet dari foto. Koneksi aktif dicoba berurutan dari prioritas terkecil;
          kalau satu gagal, berikutnya yang mencoba.</p>
      </div>
      <button class="btn sun" @click="open(null)">Tambah koneksi</button>
    </div>
    <p v-if="mock" class="notice">AI_MOCK menyala di server: generate tidak memakai koneksi di bawah ini.</p>

    <p v-if="loading" class="muted">Memuat…</p>
    <div v-else-if="!rows.length" class="empty">
      <h3>Belum ada koneksi</h3>
      <p class="muted">Tanpa koneksi, pengguna tetap bisa membuat pet dari foto lewat cara manual (salin prompt ke ChatGPT).</p>
      <button class="btn sun" style="margin-top: 14px" @click="open(null)">Tambah koneksi pertama</button>
    </div>
    <article v-for="c in rows" :key="c.id" class="px conn" :class="{ off: !c.enabled }">
      <div class="grow">
        <h3>{{ c.name }} <span class="tag" :class="c.enabled ? 'ok' : ''">{{ c.enabled ? 'Aktif' : 'Mati' }}</span></h3>
        <dl class="small">
          <div><dt>Model</dt><dd><code>{{ c.image_model }}</code></dd></div>
          <div><dt>Alamat</dt><dd>{{ c.base_url }} <span class="muted">({{ c.style === 'chat' ? 'chat completions' : 'images/edits' }})</span></dd></div>
          <div><dt>API key</dt><dd><code>{{ c.api_key_masked }}</code></dd></div>
          <div><dt>Prioritas</dt><dd>{{ c.priority }}</dd></div>
          <div><dt>Pemakaian</dt><dd>{{ c.done }} berhasil, {{ c.failed }} gagal</dd></div>
          <div v-if="c.last_test_at"><dt>Tes terakhir</dt>
            <dd><span class="tag" :class="c.last_test_ok ? 'ok' : 'bad'">{{ c.last_test_ok ? 'Tersambung' : 'Gagal' }}</span> {{ when(c.last_test_at) }}<br />{{ c.last_test_msg }}</dd>
          </div>
        </dl>
      </div>
      <div class="acts">
        <button class="btn small" :disabled="testing === c.id" @click="test(c)">{{ testing === c.id ? 'Mengetes…' : 'Tes koneksi' }}</button>
        <button class="btn small" @click="open(c)">Ubah</button>
        <button class="link small" @click="toggle(c)">{{ c.enabled ? 'Matikan' : 'Nyalakan' }}</button>
        <button class="link small danger" @click="removing = c">Hapus</button>
      </div>
    </article>

    <Modal v-if="editing" :title="editing.id ? 'Ubah koneksi' : 'Tambah koneksi'" wide @close="editing = null">
      <form class="stack" @submit.prevent="save">
        <div class="two">
          <label class="field"><span>Provider</span>
            <select class="input" v-model="form.kind" @change="applyPreset">
              <option v-for="p in presets" :key="p.kind" :value="p.kind">{{ p.title }}</option>
            </select>
            <small>{{ preset(form.kind).hint }}</small>
          </label>
          <label class="field"><span>Nama koneksi</span>
            <input class="input" v-model="form.name" maxlength="60" required />
          </label>
        </div>
        <label class="field"><span>Base URL</span>
          <input class="input mono" v-model="form.base_url" placeholder="https://…/v1" required />
        </label>
        <label class="field"><span>API key</span>
          <input class="input mono" type="password" v-model="form.api_key" autocomplete="off" :required="!editing.id"
            :placeholder="editing.id ? `Tersimpan (${editing.masked}). Kosongkan kalau tidak diganti.` : 'sk-…'" />
          <small>Disimpan terenkripsi dan tidak pernah ditampilkan lagi.</small>
        </label>
        <div class="two">
          <label class="field"><span>Model gambar</span>
            <input class="input mono" v-model="form.image_model" list="model-list" required />
            <datalist id="model-list"><option v-for="m in models" :key="m.id" :value="m.id">{{ m.image ? 'gambar' : '' }}</option></datalist>
            <small v-if="editing.id"><button type="button" class="link" :disabled="modelsBusy" @click="loadModels">{{ modelsBusy ? 'Mengambil…' : 'Ambil daftar model dari provider' }}</button>
              <template v-if="models.length"> · {{ models.filter((m) => m.image).length }} model gambar ditemukan</template></small>
            <small v-else>Harus bisa menerima gambar masukan dan menghasilkan gambar.</small>
          </label>
          <label class="field"><span>Cara memanggil</span>
            <select class="input" v-model="form.style">
              <option value="chat">Chat completions + modalities (OpenRouter)</option>
              <option value="images">Images edits (gaya OpenAI, kenari.id)</option>
            </select>
          </label>
        </div>
        <div class="two">
          <label class="field"><span>Prioritas</span>
            <input class="input" type="number" min="0" max="9999" v-model.number="form.priority" />
            <small>Angka terkecil dicoba lebih dulu.</small>
          </label>
          <label class="switch" style="align-self: center"><input type="checkbox" v-model="form.enabled" /><i></i> Aktif</label>
        </div>
        <div class="row">
          <button class="btn sun" :disabled="saving">{{ saving ? 'Menyimpan…' : 'Simpan koneksi' }}</button>
          <button type="button" class="btn" @click="editing = null">Batal</button>
        </div>
      </form>
    </Modal>
    <Modal v-if="removing" :title="`Hapus koneksi ${removing.name}?`" @close="removing = null">
      <p>API key-nya ikut dihapus. Riwayat generate tetap ada.</p>
      <div class="row" style="margin-top: 18px">
        <button class="btn danger" @click="remove">Hapus koneksi</button>
        <button class="btn" @click="removing = null">Batal</button>
      </div>
    </Modal>
  </div>
</template>

<style scoped>
.conn { display: flex; gap: 20px; padding: 18px; align-items: flex-start; flex-wrap: wrap; }
.conn.off { background: #f1f1f6; }
.conn h3 { margin-bottom: 10px; }
dl { margin: 0; display: grid; gap: 4px; }
dl div { display: grid; grid-template-columns: 110px minmax(0, 1fr); gap: 8px; }
dt { color: var(--tinta-2); }
dd { margin: 0; overflow-wrap: anywhere; }
.acts { display: grid; gap: 6px; justify-items: start; }
.two { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }
@media (max-width: 640px) { .two { grid-template-columns: 1fr; } }
</style>
