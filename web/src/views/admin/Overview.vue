<script setup>
import { onMounted, ref } from 'vue'
import { adminApi } from '../../api.js'
import { fail } from '../../store.js'

const d = ref(null)
onMounted(async () => { try { d.value = await adminApi.get('/overview') } catch (e) { fail(e) } })
const peak = (s) => Math.max(1, ...s.map((x) => x.count))
const short = (s) => new Date(s).toLocaleDateString('id-ID', { day: 'numeric', month: 'short' })
</script>

<template>
  <div class="stack" style="--gap: 28px">
    <h1>Ringkasan</h1>
    <p v-if="!d" class="muted">Memuat…</p>
    <template v-else>
      <p v-if="d.ai_mock" class="notice">AI_MOCK menyala: generate memakai provider palsu. Matikan di production.</p>
      <p v-else-if="!d.connections_enabled" class="notice">
        Belum ada koneksi AI yang aktif, jadi pengguna hanya bisa membuat pet dari foto lewat cara manual.
        <RouterLink to="/admin/koneksi">Tambah koneksi</RouterLink>
      </p>
      <dl class="stats">
        <div><dt>Pengguna</dt><dd class="pixel">{{ d.users }}</dd><small>{{ d.users_week }} baru minggu ini</small></div>
        <div><dt>Pet</dt><dd class="pixel">{{ d.pets }}</dd><small>{{ d.lent_pets }} sedang dititipkan</small></div>
        <div><dt>Pertemanan</dt><dd class="pixel">{{ d.friendships }}</dd></div>
        <div><dt>Mac aktif 7 hari</dt><dd class="pixel">{{ d.active_macs }}</dd></div>
        <div><dt>Generate 24 jam</dt><dd class="pixel">{{ d.generations_today }}</dd><small :class="{ bad: d.generations_failed_today }">{{ d.generations_failed_today }} gagal</small></div>
      </dl>
      <div class="charts">
        <figure v-for="[title, series] in [['Pendaftar per hari', d.signups], ['Generate per hari', d.generations]]" :key="title" class="px card">
          <figcaption><b>{{ title }}</b> <span class="muted small">14 hari terakhir</span></figcaption>
          <div class="bars" role="img" :aria-label="title">
            <div v-for="s in series" :key="s.date" class="bar" :title="`${short(s.date)}: ${s.count}`">
              <span v-if="s.count" class="n">{{ s.count }}</span>
              <i :style="{ height: (s.count / peak(series)) * 100 + '%' }"></i>
            </div>
          </div>
          <div class="row spread small muted"><span>{{ short(series[0].date) }}</span><span>{{ short(series[series.length - 1].date) }}</span></div>
        </figure>
      </div>
    </template>
  </div>
</template>

<style scoped>
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 0; margin: 0; border-top: 3px solid var(--tinta); border-bottom: 3px solid var(--tinta); }
.stats div { padding: 16px 16px 16px 0; }
.stats dt { font-size: 14px; color: var(--tinta-2); }
.stats dd { margin: 2px 0; font-size: 40px; line-height: 1; }
.stats small { color: var(--tinta-2); }
.stats small.bad { color: var(--merah); font-weight: 600; }
.charts { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 20px; }
figure { margin: 3px; }
.bars { display: flex; align-items: flex-end; gap: 4px; height: 120px; margin: 14px 0 6px; border-bottom: 3px solid var(--tinta); }
.bar { flex: 1; height: 100%; display: flex; flex-direction: column; justify-content: flex-end; align-items: center; }
.bar i { display: block; width: 100%; background: var(--stroberi); min-height: 0; }
.bar .n { font-size: 11px; color: var(--tinta-2); }
</style>
