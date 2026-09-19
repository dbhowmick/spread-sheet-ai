import './assets/main.css'

import { createApp } from 'vue'
import { createPinia } from 'pinia'

import App from './App.vue'
import router from './router'
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
  app.mount('#app')
}

bootstrap()
