<script setup>
// Kerangka halaman pengguna: bilah menu ala Mac di atas, lantai dengan pet yang hidup di bawah.
import { useRoute, useRouter } from 'vue-router'
import Playground from './Playground.vue'
import { floor, logout, session } from '../store.js'

const router = useRouter(), route = useRoute()
const nav = [
  { to: '/pet', label: 'Pet-ku' },
  { to: '/studio', label: 'Bikin pet' },
  { to: '/teman', label: 'Teman' },
  { to: '/mac', label: 'Mac' },
]
async function out() {
  await logout()
  router.push('/')
}
</script>

<template>
  <div class="shell">
    <header class="bar">
      <RouterLink to="/pet" class="brand pixel">Temu</RouterLink>
      <nav aria-label="Menu utama">
        <RouterLink v-for="n in nav" :key="n.to" :to="n.to" :class="{ here: route.path.startsWith(n.to) }">{{ n.label }}</RouterLink>
      </nav>
      <div class="me">
        <RouterLink to="/akun">@{{ session.user?.handle }}</RouterLink>
        <button class="link" @click="out">Keluar</button>
      </div>
    </header>
    <main class="page">
      <RouterView />
    </main>
    <div class="floor" v-if="floor.pets.length">
      <Playground :pets="floor.pets" />
    </div>
    <div class="ground" aria-hidden="true"></div>
  </div>
</template>

<style scoped>
.shell { min-height: 100vh; padding-bottom: calc(var(--lantai) + 24px); }
.bar {
  position: sticky; top: 0; z-index: 30; display: flex; align-items: center; gap: 20px;
  min-height: 40px; padding: 0 20px; background: var(--tinta); color: #fff; font-size: 15px;
}
.brand { font-size: 20px; text-decoration: none; color: var(--jeruk); }
nav { display: flex; gap: 4px; flex: 1; overflow-x: auto; }
nav a { padding: 9px 12px; text-decoration: none; white-space: nowrap; color: #d9d4ee; }
nav a:hover { color: #fff; }
nav a.here { background: var(--langit); color: var(--tinta); font-weight: 600; }
.me { display: flex; gap: 14px; align-items: center; white-space: nowrap; }
.me a { color: #d9d4ee; text-decoration: none; }
.me a:hover, .me .link:hover { color: #fff; }
.me .link { color: #d9d4ee; text-decoration: none; }
.page { max-width: 1040px; margin: 0 auto; padding: 36px 20px 24px; }
.floor { position: fixed; left: 0; right: 0; bottom: 0; z-index: 20; height: var(--lantai); pointer-events: none; }
.ground {
  position: fixed; left: 0; right: 0; bottom: 0; z-index: 10; height: 18px; background: var(--langit-tua);
  border-top: 3px solid var(--tinta);
}
@media (max-width: 640px) {
  .bar { flex-wrap: wrap; gap: 0 12px; padding: 0 12px; }
  nav { order: 3; flex-basis: 100%; }
  .me { margin-left: auto; min-height: 40px; }
  .page { padding-top: 24px; }
}
</style>
