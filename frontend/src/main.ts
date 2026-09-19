import './assets/main.css'

import { createApp } from 'vue'
import { createPinia } from 'pinia'

import App from './App.vue'
import router from './router'
import { configureSocket } from '@/lib/socket'
import { installBackend } from '@/lib/transport'
import { useAuthStore } from '@/stores/auth'

async function bootstrap() {
  const app = createApp(App)
  app.use(createPinia())

  // Hydrate the auth session before mounting so router guards see the
  // resolved identity on first render and don't ping-pong unauthenticated
  // visitors through `/auth/login` before `/api/me` returns.
  try {
    await useAuthStore().hydrate()
  } catch (err) {
    console.warn('[boot] auth hydrate failed; continuing as unauthenticated', err)
  }

  app.use(router)

  // The socket can't reach into a store directly without creating an import
  // cycle (stores/auth already imports lib/socket for its sign-out teardown),
  // so the one thing it needs from the app is injected here.
  configureSocket({
    onUnauthenticated: () => {
      useAuthStore().clearState()
      void router.push({ name: 'login' })
    },
  })

  // Swaps in the mock transports under VITE_MOCK_BACKEND=1. Awaited before
  // mount so every consumer of the factories stays synchronous.
  await installBackend()

  app.mount('#app')
}

bootstrap()
