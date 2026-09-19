<script setup lang="ts">
import { onMounted } from 'vue'
import { RouterView } from 'vue-router'

import NavRail from '@/components/app/NavRail.vue'
import { ensureConnected } from '@/lib/socket'

onMounted(() => {
  // `connect()` is lazy in lib/socket.ts, but the shell only ever mounts for
  // an authenticated user and every route under it wants the socket within a
  // second. `ensureConnected()` is idempotent, so the lazy join path still
  // works for anything that joins before this runs.
  void ensureConnected()
})
</script>

<template>
  <div class="flex h-screen overflow-hidden bg-background">
    <NavRail />
    <main class="flex min-w-0 flex-1 flex-col overflow-hidden">
      <RouterView />
    </main>
  </div>
</template>
