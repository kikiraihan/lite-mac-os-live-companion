<script setup>
import { toasts } from '../store.js'
</script>

<template>
  <div class="toasts" role="status" aria-live="polite">
    <div v-for="t in toasts" :key="t.id" class="px toast" :class="t.kind">{{ t.message }}</div>
  </div>
</template>

<style scoped>
.toasts { position: fixed; top: 52px; right: 16px; z-index: 60; display: grid; gap: 12px; max-width: min(360px, calc(100vw - 32px)); }
.toast { padding: 10px 14px; font-weight: 500; }
.toast.ok { background: #dbf5e9; }
.toast.bad { background: #ffe3e8; }
</style>
