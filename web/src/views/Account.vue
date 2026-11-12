<script setup>
import { reactive, ref } from 'vue'
import { api } from '../api.js'
import { fail, session, toast } from '../store.js'

const profile = reactive({ name: session.user.name, handle: session.user.handle })
const pw = reactive({ current_password: '', new_password: '' })
const busy = ref(false)

async function saveProfile() {
  busy.value = true
  try {
    session.user = (await api.patch('/auth/me', profile)).user
    toast('Profil disimpan')
  } catch (e) { fail(e) }
  busy.value = false
}
async function savePassword() {
  busy.value = true
  try {
    await api.post('/auth/password', pw)
    pw.current_password = pw.new_password = ''
    toast('Password diganti. Browser lain dikeluarkan.')
  } catch (e) { fail(e) }
  busy.value = false
}
</script>

<template>
  <div class="stack account" style="--gap: 36px">
    <div>
      <h1>Akun</h1>
      <p class="muted">{{ session.user.email }}</p>
    </div>
    <form class="stack" @submit.prevent="saveProfile">
      <h2>Profil</h2>
      <label class="field"><span>Nama panggilan</span>
        <input class="input" v-model="profile.name" maxlength="40" required />
      </label>
      <label class="field"><span>Nama pengguna</span>
        <input class="input" v-model="profile.handle" maxlength="20" pattern="[a-z0-9_]{3,20}" autocapitalize="none" required />
        <small>Teman mencarimu dengan nama ini.</small>
      </label>
      <div><button class="btn primary" :disabled="busy">Simpan profil</button></div>
    </form>
    <form class="stack" @submit.prevent="savePassword">
      <h2>Ganti password</h2>
      <label class="field"><span>Password sekarang</span>
        <input class="input" type="password" v-model="pw.current_password" autocomplete="current-password" required />
      </label>
      <label class="field"><span>Password baru</span>
        <input class="input" type="password" v-model="pw.new_password" minlength="8" autocomplete="new-password" required />
        <small>Minimal 8 karakter.</small>
      </label>
      <div><button class="btn" :disabled="busy">Ganti password</button></div>
    </form>
  </div>
</template>

<style scoped>
.account { max-width: 440px; }
</style>
