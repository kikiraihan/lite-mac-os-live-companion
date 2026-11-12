<script setup>
import { onMounted, reactive, ref } from 'vue'
import Modal from '../../components/Modal.vue'
import { adminApi } from '../../api.js'
import { adminSession, fail, toast } from '../../store.js'
import { when } from '../../lib/format.js'

const rows = ref([]), loading = ref(true), adding = ref(false)
const form = reactive({ email: '', name: '', password: '', super: false })
const pw = reactive({ current_password: '', new_password: '' })

async function load() {
  try { rows.value = (await adminApi.get('/accounts')).data } catch (e) { fail(e) }
  loading.value = false
}
onMounted(load)
async function create() {
  try {
    await adminApi.post('/accounts', form)
    toast('Akun admin dibuat')
    adding.value = false
    Object.assign(form, { email: '', name: '', password: '', super: false })
    load()
  } catch (e) { fail(e) }
}
async function update(a, patch) {
  try { await adminApi.patch('/accounts/' + a.id, patch); load() } catch (e) { fail(e) }
}
async function changePassword() {
  try {
    await adminApi.post('/auth/password', pw)
    pw.current_password = pw.new_password = ''
    toast('Password admin diganti')
  } catch (e) { fail(e) }
}
</script>

<template>
  <div class="stack" style="--gap: 28px">
    <div class="row spread">
      <div>
        <h1>Akun admin</h1>
        <p class="muted">Akun admin tidak ada hubungannya dengan akun pengguna, walau emailnya sama.</p>
      </div>
      <button class="btn sun" @click="adding = true">Tambah admin</button>
    </div>
    <p v-if="loading" class="muted">Memuat…</p>
    <div v-else class="scroll-x">
      <table class="data">
        <thead><tr><th>Email</th><th>Nama</th><th>Peran</th><th>Masuk terakhir</th><th></th></tr></thead>
        <tbody>
          <tr v-for="a in rows" :key="a.id">
            <td>{{ a.email }} <span v-if="a.disabled" class="tag bad">Nonaktif</span></td>
            <td>{{ a.name || '–' }}</td>
            <td>{{ a.super ? 'Superadmin' : 'Admin' }}</td>
            <td>{{ when(a.last_login_at) }}</td>
            <td>
              <span v-if="a.id === adminSession.admin.id" class="muted">Kamu</span>
              <span v-else class="row" style="gap: 14px">
                <button class="link" @click="update(a, { super: !a.super })">{{ a.super ? 'Jadikan admin biasa' : 'Jadikan superadmin' }}</button>
                <button class="link" :class="{ danger: !a.disabled }" @click="update(a, { disabled: !a.disabled })">{{ a.disabled ? 'Aktifkan' : 'Nonaktifkan' }}</button>
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <form class="stack pw" @submit.prevent="changePassword">
      <h2>Ganti password-ku</h2>
      <label class="field"><span>Password sekarang</span><input class="input" type="password" v-model="pw.current_password" autocomplete="current-password" required /></label>
      <label class="field"><span>Password baru</span><input class="input" type="password" v-model="pw.new_password" minlength="8" autocomplete="new-password" required /></label>
      <div><button class="btn">Ganti password</button></div>
    </form>

    <Modal v-if="adding" title="Tambah admin" @close="adding = false">
      <form class="stack" @submit.prevent="create">
        <label class="field"><span>Email</span><input class="input" type="email" v-model="form.email" required autofocus /></label>
        <label class="field"><span>Nama</span><input class="input" v-model="form.name" maxlength="60" /></label>
        <label class="field"><span>Password awal</span><input class="input" type="password" v-model="form.password" minlength="8" autocomplete="new-password" required />
          <small>Minimal 8 karakter. Minta dia menggantinya setelah masuk.</small></label>
        <label class="switch"><input type="checkbox" v-model="form.super" /><i></i> Superadmin (boleh mengelola akun admin)</label>
        <button class="btn sun">Buat akun admin</button>
      </form>
    </Modal>
  </div>
</template>

<style scoped>
.pw { max-width: 400px; }
</style>
