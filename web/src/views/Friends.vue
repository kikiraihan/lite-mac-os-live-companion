<script setup>
import { onMounted, reactive, ref } from 'vue'
import Modal from '../components/Modal.vue'
import PetSprite from '../components/PetSprite.vue'
import { api } from '../api.js'
import { fail, refreshFloor, toast } from '../store.js'

const data = reactive({ friends: [], incoming: [], outgoing: [] })
const loading = ref(true)
const invite = ref(null), copied = ref(false)
const handle = ref(''), adding = ref(false)
const nudging = ref(null), nudgeText = ref('')
const QUICK = ['Peluk dari jauh ♥', 'Kangen', 'Semangat ya!', 'Sudah makan?', 'Istirahat dulu, yuk']
const removing = ref(null)

async function load() {
  try { Object.assign(data, await api.get('/friends')) } catch (e) { fail(e) }
  loading.value = false
}
onMounted(load)

async function makeInvite() {
  try {
    invite.value = await api.post('/friends/invites')
    copyInvite()
  } catch (e) { fail(e) }
}
async function copyInvite() {
  try {
    await navigator.clipboard.writeText(invite.value.url)
    copied.value = true
    setTimeout(() => { copied.value = false }, 2000)
  } catch { /* tautannya tetap terlihat untuk disalin manual */ }
}
async function add() {
  adding.value = true
  try {
    const r = await api.post('/friends/requests', { handle: handle.value })
    toast(r.friends ? 'Kalian sekarang berteman' : 'Permintaan pertemanan terkirim')
    handle.value = ''
    load()
  } catch (e) { fail(e) }
  adding.value = false
}
async function accept(r) {
  try { await api.post(`/friends/requests/${r.id}/accept`); toast(`Kamu dan ${r.user.name} sekarang berteman`); load() } catch (e) { fail(e) }
}
async function dropRequest(r) {
  try { await api.del('/friends/requests/' + r.id); load() } catch (e) { fail(e) }
}
async function ask(f, p) {
  try {
    await api.post(`/pets/${p.id}/request`)
    p.share_status = 'requested'
    toast(`Permintaan dikirim ke ${f.name}`)
  } catch (e) { fail(e) }
}
async function cancel(p) {
  try {
    await api.del('/pet-requests/' + p.share_id)
    await load(); refreshFloor()
  } catch (e) { fail(e) }
}
async function sendNudge() {
  try {
    await api.post(`/friends/${nudging.value.id}/nudge`, { text: nudgeText.value })
    toast(`Sapaan dikirim. Pet di Mac ${nudging.value.name} yang akan menyampaikan.`)
    nudging.value = null; nudgeText.value = ''
  } catch (e) { fail(e) }
}
async function unfriend() {
  try {
    await api.del('/friends/' + removing.value.id)
    removing.value = null
    await load(); refreshFloor()
  } catch (e) { fail(e) }
}
</script>

<template>
  <div class="stack" style="--gap: 36px">
    <div>
      <h1>Teman</h1>
      <p class="muted">Teman bisa saling melihat pet, meminta pet untuk tampil di Mac masing-masing, dan saling menyapa.</p>
    </div>

    <section class="px card ways">
      <div>
        <h3>Undang lewat tautan</h3>
        <p class="small muted">Siapa pun yang membukanya dan mendaftar langsung jadi temanmu. Berlaku 14 hari.</p>
        <div class="row" style="margin-top: 10px">
          <input v-if="invite" class="input mono grow" readonly :value="invite.url" aria-label="Tautan undangan" @focus="$event.target.select()" />
          <button class="btn sun" @click="invite ? copyInvite() : makeInvite()">{{ copied ? 'Tersalin' : invite ? 'Salin' : 'Buat tautan undangan' }}</button>
        </div>
      </div>
      <form @submit.prevent="add">
        <h3>Sudah punya akun?</h3>
        <p class="small muted">Tambahkan dengan nama penggunanya.</p>
        <div class="row" style="margin-top: 10px">
          <input class="input grow" v-model="handle" placeholder="@namapengguna" aria-label="Nama pengguna teman" autocapitalize="none" required />
          <button class="btn" :disabled="adding">Tambah teman</button>
        </div>
      </form>
    </section>

    <section v-if="data.incoming.length || data.outgoing.length">
      <h2>Permintaan pertemanan</h2>
      <div v-for="r in data.incoming" :key="r.id" class="row line">
        <p class="grow"><b>{{ r.user.name }}</b> <span class="muted">@{{ r.user.handle }}</span> ingin berteman.</p>
        <button class="btn small sun" @click="accept(r)">Terima</button>
        <button class="btn small" @click="dropRequest(r)">Tolak</button>
      </div>
      <div v-for="r in data.outgoing" :key="r.id" class="row line">
        <p class="grow muted">Menunggu jawaban <b>{{ r.user.name }}</b> @{{ r.user.handle }}</p>
        <button class="link small" @click="dropRequest(r)">Batalkan</button>
      </div>
    </section>

    <section>
      <p v-if="loading" class="muted">Memuat teman…</p>
      <div v-else-if="!data.friends.length" class="empty">
        <h3>Belum ada teman di sini</h3>
        <p class="muted">Buat tautan undangan di atas, lalu kirim ke orang yang ingin kamu ajak.</p>
      </div>
      <article v-for="f in data.friends" :key="f.id" class="friend">
        <div class="row spread">
          <h2>{{ f.name }} <span class="handle">@{{ f.handle }}</span></h2>
          <div class="row small">
            <button class="btn small" @click="nudging = f">Sapa</button>
            <button class="link danger" @click="removing = f">Hapus teman</button>
          </div>
        </div>
        <p v-if="!f.pets.length" class="muted small">{{ f.name }} belum punya pet.</p>
        <div v-else class="pets">
          <div v-for="p in f.pets" :key="p.id" class="px fpet">
            <PetSprite :src="p.sheet_url" :scale="3" />
            <div>
              <b>{{ p.name }}</b>
              <p v-if="p.bio" class="small muted">{{ p.bio }}</p>
              <template v-if="p.share_status === 'approved'">
                <p class="tag ok">Ada di Mac-mu</p>
                <button class="link small" @click="cancel(p)">Pulangkan</button>
              </template>
              <template v-else-if="p.share_status === 'requested'">
                <p class="tag warn">Menunggu izin</p>
                <button class="link small" @click="cancel(p)">Batalkan</button>
              </template>
              <button v-else class="btn small" @click="ask(f, p)">Minta ke Mac-ku</button>
            </div>
          </div>
        </div>
      </article>
    </section>

    <Modal v-if="nudging" :title="`Sapa ${nudging.name}`" @close="nudging = null">
      <form class="stack" @submit.prevent="sendNudge">
        <div class="row quick" role="group" aria-label="Sapaan cepat">
          <button v-for="q in QUICK" :key="q" type="button" class="btn small" :class="{ sun: nudgeText === q }" @click="nudgeText = q">{{ q }}</button>
        </div>
        <label class="field"><span>Pesan</span>
          <input class="input" v-model="nudgeText" maxlength="80" placeholder="Makan siang yuk" autofocus />
          <small>Muncul sebagai balon kata pet di Mac-nya. Boleh kosong, nanti pet-nya cuma melambai.</small>
        </label>
        <button class="btn primary">Kirim sapaan</button>
      </form>
    </Modal>
    <Modal v-if="removing" :title="`Hapus ${removing.name} dari teman?`" @close="removing = null">
      <p>Pet yang saling kalian titipkan ikut pulang ke pemiliknya masing-masing.</p>
      <div class="row" style="margin-top: 18px">
        <button class="btn danger" @click="unfriend">Hapus teman</button>
        <button class="btn" @click="removing = null">Batal</button>
      </div>
    </Modal>
  </div>
</template>

<style scoped>
.ways { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 32px; }
.quick { gap: 2px; }
.line { padding: 10px 0; border-bottom: 1px solid var(--langit-tua); }
h2 { margin-bottom: 12px; }
.friend { padding: 20px 0; border-top: 3px solid var(--tinta); }
.friend:first-of-type { border-top: 0; padding-top: 0; }
.handle { font-family: var(--body); font-size: 15px; font-weight: 400; color: var(--tinta-2); }
.pets { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 16px; }
.fpet { display: flex; gap: 12px; padding: 12px; align-items: center; }
.fpet > div { display: grid; gap: 4px; justify-items: start; min-width: 0; }
@media (max-width: 720px) { .ways { grid-template-columns: 1fr; gap: 20px; } }
</style>
