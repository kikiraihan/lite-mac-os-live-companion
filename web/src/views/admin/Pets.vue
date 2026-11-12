<script setup>
import { onMounted, ref } from 'vue'
import PetSprite from '../../components/PetSprite.vue'
import { adminApi } from '../../api.js'
import { fail, toast } from '../../store.js'
import { day } from '../../lib/format.js'

const rows = ref([]), q = ref(''), loading = ref(true)
const ORIGIN = { template: 'Bawaan', drawn: 'Gambar sendiri', ai: 'AI', upload: 'Unggahan' }
async function load() {
  try { rows.value = (await adminApi.get('/pets?q=' + encodeURIComponent(q.value))).data } catch (e) { fail(e) }
  loading.value = false
}
onMounted(load)
async function toggle(p) {
  try {
    await adminApi.patch('/pets/' + p.id, { hidden: !p.hidden })
    p.hidden = !p.hidden
    toast(p.hidden ? `${p.name} disembunyikan dari teman dan dari Mac` : `${p.name} ditampilkan lagi`)
  } catch (e) { fail(e) }
}
</script>

<template>
  <div class="stack" style="--gap: 20px">
    <div class="row spread">
      <div>
        <h1>Pet</h1>
        <p class="muted">Pet yang disembunyikan tetap terlihat pemiliknya, tapi tidak tampil ke teman maupun di Mac.</p>
      </div>
      <form class="row" @submit.prevent="load">
        <input class="input" v-model="q" placeholder="Cari nama pet atau pemilik" aria-label="Cari pet" style="width: 240px" />
        <button class="btn">Cari</button>
      </form>
    </div>
    <p v-if="loading" class="muted">Memuat…</p>
    <div v-else-if="!rows.length" class="empty"><h3>Tidak ada pet yang cocok</h3></div>
    <div v-else class="grid">
      <article v-for="p in rows" :key="p.id" class="px item" :class="{ hidden: p.hidden }">
        <PetSprite :src="p.sheet_url" anim="tour" :scale="3" />
        <div>
          <b>{{ p.name }}</b> <span v-if="p.hidden" class="tag bad">Disembunyikan</span>
          <p class="small muted">@{{ p.owner_handle }} · {{ ORIGIN[p.origin] || p.origin }} · {{ day(p.created_at) }}</p>
          <p class="small muted" v-if="p.lent">Dititipkan ke {{ p.lent }} teman</p>
          <button class="link small" :class="{ danger: !p.hidden }" @click="toggle(p)">{{ p.hidden ? 'Tampilkan lagi' : 'Sembunyikan' }}</button>
        </div>
      </article>
    </div>
  </div>
</template>

<style scoped>
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; }
.item { display: flex; gap: 12px; padding: 12px; align-items: center; }
.item.hidden { background: #fff0f2; }
.item > div { display: grid; gap: 3px; justify-items: start; min-width: 0; }
</style>
