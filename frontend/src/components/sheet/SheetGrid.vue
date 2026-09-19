<script setup lang="ts">
import { computed, provide, ref, toRef } from 'vue'
import { useIntervalFn } from '@vueuse/core'
import { useVirtualizer } from '@tanstack/vue-virtual'

import { TooltipProvider } from '@/components/ui/tooltip'
import { useSheetTable } from '@/composables/useSheetTable'
import type { Cue } from '@/lib/sheet/consistency'
import { ROW_HEIGHT } from '@/lib/sheet/grid'
import type { SheetState } from '@/lib/sheet/state'
import { cn } from '@/lib/utils'

import { sheetGridKey } from './context'
import SheetHeaderCell from './SheetHeaderCell.vue'
import SheetRow from './SheetRow.vue'

/**
 * The sheet grid (frontend-plan §7.2): one scroll container, a sticky header
 * row, the gutter and label column pinned to the start edge, and virtualized
 * rows. Columns are not virtualized in the POC.
 *
 * Key it by sheet id: the table's width storage is bound at setup.
 */
const props = defineProps<{
  view: SheetState
  cues: Map<string, Cue>
  pendingCells: Set<string>
}>()

const view = toRef(props, 'view')
const { rows, headers, pinnedCount, gridTemplate } = useSheetTable(view, props.view.id)

const scrollElement = ref<HTMLElement | null>(null)

const virtualizer = useVirtualizer(
  computed(() => ({
    count: rows.value.length,
    getScrollElement: () => scrollElement.value,
    estimateSize: () => ROW_HEIGHT,
    overscan: 10,
    getItemKey: (index: number) => rows.value[index]?.id ?? index,
  })),
)
const virtualRows = computed(() => virtualizer.value.getVirtualItems())
const totalSize = computed(() => virtualizer.value.getTotalSize())

// One coarse clock for the whole grid, rather than a timer per cue marker.
const now = ref(Date.now())
useIntervalFn(() => {
  now.value = Date.now()
}, 5000)

provide(sheetGridKey, {
  cues: toRef(props, 'cues'),
  pendingCells: toRef(props, 'pendingCells'),
  now,
})
</script>

<template>
  <TooltipProvider :delay-duration="300">
    <div
      ref="scrollElement"
      role="grid"
      :aria-rowcount="rows.length + 1"
      :aria-colcount="headers.length"
      class="relative h-full overflow-auto overscroll-contain"
      :style="{ '--grid-cols': gridTemplate }"
    >
      <div
        role="row"
        aria-rowindex="1"
        class="sticky top-0 z-[2] grid h-8 w-max min-w-full grid-cols-(--grid-cols) border-b bg-muted"
      >
        <div
          v-for="(header, i) in headers"
          :key="header.id"
          role="columnheader"
          :class="
            cn(
              'min-w-0 border-e bg-muted',
              i < pinnedCount && 'sticky z-[3]',
              i === pinnedCount - 1 && 'shadow-[4px_0_6px_-4px_rgb(0_0_0/0.15)]',
            )
          "
          :style="
            i < pinnedCount ? { insetInlineStart: `${header.getStart('start')}px` } : undefined
          "
        >
          <SheetHeaderCell :header="header" />
        </div>
      </div>

      <div role="rowgroup" class="relative w-max min-w-full" :style="{ height: `${totalSize}px` }">
        <template v-for="item in virtualRows" :key="String(item.key)">
          <SheetRow v-if="rows[item.index]" :row="rows[item.index]!" :start="item.start" />
        </template>
      </div>

      <p v-if="rows.length === 0" class="sticky start-0 px-4 py-6 text-sm text-muted-foreground">
        No rows yet.
      </p>
    </div>
  </TooltipProvider>
</template>
