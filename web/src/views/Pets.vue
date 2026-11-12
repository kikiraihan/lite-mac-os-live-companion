<script setup>
import { onMounted, ref } from 'vue'
import Modal from '../components/Modal.vue'
import PetSprite from '../components/PetSprite.vue'
import { api } from '../api.js'
import { fail, refreshFloor, toast } from '../store.js'

const mine = ref([]), guests = ref([]), incoming = ref([]), lent = ref([])
const loading = ref(true), removing = ref(null)
const ORIGIN = { template: 'Bawaan', drawn: 'Gambar sendiri', ai: 'Dari foto', upload: 'Dari foto' }

async function load() {
  try {
    const [p, r] = await Promise.all([api.get('/pets'), api.get('/pet-requests')])
    mine.value = p.mine; guests.value = p.guests
    incoming.value = r.incoming; lent.value = r.lent
  } catch (e) { fail(e) }
  loading.value = false
}
onMounted(load)

async function setOnMac(p, on) {
  try {
    if (p.mine) await api.patch('/pets/' + p.id, { on_mac: on })
    else await api.patch('/pet-requests/' + p.share_id, { on_mac: on })
    p.on_mac = on
    refreshFloor()
  } catch (e) { fail(e) }
}
async function remove() {
  const p = removing.value
  try {
    await api.del('/pets/' + p.id)
    toast(`${p.name} dilepas`)
    removing.value = null
    await load(); refreshFloor()
  } catch (e) { fail(e) }
}
async function sendHome(p) {
  try {
    await api.del('/pet-requests/' + p.share_id)
    toast(`${p.name} dipulangkan ke ${p.owner.name}`)
    await load(); refreshFloor()
  } catch (e) { fail(e) }
}
async function approve(r) {
  try {
    await api.post(`/pet-requests/${r.id}/approve`)
    toast(`${r.pet.name} sekarang ikut tampil di Mac ${r.user.name}`)
    load()
  } catch (e) { fail(e) }
}
async function decline(r, recalled) {
  try {
    await api.del('/pet-requests/' + r.id)
    toast(recalled ? `${r.pet.name} dipanggil pulang` : 'Permintaan ditolak')
    load()
  } catch (e) { fail(e) }
}
</script>

<template>
  <div class="stack" style="--gap: 36px">
    <div class="row spread">
      <div>
        <h1>Pet-ku</h1>
        <p class="muted">Yang dinyalakan "Tampil di Mac" berjalan di layar Mac-mu, dan di lantai halaman ini.</p>
      </div>
      <RouterLink class="btn primary" to="/studio">Bikin pet baru</RouterLink>
    </div>

    <section v-if="incoming.length" class="px card requests">
      <h3>Ada yang meminta pet-mu</h3>
      <div v-for="r in incoming" :key="r.id" class="row req">
        <PetSprite :src="r.pet.sheet_url" anim="wave" :scale="1.5" />
        <p class="grow"><b>{{ r.user.name }}</b> ingin {{ r.pet.name }} tampil di Mac-nya.</p>
        <button class="btn small sun" @click="approve(r)">Izinkan</button>
        <button class="btn small" @click="decline(r, false)">Tolak</button>
      </div>
    </section>

    <section>
      <p v-if="loading" class="muted">Memanggil pet-mu…</p>
      <div v-else-if="!mine.length" class="empty">
        <h3>Belum ada pet</h3>
        <p class="muted">Pilih pet bawaan, gambar sendiri, atau buat dari fotomu.</p>
        <RouterLink class="btn primary" to="/studio" style="margin-top: 14px">Bikin pet pertama</RouterLink>
      </div>
      <div v-else class="shelf">
        <article v-for="p in mine" :key="p.id" class="px pet">
          <RouterLink :to="'/pet/' + p.id" class="face" :aria-label="'Ubah ' + p.name">
            <PetSprite :src="p.sheet_url" :anim="p.on_mac ? 'idle' : 'sleep'" :scale="3" />
          </RouterLink>
          <div class="info">
            <h3>{{ p.name }}</h3>
            <p class="small muted">{{ ORIGIN[p.origin] || 'Buatan sendiri' }}<template v-if="p.bio"> · {{ p.bio }}</template></p>
            <p v-if="p.hidden" class="tag bad">Disembunyikan admin</p>
            <label class="switch small">
              <input type="checkbox" :checked="p.on_mac" @change="setOnMac(p, $event.target.checked)" />
              <i></i> Tampil di Mac
            </label>
            <div class="row small acts">
              <RouterLink :to="'/pet/' + p.id">Ubah gambar</RouterLink>
              <button class="link danger" @click="removing = p">Lepas</button>
            </div>
          </div>
        </article>
      </div>
    </section>

    <section v-if="guests.length">
      <h2>Titipan teman</h2>
      <div class="shelf">
        <article v-for="p in guests" :key="p.id" class="px pet">
          <div class="face"><PetSprite :src="p.sheet_url" :anim="p.on_mac ? 'idle' : 'sleep'" :scale="3" /></div>
          <div class="info">
            <h3>{{ p.name }}</h3>
            <p class="small muted">Milik {{ p.owner.name }}</p>
            <label class="switch small">
              <input type="checkbox" :checked="p.on_mac" @change="setOnMac(p, $event.target.checked)" />
              <i></i> Tampil di Mac
            </label>
            <div class="row small acts"><button class="link" @click="sendHome(p)">Pulangkan</button></div>
          </div>
        </article>
      </div>
    </section>

    <section v-if="lent.length">
      <h2>Sedang main di Mac teman</h2>
      <div v-for="r in lent" :key="r.id" class="row req line">
        <PetSprite :src="r.pet.sheet_url" anim="walk" :scale="1.5" />
        <p class="grow">{{ r.pet.name }} ada di Mac <b>{{ r.user.name }}</b>.</p>
        <button class="btn small" @click="decline(r, true)">Panggil pulang</button>
      </div>
    </section>

    <Modal v-if="removing" :title="`Lepas ${removing.name}?`" @close="removing = null">
      <p>{{ removing.name }} akan hilang dari akunmu, dari Mac-mu, dan dari Mac teman yang menitipnya. Ini tidak bisa dibatalkan.</p>
      <div class="row" style="margin-top: 18px">
        <button class="btn danger" @click="remove">Lepas {{ removing.name }}</button>
        <button class="btn" @click="removing = null">Batal</button>
      </div>
    </Modal>
  </div>
</template>

<style scoped>
.shelf { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; margin-top: 4px; }
.pet { display: flex; gap: 16px; padding: 16px; align-items: flex-start; }
.face { flex: none; background: var(--langit); padding: 0 4px; border-bottom: 3px solid var(--tinta); display: block; }
.info { min-width: 0; display: grid; gap: 6px; justify-items: start; }
.info h3 { overflow-wrap: anywhere; }
.acts { gap: 14px; margin-top: 2px; }
h2 { margin-bottom: 14px; }
.requests { background: #fff6cf; }
.requests h3 { margin-bottom: 8px; }
.req { padding: 8px 0; }
.req.line { border-bottom: 1px solid var(--langit-tua); }
</style>
