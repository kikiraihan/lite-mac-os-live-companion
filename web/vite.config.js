import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// Dev: `npm run dev` (port 5173) dengan proxy /api ke server Go di :8080.
export default defineConfig({
  plugins: [vue()],
  server: { proxy: { '/api': 'http://localhost:8080' } },
  build: { target: 'es2020', chunkSizeWarningLimit: 800 },
})
