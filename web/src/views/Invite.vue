<script setup>
import { onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import AuthCard from '../components/AuthCard.vue'
import { api } from '../api.js'
import { session, toast } from '../store.js'

const route = useRoute(), router = useRouter()
const code = String(route.params.code).toUpperCase()
const info = ref(null), error = ref(''), busy = ref(false)

onMounted(async () => {
  try {
    info.value = await api.get('/invites/' + code)
  } catch (e) {
    error.value = e.message
  }
})

async function accept() {
  busy.value = true
  try {
    const r = await api.post(`/invites/${code}/accept`)
    toast(`Kamu dan ${r.friend.name} sekarang berteman`)
    router.push('/teman')
  } catch (e) {
    error.value = e.message
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <AuthCard :title="info ? `${info.from.name} mengajakmu berteman` : 'Undangan berteman'" :pet="info ? info.pet_url : undefined" anim="wave">
    <p v-if="error" class="notice bad" role="alert">{{ error }}</p>
    <div v-else-if="info" class="stack">
      <p>Setelah berteman, kalian bisa saling melihat pet, meminta pet untuk tampil di Mac masing-masing, dan saling menyapa.</p>
      <template v-if="session.user">
        <button class="btn primary block" :disabled="busy" @click="accept">Berteman dengan @{{ info.from.handle }}</button>
      </template>
      <template v-else>
        <RouterLink class="btn primary block" :to="{ path: '/daftar', query: { undangan: code, lanjut: '/teman' } }">Daftar dan berteman</RouterLink>
        <RouterLink class="btn block" :to="{ path: '/masuk', query: { lanjut: route.fullPath } }">Aku sudah punya akun</RouterLink>
      </template>
    </div>
    <p v-else class="muted">Membuka undangan…</p>
  </AuthCard>
</template>
