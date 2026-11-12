<script setup>
// Halaman yang dibuka aplikasi Mac: menyetujui kode supaya Mac itu terhubung ke akun ini.
import { onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import PetSprite from '../components/PetSprite.vue'
import { api } from '../api.js'
import { session } from '../store.js'

const route = useRoute()
const code = ref(String(route.query.code || '').toUpperCase())
const device = ref(''), error = ref(''), done = ref(false), busy = ref(false)

async function check() {
  error.value = ''; device.value = ''
  if (code.value.replace('-', '').length < 8) return
  try {
    device.value = (await api.get('/link/' + encodeURIComponent(code.value))).device_name
  } catch (e) { error.value = e.message }
}
onMounted(check)

async function approve() {
  busy.value = true
  try {
    await api.post(`/link/${encodeURIComponent(code.value)}/approve`)
    done.value = true
  } catch (e) { error.value = e.message }
  busy.value = false
}
</script>

<template>
  <div class="link stack">
    <template v-if="done">
      <PetSprite src="/api/templates/oren.png" anim="happy" :scale="4" />
      <h1>Mac terhubung</h1>
      <p>Kembali ke Mac-mu. Pet-mu muncul di layar dalam beberapa detik.</p>
      <RouterLink class="btn" to="/pet">Lihat pet-ku</RouterLink>
    </template>
    <template v-else>
      <h1>Hubungkan Mac</h1>
      <form class="stack" @submit.prevent="check">
        <label class="field"><span>Kode dari aplikasi Mac</span>
          <input class="input code pixel" v-model="code" maxlength="9" placeholder="ABCD-EFGH" autocapitalize="characters" autocomplete="off" @input="code = code.toUpperCase()" />
        </label>
        <button v-if="!device" class="btn">Periksa kode</button>
      </form>
      <p v-if="error" class="notice bad" role="alert">{{ error }}</p>
      <div v-if="device" class="px card stack">
        <p><b>{{ device }}</b> ingin terhubung ke akun <b>@{{ session.user.handle }}</b>.</p>
        <p class="small muted">Pastikan kode di atas sama dengan yang tampil di aplikasi. Mac ini hanya bisa mengambil gambar pet dan sapaan teman.</p>
        <div class="row">
          <button class="btn primary" :disabled="busy" @click="approve">Hubungkan Mac ini</button>
          <RouterLink class="btn" to="/mac">Bukan aku</RouterLink>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.link { max-width: 460px; justify-items: start; }
.code { font-size: 28px; letter-spacing: 0.08em; text-align: center; min-height: 56px; }
</style>
