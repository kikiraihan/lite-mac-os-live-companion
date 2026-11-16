<script setup>
import { onMounted, reactive, ref } from 'vue'
import { adminApi } from '../../api.js'
import { fail, toast } from '../../store.js'

const form = reactive({ registration_open: true, daily_generations: 3, max_pets: 12, prompt: '', support_url: '', supporters_url: '' })
const defaultPrompt = ref(''), loading = ref(true), saving = ref(false)
const defaults = reactive({ support_url: '', supporters_url: '' }) // link dukungan bawaan dari server
onMounted(async () => {
  try {
    const d = await adminApi.get('/settings')
    Object.assign(form, d.settings)
    defaultPrompt.value = d.default_prompt
    defaults.support_url = d.default_support_url
    defaults.supporters_url = d.default_supporters_url
  } catch (e) { fail(e) }
  loading.value = false
})
async function save() {
  saving.value = true
  try {
    Object.assign(form, (await adminApi.put('/settings', form)).settings)
    toast('Pengaturan disimpan')
  } catch (e) { fail(e) }
  saving.value = false
}
</script>

<template>
  <form class="stack settings" style="--gap: 28px" @submit.prevent="save">
    <h1>Pengaturan</h1>
    <p v-if="loading" class="muted">Memuat…</p>
    <template v-else>
      <section class="stack">
        <h2>Pendaftaran</h2>
        <label class="switch"><input type="checkbox" v-model="form.registration_open" /><i></i> Siapa pun boleh mendaftar</label>
        <p class="small muted">Kalau dimatikan, orang baru hanya bisa mendaftar lewat tautan undangan dari pengguna yang sudah ada.</p>
      </section>
      <section class="stack">
        <h2>Batas</h2>
        <div class="two">
          <label class="field"><span>Generate AI per pengguna per hari</span>
            <input class="input" type="number" min="0" max="100" v-model.number="form.daily_generations" required />
            <small>0 mematikan generate otomatis; cara manual tetap tersedia.</small>
          </label>
          <label class="field"><span>Pet per pengguna</span>
            <input class="input" type="number" min="1" max="50" v-model.number="form.max_pets" required />
          </label>
        </div>
      </section>
      <section class="stack">
        <h2>Prompt generate</h2>
        <p class="small muted measure">Dikirim ke model gambar bersama foto pengguna dan contoh tata letak, dan ditampilkan ke pengguna untuk
          cara manual. Tulis <code v-pre>{{note}}</code> di tempat permintaan tambahan pengguna disisipkan. Kosong = prompt bawaan.</p>
        <textarea class="input mono" rows="14" v-model="form.prompt" :placeholder="defaultPrompt" aria-label="Prompt generate"></textarea>
        <div><button type="button" class="link small" @click="form.prompt = defaultPrompt">Isi dengan prompt bawaan untuk diubah</button></div>
      </section>
      <section class="stack">
        <h2>Dukungan</h2>
        <label class="field"><span>Link dukungan</span>
          <input class="input" type="url" v-model.trim="form.support_url" :placeholder="defaults.support_url" />
          <small>Tujuan tombol "Dukung lewat Sociabuzz" di landing, "Dukung Temu" di footer, dan "Buka Sociabuzz…" di aplikasi Mac.
            Kosong = link bawaan.</small>
        </label>
        <label class="field"><span>Link daftar pendukung</span>
          <input class="input" type="url" v-model.trim="form.supporters_url" placeholder="Kosong = tautan disembunyikan" />
          <small>Tautan kecil "Lihat para pendukung" di bawah tombol dukungan di landing. Kosongkan untuk menyembunyikannya.</small>
        </label>
        <div><button type="button" class="link small" @click="Object.assign(form, defaults)">Kembalikan ke link bawaan</button></div>
      </section>
      <div><button class="btn sun" :disabled="saving">{{ saving ? 'Menyimpan…' : 'Simpan pengaturan' }}</button></div>
    </template>
  </form>
</template>

<style scoped>
.settings { max-width: 760px; }
.two { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }
@media (max-width: 640px) { .two { grid-template-columns: 1fr; } }
</style>
