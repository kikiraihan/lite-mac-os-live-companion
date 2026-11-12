<script setup>
import { onMounted, ref } from 'vue'
import { api } from '../api.js'
import { fail, toast } from '../store.js'

const devices = ref([]), download = ref('#'), loading = ref(true)
const when = (t) => (t ? new Date(t).toLocaleString('id-ID', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : 'belum pernah')

async function load() {
  try {
    devices.value = (await api.get('/devices')).data
    download.value = (await api.get('/config')).mac_download_url
  } catch (e) { fail(e) }
  loading.value = false
}
onMounted(load)

async function revoke(d) {
  try {
    await api.del('/devices/' + d.id)
    toast(`${d.name} diputuskan`)
    load()
  } catch (e) { fail(e) }
}
</script>

<template>
  <div class="stack" style="--gap: 36px">
    <div>
      <h1>Mac</h1>
      <p class="muted">Aplikasi kecil di menu bar yang menampilkan pet-mu di layar.</p>
    </div>

    <section class="px card">
      <ol class="steps">
        <li><b>Unduh dan pasang Temani untuk Mac.</b>
          <div><a class="btn primary" :href="download" target="_blank" rel="noopener">Unduh untuk Mac</a></div>
          <p class="small muted">Buka berkas .zip, pindahkan Temani ke folder Applications, lalu buka. macOS 13 ke atas.</p>
        </li>
        <li><b>Klik ikon pet di menu bar, lalu "Hubungkan akun".</b>
          <p class="small muted">Browser terbuka di halaman ini dengan sebuah kode. Kamu tidak perlu mengetik password di aplikasi.</p>
        </li>
        <li><b>Setujui kodenya.</b> Pet yang kamu nyalakan "Tampil di Mac" langsung muncul.
          <p class="small"><RouterLink to="/hubungkan">Punya kode? Masukkan di sini</RouterLink></p>
        </li>
      </ol>
    </section>

    <section>
      <h2>Mac yang terhubung</h2>
      <p v-if="loading" class="muted">Memuat…</p>
      <div v-else-if="!devices.length" class="empty">
        <h3>Belum ada Mac yang terhubung</h3>
        <p class="muted">Pasang aplikasinya, lalu pilih "Hubungkan akun" dari ikon pet di menu bar.</p>
      </div>
      <div v-for="d in devices" :key="d.id" class="row line">
        <div class="grow">
          <b>{{ d.name }}</b>
          <p class="small muted">Terhubung {{ when(d.created_at) }} · terakhir aktif {{ when(d.last_seen_at) }}</p>
        </div>
        <button class="btn small danger" @click="revoke(d)">Putuskan</button>
      </div>
    </section>

    <section class="measure">
      <h2>Yang bisa dan tidak bisa dilakukan aplikasinya</h2>
      <p>Aplikasi Mac hanya mengambil gambar pet yang tampil di Mac dan sapaan dari teman. Ia tidak membaca layar,
        ketikan, atau berkas, dan tidak meminta izin Aksesibilitas. Memutuskan sebuah Mac di sini langsung mencabut aksesnya.</p>
    </section>
  </div>
</template>

<style scoped>
.steps { margin: 0; padding-left: 24px; display: grid; gap: 18px; }
.steps li::marker { font-family: var(--pixel); font-weight: 700; font-size: 20px; }
.steps li > div { margin: 8px 0 6px; }
h2 { margin-bottom: 12px; }
.line { padding: 12px 0; border-bottom: 1px solid var(--langit-tua); }
</style>
