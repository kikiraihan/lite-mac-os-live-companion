<script setup>
import { reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import AuthCard from '../components/AuthCard.vue'
import { api } from '../api.js'
import { refreshFloor, session } from '../store.js'

const route = useRoute(), router = useRouter()
const form = reactive({ email: '', password: '' })
const error = ref(''), busy = ref(false)

async function submit() {
  busy.value = true
  error.value = ''
  try {
    session.user = (await api.post('/auth/login', form)).user
    refreshFloor()
    const next = String(route.query.lanjut || '')
    router.push(next.startsWith('/') && !next.startsWith('//') ? next : '/pet')
  } catch (e) {
    error.value = e.message
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <AuthCard title="Masuk">
    <form class="stack" @submit.prevent="submit">
      <label class="field"><span>Email</span>
        <input class="input" type="email" v-model="form.email" autocomplete="email" required autofocus />
      </label>
      <label class="field"><span>Password</span>
        <input class="input" type="password" v-model="form.password" autocomplete="current-password" required />
      </label>
      <p v-if="error" class="notice bad" role="alert">{{ error }}</p>
      <button class="btn primary block" :disabled="busy">{{ busy ? 'Memeriksa…' : 'Masuk' }}</button>
    </form>
    <template #below>
      Belum punya akun? <RouterLink :to="{ path: '/daftar', query: route.query }">Daftar</RouterLink>
    </template>
  </AuthCard>
</template>
