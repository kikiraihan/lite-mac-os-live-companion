<script setup>
import { onMounted, ref } from 'vue'
import { adminApi } from '../../api.js'
import { fail, toast } from '../../store.js'
import { day, when } from '../../lib/format.js'

const rows = ref([]), q = ref(''), loading = ref(true)
async function load() {
  try { rows.value = (await adminApi.get('/users?q=' + encodeURIComponent(q.value))).data } catch (e) { fail(e) }
  loading.value = false
}
onMounted(load)
async function toggle(u) {
  try {
    await adminApi.patch('/users/' + u.id, { disabled: !u.disabled })
    u.disabled = !u.disabled
    toast(u.disabled ? `${u.name} dinonaktifkan dan dikeluarkan dari semua perangkat` : `${u.name} diaktifkan lagi`)
  } catch (e) { fail(e) }
}
</script>

<template>
  <div class="stack" style="--gap: 20px">
    <div class="row spread">
      <h1>Pengguna</h1>
      <form class="row" @submit.prevent="load">
        <input class="input" v-model="q" placeholder="Cari nama, @pengguna, email" aria-label="Cari pengguna" style="width: 260px" />
        <button class="btn">Cari</button>
      </form>
    </div>
    <p v-if="loading" class="muted">Memuat…</p>
    <div v-else-if="!rows.length" class="empty"><h3>Tidak ada pengguna yang cocok</h3><p class="muted">Coba kata kunci lain, atau kosongkan pencarian.</p></div>
    <div v-else class="scroll-x">
      <table class="data">
        <thead><tr><th>Pengguna</th><th>Email</th><th>Pet</th><th>Teman</th><th>Mac</th><th>Daftar</th><th>Terakhir aktif</th><th></th></tr></thead>
        <tbody>
          <tr v-for="u in rows" :key="u.id">
            <td><b>{{ u.name }}</b> <span class="muted">@{{ u.handle }}</span> <span v-if="u.disabled" class="tag bad">Nonaktif</span></td>
            <td>{{ u.email }}</td><td>{{ u.pets }}</td><td>{{ u.friends }}</td><td>{{ u.macs }}</td>
            <td>{{ day(u.created_at) }}</td><td>{{ when(u.last_seen_at) }}</td>
            <td><button class="link" :class="{ danger: !u.disabled }" @click="toggle(u)">{{ u.disabled ? 'Aktifkan' : 'Nonaktifkan' }}</button></td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
