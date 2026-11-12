<script setup>
import { reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { adminApi } from '../../api.js'
import { adminSession } from '../../store.js'

const router = useRouter()
const form = reactive({ email: '', password: '' })
const error = ref(''), busy = ref(false)

async function submit() {
  busy.value = true
  error.value = ''
  try {
    adminSession.admin = (await adminApi.post('/auth/login', form)).admin
    adminSession.ready = true
    router.push('/admin')
  } catch (e) { error.value = e.message }
  busy.value = false
}
</script>

<template>
  <div class="wrap">
    <div class="px box">
      <p class="row"><span class="pixel brand">Temani</span><span class="badge">Admin</span></p>
      <h2>Masuk admin</h2>
      <form class="stack" @submit.prevent="submit">
        <label class="field"><span>Email</span>
          <input class="input" type="email" v-model="form.email" autocomplete="username" required autofocus />
        </label>
        <label class="field"><span>Password</span>
          <input class="input" type="password" v-model="form.password" autocomplete="current-password" required />
        </label>
        <p v-if="error" class="notice bad" role="alert">{{ error }}</p>
        <button class="btn sun block" :disabled="busy">{{ busy ? 'Memeriksa…' : 'Masuk' }}</button>
      </form>
      <p class="small muted">Akun admin terpisah dari akun pengguna. Admin pertama dibuat dari server dengan <code>make admin</code>.</p>
    </div>
  </div>
</template>

<style scoped>
.wrap { min-height: 100vh; display: grid; place-items: center; padding: 20px; background: var(--tinta); }
.box { width: min(400px, 100%); padding: 28px; display: grid; gap: 16px; }
.brand { font-size: 22px; }
.badge { background: var(--lemon); font-size: 12px; font-weight: 600; padding: 1px 8px; }
</style>
