<script setup>
// Kerangka admin: sengaja berbeda dari sisi pengguna (rel samping gelap, tanpa lantai pet)
// supaya selalu jelas sedang berada di ruang admin.
import { useRouter } from 'vue-router'
import { adminApi } from '../api.js'
import { adminSession } from '../store.js'

const router = useRouter()
const nav = [
  { to: '/admin', label: 'Ringkasan', exact: true },
  { to: '/admin/pengguna', label: 'Pengguna' },
  { to: '/admin/pet', label: 'Pet' },
  { to: '/admin/koneksi', label: 'Koneksi AI' },
  { to: '/admin/generate', label: 'Riwayat generate' },
  { to: '/admin/pengaturan', label: 'Pengaturan' },
  { to: '/admin/akun', label: 'Akun admin', super: true },
  { to: '/admin/audit', label: 'Jejak audit' },
]
async function out() {
  try { await adminApi.post('/auth/logout') } catch { /* sesi sudah habis */ }
  adminSession.admin = null
  router.push('/admin/login')
}
</script>

<template>
  <div class="admin">
    <aside class="rail">
      <div class="who">
        <span class="pixel brand">Temu</span>
        <span class="badge">Admin</span>
      </div>
      <nav aria-label="Menu admin">
        <template v-for="n in nav" :key="n.to">
          <RouterLink v-if="!n.super || adminSession.admin?.super" :to="n.to" :class="{ exact: n.exact }">{{ n.label }}</RouterLink>
        </template>
      </nav>
      <div class="foot small">
        <span>{{ adminSession.admin?.email }}</span>
        <button class="link" @click="out">Keluar</button>
      </div>
    </aside>
    <main class="content">
      <RouterView />
    </main>
  </div>
</template>

<style scoped>
.admin { display: grid; grid-template-columns: 220px minmax(0, 1fr); min-height: 100vh; background: #f4f6ff; }
.rail { background: var(--tinta); color: #d9d4ee; padding: 20px 0; display: flex; flex-direction: column; gap: 20px; position: sticky; top: 0; height: 100vh; }
.who { padding: 0 20px; display: flex; align-items: center; gap: 10px; }
.brand { font-size: 22px; color: #fff; }
.badge { background: var(--lemon); color: var(--tinta); font-size: 12px; font-weight: 600; padding: 1px 8px; }
nav { display: grid; }
nav a { padding: 9px 20px; text-decoration: none; color: inherit; border-left: 4px solid transparent; }
nav a:hover { color: #fff; }
nav a.router-link-active:not(.exact), nav a.router-link-exact-active { background: #3a3056; color: #fff; border-left-color: var(--lemon); font-weight: 500; }
.foot { margin-top: auto; padding: 0 20px; display: grid; gap: 6px; overflow-wrap: anywhere; }
.foot .link { color: #fff; justify-self: start; }
.content { padding: 32px 36px 64px; max-width: 1180px; width: 100%; }
@media (max-width: 800px) {
  .admin { grid-template-columns: 1fr; }
  .rail { position: static; height: auto; padding: 14px 0; gap: 10px; }
  nav { display: flex; overflow-x: auto; }
  nav a { white-space: nowrap; border-left: 0; border-bottom: 4px solid transparent; padding: 8px 14px; }
  nav a.router-link-active:not(.exact), nav a.router-link-exact-active { border-bottom-color: var(--lemon); }
  .foot { margin-top: 0; display: flex; justify-content: space-between; }
  .content { padding: 24px 16px 48px; }
}
</style>
