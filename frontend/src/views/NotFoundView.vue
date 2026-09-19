<script setup lang="ts">
import { useRouter } from 'vue-router'
import { ArrowLeftIcon } from '@lucide/vue'
import { Button } from '@/components/ui/button'

const router = useRouter()
</script>

<template>
  <main class="min-h-screen flex items-center justify-center p-8">
    <div class="max-w-md text-center space-y-4">
      <p class="text-sm font-medium text-muted-foreground">404</p>
      <h1 class="font-display text-2xl font-semibold tracking-tight">Page not found</h1>
      <p class="text-base text-muted-foreground">The page you're looking for doesn't exist.</p>
      <Button @click="router.push('/')">
        <ArrowLeftIcon class="size-4" />
        Go home
      </Button>
    </div>
  </main>
</template>
