<script setup lang="ts">
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '@/components/ui/empty'

defineProps<{ conversationId: string }>()
</script>

<template>
  <Empty class="h-full">
    <EmptyHeader>
      <EmptyTitle>Workspace</EmptyTitle>
      <EmptyDescription>
        Chat and tabbed sheets for conversation
        <code class="font-mono text-xs">{{ conversationId }}</code>
        land in F5.
      </EmptyDescription>
    </EmptyHeader>
  </Empty>
</template>
