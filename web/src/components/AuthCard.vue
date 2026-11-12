<script setup>
// Bingkai halaman masuk / daftar / undangan: satu kolom sempit dengan seekor pet di atasnya.
import PetSprite from './PetSprite.vue'
defineProps({ title: String, pet: { type: String, default: '/api/templates/oren.png' }, anim: { type: String, default: 'idle' } })
</script>

<template>
  <div class="auth">
    <RouterLink to="/" class="brand pixel">Temu</RouterLink>
    <div class="stage">
      <PetSprite :src="pet" :anim="anim" :scale="3" />
    </div>
    <div class="px box">
      <h2>{{ title }}</h2>
      <slot />
    </div>
    <div class="below small"><slot name="below" /></div>
  </div>
</template>

<style scoped>
.auth { max-width: 420px; margin: 0 auto; padding: 32px 20px 64px; }
.brand { font-size: 24px; text-decoration: none; color: var(--tinta); }
.stage { margin-top: 28px; padding-left: 20px; }
.box { padding: 24px; }
.box h2 { margin-bottom: 18px; }
.below { margin-top: 18px; padding: 0 4px; }
</style>
