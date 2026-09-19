<script setup lang="ts">
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '@/components/ui/empty'

defineProps<{ sheetId: string }>()
</script>

<template>
  <Empty class="h-full">
    <EmptyHeader>
      <EmptyTitle>Sheet</EmptyTitle>
      <EmptyDescription>
        The grid for sheet
        <code class="font-mono text-xs">{{ sheetId }}</code>
        lands in F3.
      </EmptyDescription>
    </EmptyHeader>
  </Empty>
</template>
