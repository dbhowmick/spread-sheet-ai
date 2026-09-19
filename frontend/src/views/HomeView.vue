<script setup lang="ts">
import { ref } from 'vue'
import { Button, toast } from '@meldui/vue'
import { IconBolt, IconExternalLink } from '@meldui/tabler-vue'

const count = ref(0)

function increment() {
  count.value++
  toast.success(`Clicked ${count.value} time${count.value === 1 ? '' : 's'}`)
}
</script>

<template>
  <main class="min-h-screen flex items-center justify-center p-8">
    <div class="max-w-xl text-center space-y-6">
      <h1 class="font-display text-4xl font-semibold tracking-tight">Welcome to SpreadSheetAi</h1>
      <p class="text-base text-muted-foreground">
        Phoenix 1.8 + Vue 3 + Vite — wired up and ready. Edit
        <code class="font-mono text-sm rounded bg-muted px-1.5 py-0.5">
          frontend/src/views/HomeView.vue
        </code>
        and save to see HMR in action.
      </p>
      <div class="flex items-center justify-center gap-3">
        <Button @click="increment">
          <IconBolt class="size-4" />
          Click me
        </Button>
        <Button as="a" href="/dev/dashboard" variant="outline">
          LiveDashboard
          <IconExternalLink class="size-4" />
        </Button>
      </div>
    </div>
  </main>
</template>
