<script setup>
import { onBeforeUnmount, onMounted } from 'vue'

defineProps({ title: String, wide: Boolean })
const emit = defineEmits(['close'])
const onKey = (e) => { if (e.key === 'Escape') emit('close') }
onMounted(() => window.addEventListener('keydown', onKey))
onBeforeUnmount(() => window.removeEventListener('keydown', onKey))
</script>

<template>
  <div class="veil" @mousedown.self="emit('close')">
    <div class="px sheet" :class="{ wide }" role="dialog" aria-modal="true" :aria-label="title">
      <div class="row spread head">
        <h3>{{ title }}</h3>
        <button class="link" @click="emit('close')">Tutup</button>
      </div>
      <slot />
    </div>
  </div>
</template>

<style scoped>
.veil { position: fixed; inset: 0; z-index: 50; background: rgba(42, 33, 64, 0.55); display: grid; place-items: center; padding: 16px; overflow-y: auto; }
.sheet { width: min(480px, 100%); padding: 20px; }
.sheet.wide { width: min(720px, 100%); }
.head { margin-bottom: 16px; }
</style>
