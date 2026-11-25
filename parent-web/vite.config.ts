import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import path from 'node:path'

/**
 * 生产环境是同源部署：静态页和 API 由同一个 Node 进程提供，不需要任何代理。
 * 这里的 proxy 只服务于 `npm run dev` —— 开发服务器在 5180，后端在 8787，
 * 用代理把两条接口前缀转过去，前端代码里就始终是相对路径，不用为开发单独配 CORS。
 */
const BACKEND = process.env.VITE_DEV_BACKEND ?? 'http://127.0.0.1:8787'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { '@': path.resolve(import.meta.dirname, 'src') },
  },
  server: {
    port: 5180,
    host: '127.0.0.1',
    proxy: {
      '/auth': { target: BACKEND, changeOrigin: false },
      '/v1': { target: BACKEND, changeOrigin: false },
      '/healthz': { target: BACKEND, changeOrigin: false },
    },
  },
})
