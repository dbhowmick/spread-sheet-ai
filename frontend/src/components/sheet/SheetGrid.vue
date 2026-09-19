<script setup lang="ts">
import { computed, provide, ref, toRef, useId, watch } from 'vue'
import { useIntervalFn } from '@vueuse/core'
import { defaultRangeExtractor, useVirtualizer } from '@tanstack/vue-virtual'

import { TooltipProvider } from '@/components/ui/tooltip'
import { useGridNavigation } from '@/composables/useGridNavigation'
import { useSheetTable } from '@/composables/useSheetTable'
import type { Cue } from '@/lib/sheet/consistency'
import { ROW_HEIGHT } from '@/lib/sheet/grid'
import { withIndex } from '@/lib/sheet/navigation'
import type { SheetState } from '@/lib/sheet/state'
import { cn } from '@/lib/utils'
import type { Op } from '@/types/contract'

import { sheetGridKey, sheetNavKey } from './context'
import NewRowInput from './NewRowInput.vue'
import SheetHeaderCell from './SheetHeaderCell.vue'
import SheetRow from './SheetRow.vue'

/**
 * The sheet grid (frontend-plan §7.2, §7.4): one scroll container, a sticky
 * header row, the gutter and label column pinned to the start edge, and
 * virtualized rows. Columns are not virtualized in the POC.
 *
 * The scroll container is the one focusable element — see the note in
 * `useGridNavigation` for why cells must not take focus.
 *
 * Key it by sheet id: the table's width storage is bound at setup.
 */
const props = defineProps<{
  view: SheetState
  cues: Map<string, Cue>
  pendingCells: Set<string>
  apply: (op: Op) => Promise<void>
}>()

const emit = defineEmits<{ 'update:selectedRowIds': [ids: string[]] }>()

const view = toRef(props, 'view')
const gridId = useId()

const {
  rows,
  headers,
  pinnedCount,
  gridTemplate,
  rowSelection,
  navColumnIds,
  frozenWidth,
  columnRect,
} = useSheetTable(view, props.view.id)

const scrollElement = ref<HTMLElement | null>(null)

// Navigation comes first, because the virtualizer's `rangeExtractor` needs
// `activeRowIndex`. It reads the virtualizer back lazily, only when scrolling.
const { nav, activeDescendantId, activeRowIndex, onKeydown, onCopy, onPaste, focusGrid } =
  useGridNavigation({
    view,
    navColumnIds,
    scrollElement,
    virtualizer: () => virtualizer.value,
    frozenWidth,
    columnRect,
    apply: props.apply,
    gridId,
  })

const virtualizer = useVirtualizer(
  computed(() => ({
    count: rows.value.length,
    getScrollElement: () => scrollElement.value,
    estimateSize: () => ROW_HEIGHT,
    overscan: 10,
    getItemKey: (index: number) => rows.value[index]?.id ?? index,
    // Keep the active row mounted wherever it is, so an open editor survives
    // being scrolled away and `aria-activedescendant` never dangles.
    rangeExtractor: (range: Parameters<typeof defaultRangeExtractor>[0]) =>
      withIndex(defaultRangeExtractor(range), activeRowIndex.value),
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
provide(sheetNavKey, nav)

// Row selection lives in the table, but the toolbar's "Delete N rows" sits
// outside the grid, so it is mirrored upwards.
const selectedRowIds = computed(() =>
  Object.keys(rowSelection.value).filter((id) => rowSelection.value[id]),
)
watch(selectedRowIds, (ids) => emit('update:selectedRowIds', ids))

function clearSelection() {
  rowSelection.value = {}
}

defineExpose({ focusGrid, clearSelection })
</script>

<template>
  <TooltipProvider :delay-duration="300">
    <div class="flex h-full min-h-0 flex-col">
      <div
        ref="scrollElement"
        role="grid"
        tabindex="0"
        :aria-rowcount="rows.length + 1"
        :aria-colcount="headers.length"
        :aria-activedescendant="activeDescendantId"
        class="relative min-h-0 flex-1 overflow-auto overscroll-contain outline-none focus-visible:ring-1 focus-visible:ring-ring/50 focus-visible:ring-inset"
        :style="{ '--grid-cols': gridTemplate }"
        @keydown="onKeydown"
        @copy="onCopy"
        @paste="onPaste"
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
            <SheetHeaderCell :header="header" :view="view" :apply="apply" />
          </div>
        </div>

        <div
          role="rowgroup"
          class="relative w-max min-w-full"
          :style="{ height: `${totalSize}px` }"
        >
          <template v-for="item in virtualRows" :key="String(item.key)">
            <SheetRow
              v-if="rows[item.index]"
              :row="rows[item.index]!"
              :start="item.start"
              :grid-id="gridId"
              :view="view"
              :apply="apply"
              :selected-row-ids="selectedRowIds"
              @clear-selection="clearSelection"
            />
          </template>
        </div>

        <p v-if="rows.length === 0" class="sticky start-0 px-4 py-6 text-sm text-muted-foreground">
          No rows yet. Add the first one below.
        </p>
      </div>

      <NewRowInput :view="view" :apply="apply" />
    </div>
  </TooltipProvider>
</template>
