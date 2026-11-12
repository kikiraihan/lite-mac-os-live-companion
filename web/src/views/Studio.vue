<script setup>
import { onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import PetSprite from '../components/PetSprite.vue'
import { api } from '../api.js'
import { fail, refreshFloor, toast } from '../store.js'

const router = useRouter()
const templates = ref([]), chosen = ref('oren'), name = ref(''), busy = ref(false)

onMounted(async () => {
  try { templates.value = (await api.get('/templates')).data } catch (e) { fail(e) }
})
const current = () => templates.value.find((t) => t.id === chosen.value)

async function adopt() {
  busy.value = true
  try {
    const { pet } = await api.post('/pets', { template: chosen.value, name: name.value })
    toast(`${pet.name} sudah jadi pet-mu`)
    refreshFloor()
    router.push('/pet')
  } catch (e) { fail(e) }
  busy.value = false
}
</script>

<template>
  <div class="stack" style="--gap: 32px">
    <div>
      <h1>Bikin pet</h1>
      <p class="muted">Tiga jalan. Apa pun pilihanmu, gambarnya masih bisa diubah nanti.</p>
    </div>

    <section class="px card way">
      <div class="grow">
        <h2>Pilih yang sudah jadi</h2>
        <div class="row choices" role="radiogroup" aria-label="Pet bawaan">
          <button v-for="t in templates" :key="t.id" role="radio" :aria-checked="chosen === t.id" :class="{ on: chosen === t.id }" @click="chosen = t.id">
            <PetSprite :src="t.sheet_url" :anim="chosen === t.id ? 'happy' : 'idle'" :scale="2" />
            <span class="small">{{ t.title }}</span>
          </button>
        </div>
        <form class="row" @submit.prevent="adopt">
          <input class="input name" v-model="name" maxlength="24" :placeholder="current()?.default_name || 'Nama pet'" aria-label="Nama pet" />
          <button class="btn primary" :disabled="busy">Jadikan pet-ku</button>
          <RouterLink class="small" :to="{ path: '/studio/gambar', query: { dari: chosen } }">Ubah gambarnya dulu</RouterLink>
        </form>
      </div>
    </section>

    <div class="two">
      <RouterLink class="px card door" to="/studio/gambar">
        <PetSprite src="/api/templates/rubah.png" anim="tour" :scale="3" />
        <h2>Gambar sendiri</h2>
        <p>Editor piksel 32×32 dengan 16 pose. Mulai dari kanvas kosong atau dari pet bawaan.</p>
        <span class="go">Buka editor</span>
      </RouterLink>
      <RouterLink class="px card door" to="/studio/foto">
        <PetSprite src="/api/templates/kelinci.png" anim="wave" :scale="3" />
        <h2>Dari foto</h2>
        <p>Unggah fotomu dan biarkan AI menggambar versi pixel-nya. Bisa juga lewat ChatGPT-mu sendiri.</p>
        <span class="go">Pakai foto</span>
      </RouterLink>
    </div>
  </div>
</template>

<style scoped>
.way h2 { margin-bottom: 14px; }
.choices { gap: 8px; margin-bottom: 16px; }
.choices button { background: none; border: 3px solid transparent; padding: 6px 8px; cursor: pointer; display: grid; justify-items: center; gap: 2px; }
.choices button.on { border-color: var(--tinta); background: var(--lemon); }
.name { width: 200px; }
.two { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 20px; }
.door { text-decoration: none; display: grid; gap: 8px; justify-items: start; align-content: start; }
.door:hover { background: #fffbe6; }
.go { font-weight: 600; text-decoration: underline; text-underline-offset: 3px; margin-top: 4px; }
@media (max-width: 640px) { .two { grid-template-columns: 1fr; } .name { width: 100%; } }
</style>
