<script setup>
import { onMounted, ref } from 'vue'
import { adminApi } from '../../api.js'
import { fail } from '../../store.js'
import { when } from '../../lib/format.js'

const rows = ref([]), loading = ref(true)
const ACTION = {
  'admin.login': 'Masuk', 'admin.password_changed': 'Ganti password', 'user.update': 'Ubah pengguna', 'pet.update': 'Ubah pet',
  'connection.create': 'Tambah koneksi AI', 'connection.update': 'Ubah koneksi AI', 'connection.delete': 'Hapus koneksi AI',
  'settings.update': 'Ubah pengaturan', 'account.create': 'Tambah admin', 'account.update': 'Ubah admin',
}
const meta = (m) => Object.entries(m || {}).filter(([, v]) => v !== null).map(([k, v]) => `${k}: ${v}`).join(', ')
onMounted(async () => {
  try { rows.value = (await adminApi.get('/audit')).data } catch (e) { fail(e) }
  loading.value = false
})
</script>

<template>
  <div class="stack" style="--gap: 20px">
    <div>
      <h1>Jejak audit</h1>
      <p class="muted">Setiap tindakan admin dicatat. 200 catatan terakhir.</p>
    </div>
    <p v-if="loading" class="muted">Memuat…</p>
    <div v-else class="scroll-x">
      <table class="data">
        <thead><tr><th>Waktu</th><th>Admin</th><th>Tindakan</th><th>Rincian</th><th>IP</th></tr></thead>
        <tbody>
          <tr v-for="a in rows" :key="a.id">
            <td>{{ when(a.created_at) }}</td><td>{{ a.admin }}</td><td>{{ ACTION[a.action] || a.action }}</td>
            <td class="small">{{ meta(a.meta) }}</td><td class="small muted">{{ a.ip }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
