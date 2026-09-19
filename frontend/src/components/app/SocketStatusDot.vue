<script setup lang="ts">
import { computed } from 'vue'

import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import type { ConnectionState } from '@/lib/socket'
import { useSocketStatus } from '@/composables/useSocketStatus'
import { cn } from '@/lib/utils'

/**
 * Dev-only socket indicator. Lives in the nav rail because the layout has no
 * header row. F7 grows this into the user-facing reconnect indicator.
 */
const status = useSocketStatus()

const COLORS: Record<ConnectionState, string> = {
  idle: 'bg-muted-foreground/40',
  connecting: 'bg-amber-500 animate-pulse',
  open: 'bg-emerald-500',
  closed: 'bg-destructive',
}

const LABELS: Record<ConnectionState, string> = {
  idle: 'Socket idle',
  connecting: 'Socket connecting…',
  open: 'Socket connected',
  closed: 'Socket closed',
}

const dotClass = computed(() => COLORS[status.value])
</script>

<template>
  <Tooltip>
    <TooltipTrigger as-child>
      <span class="flex size-10 items-center justify-center" :aria-label="LABELS[status]">
        <span :class="cn('size-2 rounded-full', dotClass)" />
      </span>
    </TooltipTrigger>
    <TooltipContent side="right">{{ LABELS[status] }}</TooltipContent>
  </Tooltip>
</template>
