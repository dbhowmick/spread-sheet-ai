<script setup lang="ts">
import { RouterView } from 'vue-router'
import { Toaster } from '@meldui/vue'
</script>

<template>
  <RouterView />
  <Toaster position="bottom-right" />
</template>
