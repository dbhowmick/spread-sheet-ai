<script setup lang="ts">
import { computed, ref } from 'vue'
import { PlusIcon, TableIcon, XIcon } from '@lucide/vue'

import OpenSheetDialog from '@/components/workspace/OpenSheetDialog.vue'
import SheetPane from '@/components/workspace/SheetPane.vue'
import { Button } from '@/components/ui/button'
import {
  Empty,
  EmptyContent,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from '@/components/ui/empty'
import { cn } from '@/lib/utils'
import { useSheetsStore } from '@/stores/sheets'
import type { LinkedSheet, SheetId } from '@/types/contract'

/**
 * The sheets open beside the chat, one per tab (UI-3). Not browser tabs.
 *
 * Every pane stays **mounted** and is hidden with `v-show`, so switching tabs
 * keeps each grid's scroll position and active cell and does not re-join its
 * channel (frontend-plan §4).
 */
const props = defineProps<{
  openIds: SheetId[]
  activeId: SheetId | null
  linkedSheets: LinkedSheet[]
}>()

const emit = defineEmits<{
  (e: 'activate', sheetId: SheetId): void
  (e: 'close', sheetId: SheetId): void
  (e: 'pick', sheetId: SheetId): void
}>()

const sheetsStore = useSheetsStore()
const picking = ref(false)

/**
 * A tab's label. The store has it once the channel has joined; until then the
 * linked-sheet list usually does, and only a sheet opened from a fresh reload
 * falls back to the placeholder.
 */
const names = computed(() => {
  const byId = new Map<SheetId, string>()
  for (const link of props.linkedSheets) byId.set(link.sheet.id, link.sheet.name)
  return (sheetId: SheetId) =>
    sheetsStore.entryOf(sheetId)?.confirmed.name || byId.get(sheetId) || 'Sheet'
})
</script>

<template>
  <div class="flex h-full min-h-0 flex-col">
    <div class="flex h-11 shrink-0 items-center gap-1 overflow-x-auto border-b px-2">
      <div
        v-for="sheetId in openIds"
        :key="sheetId"
        :class="
          cn(
            'group flex h-8 shrink-0 items-center gap-1 rounded-md ps-3 pe-1 text-sm transition-colors',
            sheetId === activeId
              ? 'bg-accent text-accent-foreground'
              : 'text-muted-foreground hover:bg-accent/50',
          )
        "
      >
        <button
          type="button"
          class="max-w-44 truncate focus-visible:outline-none"
          :aria-current="sheetId === activeId ? 'page' : undefined"
          @click="emit('activate', sheetId)"
        >
          {{ names(sheetId) }}
        </button>
        <button
          type="button"
          class="rounded-sm p-0.5 opacity-0 transition-opacity hover:bg-background/60 focus-visible:opacity-100 group-hover:opacity-100"
          :aria-label="`Close ${names(sheetId)}`"
          @click="emit('close', sheetId)"
        >
          <XIcon class="size-3.5" />
        </button>
      </div>

      <Button
        size="icon"
        variant="ghost"
        class="size-8 shrink-0"
        aria-label="Open a sheet"
        @click="picking = true"
      >
        <PlusIcon class="size-4" />
      </Button>
    </div>

    <div class="relative min-h-0 flex-1">
      <Empty v-if="openIds.length === 0" class="h-full">
        <EmptyHeader>
          <EmptyMedia variant="icon"><TableIcon /></EmptyMedia>
          <EmptyTitle>No sheets open</EmptyTitle>
          <EmptyDescription>
            Ask the assistant to build one, or open an existing sheet.
          </EmptyDescription>
        </EmptyHeader>
        <EmptyContent>
          <Button variant="outline" @click="picking = true">
            <PlusIcon />
            Open a sheet
          </Button>
        </EmptyContent>
      </Empty>

      <!--
        `v-show`, not `v-if`: an unmounted pane would drop its channel hold and
        lose the grid's scroll position and active cell on every tab switch.
      -->
      <div
        v-for="sheetId in openIds"
        v-show="sheetId === activeId"
        :key="sheetId"
        class="absolute inset-0"
      >
        <SheetPane :sheet-id="sheetId" />
      </div>
    </div>

    <OpenSheetDialog
      v-model:open="picking"
      :linked-sheets="linkedSheets"
      @pick="emit('pick', $event)"
    />
  </div>
</template>
