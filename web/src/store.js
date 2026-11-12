import { reactive } from 'vue'
import { api, adminApi } from './api.js'

// Sesi pengguna dan sesi admin disimpan terpisah; satu tidak pernah mengisi yang lain.
export const session = reactive({ user: null, ready: false })
export const adminSession = reactive({ admin: null, ready: false })

// Pet yang sedang berjalan di lantai halaman (pet-ku & titipan yang tampil di Mac)
export const floor = reactive({ pets: [] })

// Pesan singkat di pojok (berhasil / gagal)
export const toasts = reactive([])
let seq = 0
export function toast(message, kind = 'ok') {
  const id = ++seq
  toasts.push({ id, message, kind })
  setTimeout(() => {
    const i = toasts.findIndex((t) => t.id === id)
    if (i >= 0) toasts.splice(i, 1)
  }, kind === 'bad' ? 6000 : 3200)
}
export const fail = (e) => toast(e?.message || 'Ada yang tidak beres. Coba lagi.', 'bad')

export async function loadSession() {
  try {
    session.user = (await api.get('/auth/me')).user
  } catch {
    session.user = null
  }
  session.ready = true
  if (session.user) refreshFloor()
  return session.user
}

export async function loadAdminSession() {
  try {
    adminSession.admin = (await adminApi.get('/auth/me')).admin
  } catch {
    adminSession.admin = null
  }
  adminSession.ready = true
  return adminSession.admin
}

export async function refreshFloor() {
  if (!session.user) { floor.pets = []; return }
  try {
    const d = await api.get('/pets')
    floor.pets = [...d.mine, ...d.guests].filter((p) => p.on_mac && !p.hidden)
      .map((p) => ({ id: p.id, name: p.name, sheet_url: p.sheet_url }))
  } catch { /* lantai boleh kosong */ }
}

export async function logout() {
  try { await api.post('/auth/logout') } catch { /* sesi sudah habis */ }
  session.user = null
  floor.pets = []
}
