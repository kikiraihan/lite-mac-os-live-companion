<script setup>
import PetSprite from '../components/PetSprite.vue'
</script>

<template>
  <main class="lost">
    <PetSprite src="/api/templates/oren.png" frame="dizzy" :scale="4" />
    <h1>Halaman ini tidak ada</h1>
    <p class="muted">Mungkin tautannya salah ketik, atau halamannya sudah pindah.</p>
    <RouterLink class="btn" to="/">Kembali ke depan</RouterLink>
  </main>
</template>

<style scoped>
.lost { max-width: 480px; margin: 0 auto; padding: 80px 20px; display: grid; gap: 14px; justify-items: start; }
</style>
