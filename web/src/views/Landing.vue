<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue'
import Playground from '../components/Playground.vue'
import PetSprite from '../components/PetSprite.vue'
import { api } from '../api.js'
import { session } from '../store.js'

const heroPets = [
  { id: 'oren', name: 'Mochi', sheet_url: '/api/templates/oren.png' },
  { id: 'kelinci', name: 'Bubu', sheet_url: '/api/templates/kelinci.png' },
  { id: 'hitam', name: 'Kopi', sheet_url: '/api/templates/hitam.png' },
]
const download = ref('https://github.com/kikiraihan/lite-mac-os-live-companion/releases/latest')
const clock = ref('')
let timer = 0
const tick = () => {
  clock.value = new Date().toLocaleString('id-ID', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })
}
onMounted(async () => {
  tick()
  timer = setInterval(tick, 20000)
  try { download.value = (await api.get('/config')).mac_download_url } catch { /* pakai tautan bawaan */ }
})
onBeforeUnmount(() => clearInterval(timer))
</script>

<template>
  <div class="landing">
    <header class="bar">
      <span class="brand pixel">Temani</span>
      <span class="grow"></span>
      <template v-if="session.user">
        <RouterLink to="/pet">Buka pet-ku</RouterLink>
      </template>
      <template v-else>
        <RouterLink to="/masuk">Masuk</RouterLink>
        <RouterLink to="/daftar">Daftar</RouterLink>
      </template>
    </header>

    <section class="hero">
      <div class="pitch">
        <h1>Ada yang nemenin di pojok layar.</h1>
        <p class="lead">
          Temani adalah pet pixel kecil yang hidup di Mac-mu. Dia jalan-jalan di tepi layar, ketiduran,
          joget sendiri, kadang pulang bawa bunga. Bikin pet-mu, lalu titipkan ke Mac teman.
        </p>
        <div class="row">
          <RouterLink class="btn primary" :to="session.user ? '/studio' : '/daftar'">Bikin pet-ku</RouterLink>
          <a class="btn" :href="download" target="_blank" rel="noopener">Unduh untuk Mac</a>
        </div>
        <p class="small muted">Gratis. macOS 13 ke atas, Apple Silicon dan Intel.</p>
      </div>

      <figure class="px screen">
        <div class="menubar">
          <span class="apple pixel">Temani</span><span>Berkas</span><span>Tampilan</span>
          <span class="grow"></span>
          <PetSprite src="/api/templates/oren.png" anim="walk" :scale="0.75" />
          <span>{{ clock }}</span>
        </div>
        <div class="desk">
          <div class="px win">
            <div class="winbar"><i></i><i></i><i></i><b>laporan-final-banget.txt</b></div>
            <p>Bab 3 belum selesai, tapi tidak apa-apa.<br />Ada yang nungguin di bawah.</p>
          </div>
          <Playground :pets="heroPets" :height="132" :ground="14" :scale="3" />
          <div class="dock" aria-hidden="true"></div>
        </div>
        <figcaption class="small">Coba elus mereka, atau angkat lalu lepaskan.</figcaption>
      </figure>
    </section>

    <section class="band">
      <h2>Tiga cara punya pet</h2>
      <div class="ways">
        <article>
          <PetSprite src="/api/templates/beruang.png" anim="happy" :scale="3" />
          <h3>Pilih, lalu beri nama</h3>
          <p>Kucing, kelinci, beruang, rubah. Sudah bisa jalan, tidur, dan joget sejak detik pertama.</p>
        </article>
        <article>
          <PetSprite src="/api/templates/rubah.png" anim="tour" :scale="3" />
          <h3>Gambar sendiri</h3>
          <p>Editor piksel 32×32 untuk tiap pose. Ubah warna, tambah topi, atau mulai dari kanvas kosong.</p>
        </article>
        <article>
          <PetSprite src="/api/templates/kelinci.png" anim="wave" :scale="3" />
          <h3>Dari fotomu</h3>
          <p>Unggah foto, dan AI menggambar versi pixel-mu dalam 16 pose. Bisa juga lewat ChatGPT-mu sendiri.</p>
        </article>
      </div>
    </section>

    <section class="band duo">
      <div>
        <h2>Lebih ramai kalau berdua</h2>
        <p class="measure">
          Undang teman lewat satu tautan. Kalau kamu suka pet-nya, minta saja: begitu dia setuju, pet itu ikut
          jalan-jalan di Mac-mu, di samping pet-mu sendiri. Kirim sapaan, dan pet di Mac temanmu yang menyampaikannya.
        </p>
      </div>
      <div class="px chat" aria-hidden="true">
        <div class="say">Dina menyapa: makan siang yuk</div>
        <div class="row pair">
          <PetSprite src="/api/templates/hitam.png" anim="wave" :scale="3" />
          <PetSprite src="/api/templates/oren.png" anim="happy" :scale="3" flip />
        </div>
      </div>
    </section>

    <section class="band">
      <h2>Cuma mainan, sungguh</h2>
      <ul class="plain measure">
        <li>Tidak membaca layar, ketikan, atau berkas di Mac-mu.</li>
        <li>Tidak butuh izin Aksesibilitas atau Perekaman Layar.</li>
        <li>Aplikasi Mac hanya mengambil gambar pet dan sapaan teman dari akunmu.</li>
        <li>Foto yang kamu unggah dihapus begitu pet-nya selesai digambar.</li>
        <li>Kode sumbernya terbuka di GitHub.</li>
      </ul>
    </section>

    <footer class="foot small muted">
      <span>Temani</span>
      <a href="https://github.com/kikiraihan/lite-mac-os-live-companion" target="_blank" rel="noopener">Kode sumber</a>
    </footer>
  </div>
</template>

<style scoped>
.landing { min-height: 100vh; }
.bar { display: flex; align-items: center; gap: 20px; min-height: 40px; padding: 0 20px; background: var(--tinta); color: #fff; }
.bar a { color: #d9d4ee; text-decoration: none; }
.bar a:hover { color: #fff; }
.brand { font-size: 20px; color: var(--jeruk); }

.hero { max-width: 1120px; margin: 0 auto; padding: 56px 20px 40px; display: grid; grid-template-columns: minmax(0, 5fr) minmax(0, 6fr); gap: 48px; align-items: center; }
.pitch h1 { font-size: 56px; line-height: 1.05; }
.lead { margin: 20px 0 24px; font-size: 18px; max-width: 46ch; }
.pitch .small { margin-top: 14px; }

.screen { margin: 3px; padding: 0; }
.menubar { display: flex; align-items: center; gap: 14px; height: 28px; padding: 0 12px; background: var(--tinta); color: #e9e5f7; font-size: 13px; white-space: nowrap; overflow: hidden; }
.menubar .apple { color: var(--jeruk); font-size: 15px; }
.desk { position: relative; height: 300px; background: var(--langit-tua); overflow: hidden; }
.win { position: absolute; top: 28px; left: 28px; width: min(300px, 70%); font-size: 14px; }
.winbar { display: flex; align-items: center; gap: 5px; padding: 6px 8px; background: var(--langit); border-bottom: 3px solid var(--tinta); }
.winbar i { width: 8px; height: 8px; background: var(--tinta); }
.winbar b { margin-left: 6px; font-weight: 500; font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.win p { padding: 12px; }
.desk :deep(.playground) { position: absolute; left: 0; right: 0; bottom: 0; }
.dock { position: absolute; left: 0; right: 0; bottom: 0; height: 14px; background: #b4bff3; border-top: 3px solid var(--tinta); }
figcaption { padding: 10px 12px; border-top: 3px solid var(--tinta); }

.band { max-width: 1120px; margin: 0 auto; padding: 40px 20px; }
.band h2 { margin-bottom: 20px; }
.ways { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 32px; }
.ways h3 { margin: 10px 0 6px; }
.duo { display: grid; grid-template-columns: minmax(0, 6fr) minmax(0, 4fr); gap: 48px; align-items: center; }
.chat { padding: 20px; background: var(--kertas); }
.say { display: inline-block; padding: 6px 12px; background: var(--lemon); font-weight: 500; }
.pair { margin-top: 12px; gap: 4px; }
.plain { margin: 0; padding-left: 20px; }
.plain li { margin: 6px 0; }
.plain li::marker { content: '▪  '; color: var(--stroberi); }
.foot { max-width: 1120px; margin: 24px auto 0; padding: 20px; display: flex; justify-content: space-between; border-top: 3px solid var(--langit-tua); }

@media (max-width: 860px) {
  .hero, .duo { grid-template-columns: 1fr; gap: 28px; padding-top: 32px; }
  .pitch h1 { font-size: 38px; }
  .ways { grid-template-columns: 1fr; gap: 24px; }
  .desk { height: 260px; }
}
</style>
