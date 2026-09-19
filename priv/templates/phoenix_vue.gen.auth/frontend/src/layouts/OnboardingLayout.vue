<script setup lang="ts">
import { RouterView, useRouter } from 'vue-router'
import { Button } from '@meldui/vue'
import { useAuthStore } from '@/stores/auth'

const router = useRouter()
const authStore = useAuthStore()

async function handleLogout() {
  await authStore.signOut()
  router.push({ name: 'login' })
}
</script>

<template>
  <div class="min-h-screen flex flex-col bg-muted/40">
    <header class="flex items-center justify-end p-4 px-6">
      <Button variant="ghost" size="sm" @click="handleLogout">Sign out</Button>
    </header>
    <main class="flex-1 flex items-center justify-center px-4 py-8">
      <div class="w-full max-w-md">
        <RouterView />
      </div>
    </main>
  </div>
</template>
