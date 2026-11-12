<script setup>
import { onMounted, ref } from 'vue'
import { adminApi } from '../../api.js'
import { fail } from '../../store.js'
import { secs, when } from '../../lib/format.js'

const rows = ref([]), loading = ref(true), open = ref('')
const STATUS = { queued: ['Antre', ''], running: ['Berjalan', 'warn'], done: ['Selesai', 'ok'], failed: ['Gagal', 'bad'] }
onMounted(async () => {
  try { rows.value = (await adminApi.get('/generations')).data } catch (e) { fail(e) }
  loading.value = false
})
</script>

<template>
  <div class="stack" style="--gap: 20px">
    <div>
      <h1>Riwayat generate</h1>
      <p class="muted">200 permintaan terakhir. Foto pengguna tidak disimpan, jadi tidak ditampilkan di sini.</p>
    </div>
    <p v-if="loading" class="muted">Memuat…</p>
    <div v-else-if="!rows.length" class="empty"><h3>Belum ada yang membuat pet dari foto</h3></div>
    <div v-else class="scroll-x">
      <table class="data">
        <thead><tr><th>Waktu</th><th>Pengguna</th><th>Cara</th><th>Status</th><th>Koneksi</th><th>Model</th><th>Lama</th></tr></thead>
        <tbody>
          <template v-for="g in rows" :key="g.id">
            <tr>
              <td>{{ when(g.created_at) }}</td>
              <td>{{ g.user_name }} <span class="muted">@{{ g.user_handle }}</span></td>
              <td>{{ g.mode === 'ai' ? 'Otomatis' : 'Manual' }}</td>
              <td><span class="tag" :class="STATUS[g.status][1]">{{ STATUS[g.status][0] }}</span>
                <button v-if="g.error || g.note" class="link small" style="margin-left: 8px" @click="open = open === g.id ? '' : g.id">Rincian</button></td>
              <td>{{ g.provider || '–' }}</td><td><code>{{ g.model || '–' }}</code></td><td>{{ secs(g.duration_ms) }}</td>
            </tr>
            <tr v-if="open === g.id"><td colspan="7" class="detail">
              <p v-if="g.note"><b>Permintaan pengguna:</b> {{ g.note }}</p>
              <p v-if="g.error"><b>Galat:</b> {{ g.error }}</p>
            </td></tr>
          </template>
        </tbody>
      </table>
    </div>
  </div>
</template>

<style scoped>
.detail { background: #fff6cf; overflow-wrap: anywhere; }
</style>
