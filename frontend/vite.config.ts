import { fileURLToPath, URL } from 'node:url'

import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import vueDevTools from 'vite-plugin-vue-devtools'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig({
  publicDir: false,
  server: {
    host: '0.0.0.0',
    port: 4001,
    strictPort: true,
    cors: true,
    // Origin stamped onto generated asset URLs (CSS url(), imported images,
    // worker URLs). It must point at the host the *browser* uses to reach
    // Vite, so for remote access over Tailscale set e.g.
    // `VITE_DEV_ORIGIN=http://my-desktop:4001`. Defaults to localhost.
    origin: process.env.VITE_DEV_ORIGIN || 'http://localhost:4001',
    allowedHosts: true,
    hmr: {
      port: 4002,
    },
  },
  plugins: [vue(), vueDevTools(), tailwindcss()],
  build: {
    outDir: '../priv/static',
    emptyOutDir: false,
    target: ['es2022'],
    rollupOptions: {
      input: 'src/main.ts',
      output: {
        assetFileNames: 'assets/[name][extname]',
        chunkFileNames: 'assets/[name]-[hash].js',
        entryFileNames: 'assets/[name].js',
      },
    },
  },
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
})
