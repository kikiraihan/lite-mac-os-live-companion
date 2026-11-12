import { createRouter, createWebHistory } from 'vue-router'
import { adminSession, loadAdminSession, loadSession, session } from './store.js'

const AppShell = () => import('./components/AppShell.vue')
const AdminShell = () => import('./components/AdminShell.vue')

const routes = [
  { path: '/', component: () => import('./views/Landing.vue'), meta: { title: 'Pet pixel di pojok layar Mac-mu' } },
  { path: '/masuk', component: () => import('./views/Login.vue'), meta: { guest: true, title: 'Masuk' } },
  { path: '/daftar', component: () => import('./views/Register.vue'), meta: { guest: true, title: 'Daftar' } },
  { path: '/undang/:code', component: () => import('./views/Invite.vue'), meta: { title: 'Undangan berteman' } },
  {
    path: '/', component: AppShell, meta: { user: true },
    children: [
      { path: 'pet', component: () => import('./views/Pets.vue'), meta: { title: 'Pet-ku' } },
      { path: 'studio', component: () => import('./views/Studio.vue'), meta: { title: 'Bikin pet' } },
      { path: 'studio/gambar', component: () => import('./views/PetEditor.vue'), meta: { title: 'Gambar pet' } },
      { path: 'studio/foto', component: () => import('./views/FromPhoto.vue'), meta: { title: 'Pet dari foto' } },
      { path: 'pet/:id', component: () => import('./views/PetEditor.vue'), meta: { title: 'Ubah pet' } },
      { path: 'teman', component: () => import('./views/Friends.vue'), meta: { title: 'Teman' } },
      { path: 'mac', component: () => import('./views/Mac.vue'), meta: { title: 'Mac' } },
      { path: 'hubungkan', component: () => import('./views/LinkMac.vue'), meta: { title: 'Hubungkan Mac' } },
      { path: 'akun', component: () => import('./views/Account.vue'), meta: { title: 'Akun' } },
    ],
  },
  // Admin: pintu, sesi, dan tampilan sendiri
  { path: '/admin/login', component: () => import('./views/admin/Login.vue'), meta: { title: 'Masuk admin' } },
  {
    path: '/admin', component: AdminShell, meta: { admin: true },
    children: [
      { path: '', component: () => import('./views/admin/Overview.vue'), meta: { title: 'Ringkasan' } },
      { path: 'pengguna', component: () => import('./views/admin/Users.vue'), meta: { title: 'Pengguna' } },
      { path: 'pet', component: () => import('./views/admin/Pets.vue'), meta: { title: 'Pet' } },
      { path: 'koneksi', component: () => import('./views/admin/Connections.vue'), meta: { title: 'Koneksi AI' } },
      { path: 'generate', component: () => import('./views/admin/Generations.vue'), meta: { title: 'Riwayat generate' } },
      { path: 'pengaturan', component: () => import('./views/admin/Settings.vue'), meta: { title: 'Pengaturan' } },
      { path: 'akun', component: () => import('./views/admin/Accounts.vue'), meta: { title: 'Akun admin' } },
      { path: 'audit', component: () => import('./views/admin/Audit.vue'), meta: { title: 'Jejak audit' } },
    ],
  },
  { path: '/:rest(.*)*', component: () => import('./views/NotFound.vue'), meta: { title: 'Tidak ditemukan' } },
]

export const router = createRouter({
  history: createWebHistory(),
  routes,
  scrollBehavior: () => ({ top: 0 }),
})

router.beforeEach(async (to) => {
  if (to.path.startsWith('/admin')) {
    if (!adminSession.ready) await loadAdminSession()
    if (to.meta.admin && !adminSession.admin) return { path: '/admin/login' }
    if (to.path === '/admin/login' && adminSession.admin) return { path: '/admin' }
    return true
  }
  if (!session.ready) await loadSession()
  if (to.meta.user && !session.user) return { path: '/masuk', query: { lanjut: to.fullPath } }
  if (to.meta.guest && session.user) return { path: '/pet' }
  return true
})

router.afterEach((to) => {
  document.title = (to.meta.title ? to.meta.title + ' — ' : '') + (to.path.startsWith('/admin') ? 'Admin Temani' : 'Temani')
})
