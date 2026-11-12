<script setup>
import { onMounted, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import AuthCard from '../components/AuthCard.vue'
import PetSprite from '../components/PetSprite.vue'
import { api } from '../api.js'
import { refreshFloor, session } from '../store.js'

const route = useRoute(), router = useRouter()
const form = reactive({ name: '', handle: '', email: '', password: '', template: 'oren', invite: String(route.query.undangan || '') })
const templates = ref([])
const error = ref(''), busy = ref(false), closed = ref(false)
let handleTouched = false

// nama pengguna diusulkan dari nama panggilan sampai pengguna mengetiknya sendiri
watch(() => form.name, (n) => {
  if (!handleTouched) form.handle = n.toLowerCase().replace(/[^a-z0-9_]+/g, '').slice(0, 20)
})

onMounted(async () => {
  try {
    templates.value = (await api.get('/templates')).data
    closed.value = !(await api.get('/config')).registration_open && !form.invite
  } catch { /* form tetap bisa dipakai */ }
})

async function submit() {
  busy.value = true
  error.value = ''
  try {
    session.user = (await api.post('/auth/register', form)).user
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
  <AuthCard title="Daftar" :pet="`/api/templates/${form.template}.png`" anim="happy">
    <p v-if="closed" class="notice">Pendaftaran sedang ditutup. Minta tautan undangan dari teman yang sudah punya akun.</p>
    <form v-else class="stack" @submit.prevent="submit">
      <fieldset class="pick">
        <legend>Pilih pet pertamamu</legend>
        <div class="row">
          <label v-for="t in templates" :key="t.id" :class="{ on: form.template === t.id }" :title="t.title">
            <input type="radio" name="template" :value="t.id" v-model="form.template" />
            <PetSprite :src="t.sheet_url" frame="idle" :scale="1.5" />
          </label>
        </div>
        <small class="muted">Bisa diganti, digambar ulang, atau ditambah nanti.</small>
      </fieldset>
      <label class="field"><span>Nama panggilan</span>
        <input class="input" v-model="form.name" maxlength="40" autocomplete="nickname" required />
      </label>
      <label class="field"><span>Nama pengguna</span>
        <input class="input" v-model="form.handle" maxlength="20" pattern="[a-z0-9_]{3,20}" autocapitalize="none" required @input="handleTouched = true" />
        <small>Teman mencarimu dengan nama ini. Huruf kecil, angka, garis bawah.</small>
      </label>
      <label class="field"><span>Email</span>
        <input class="input" type="email" v-model="form.email" autocomplete="email" required />
      </label>
      <label class="field"><span>Password</span>
        <input class="input" type="password" v-model="form.password" minlength="8" autocomplete="new-password" required />
        <small>Minimal 8 karakter.</small>
      </label>
      <p v-if="error" class="notice bad" role="alert">{{ error }}</p>
      <button class="btn primary block" :disabled="busy">{{ busy ? 'Membuat akun…' : 'Daftar' }}</button>
    </form>
    <template #below>
      Sudah punya akun? <RouterLink :to="{ path: '/masuk', query: route.query }">Masuk</RouterLink>
    </template>
  </AuthCard>
</template>

<style scoped>
.pick { border: 0; padding: 0; margin: 0; }
.pick legend { font-weight: 500; margin-bottom: 8px; padding: 0; }
.pick .row { gap: 6px; margin-bottom: 6px; }
.pick label { cursor: pointer; padding: 4px; border: 3px solid transparent; }
.pick label.on { border-color: var(--tinta); background: var(--lemon); }
.pick input { position: absolute; opacity: 0; }
.pick label:has(input:focus-visible) { outline: 3px solid #4d7dff; outline-offset: 2px; }
</style>
