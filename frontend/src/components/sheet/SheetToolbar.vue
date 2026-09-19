<script setup lang="ts">
import { computed, ref } from 'vue'
import { RouterLink } from 'vue-router'
import { useIntervalFn } from '@vueuse/core'
import { ChevronLeftIcon, Loader2Icon } from '@lucide/vue'

import ParticipantAvatars from '@/components/app/ParticipantAvatars.vue'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { actorName } from '@/lib/people'
import type { Cue, SheetStatus } from '@/lib/sheet/consistency'
import type { SheetState } from '@/lib/sheet/state'
import { timeAgo } from '@/lib/time'
import type { UserRef } from '@/types/contract'

/** Read-only in F3; F4 adds inline rename and "Add column". */
const props = defineProps<{
  view: SheetState
  status: SheetStatus
  participants: UserRef[]
  lastChange: Cue | null
}>()

const now = ref(Date.now())
useIntervalFn(() => {
  now.value = Date.now()
}, 5000)

const updated = computed(() => {
  const change = props.lastChange
  if (!change) return null
  return `Updated by ${actorName(change.actor)} · ${timeAgo(change.at, now.value)}`
})

const size = computed(() => `${props.view.rows.length} rows · ${props.view.columns.length} columns`)
</script>

<template>
  <header class="flex h-14 shrink-0 items-center gap-3 border-b px-3">
    <Button variant="ghost" size="icon-sm" as-child>
      <RouterLink :to="{ name: 'sheets' }" aria-label="All sheets">
        <ChevronLeftIcon />
      </RouterLink>
    </Button>

    <div class="min-w-0">
      <h1 class="truncate text-sm font-semibold">{{ view.name }}</h1>
      <p class="truncate text-xs text-muted-foreground">
        {{ size }}<template v-if="updated"> · {{ updated }}</template>
      </p>
    </div>

    <Badge v-if="status === 'resyncing'" variant="secondary" class="shrink-0">
      <Loader2Icon class="animate-spin" />
      Syncing
    </Badge>

    <div class="ms-auto flex items-center gap-2">
      <ParticipantAvatars :users="participants" />
    </div>
  </header>
</template>
