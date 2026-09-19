<script setup lang="ts">
import { RouterView } from 'vue-router'
</script>

<template>
  <div class="min-h-screen flex items-center justify-center bg-muted/40 px-4 py-12">
    <div class="w-full max-w-md">
      <RouterView />
    </div>
  </div>
</template>
