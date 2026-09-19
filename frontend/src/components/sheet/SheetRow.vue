<script setup lang="ts">
import { computed } from 'vue'
import { FlexRender, type Row as TableRow } from '@tanstack/vue-table'

import type { SheetFeatures } from '@/composables/useSheetTable'
import { cellDomId } from '@/lib/sheet/navigation'
import type { SheetState } from '@/lib/sheet/state'
import { cn } from '@/lib/utils'
import type { Op, Row } from '@/types/contract'

import RowMenu from './RowMenu.vue'

const props = defineProps<{
  row: TableRow<SheetFeatures, Row>
  /** Offset of the virtual row from the top of the body. */
  start: number
  gridId: string
  view: SheetState
  apply: (op: Op) => Promise<void>
  selectedRowIds: string[]
}>()

const emit = defineEmits<{ clearSelection: [] }>()

// Pinned cells first, matching the header order and `--grid-cols`.
const cells = computed(() => [
  ...props.row.getStartVisibleCells(),
  ...props.row.getCenterVisibleCells(),
])
const pinnedCount = computed(() => props.row.getStartVisibleCells().length)
const selected = computed(() => props.row.getIsSelected())
</script>

<template>
  <!--
    The whole row is the context-menu trigger, so right-clicking the gutter or
    any cell opens it (§7.5). The menu content only renders while open.
  -->
  <RowMenu
    :row-id="row.id"
    :index="row.index"
    :view="view"
    :apply="apply"
    :selected-row-ids="selectedRowIds"
    @clear-selection="emit('clearSelection')"
  >
    <div
      role="row"
      :aria-rowindex="row.index + 2"
      :aria-selected="selected || undefined"
      class="group/row absolute top-0 start-0 grid h-8 w-max min-w-full grid-cols-(--grid-cols) border-b"
      :style="{ transform: `translateY(${start}px)` }"
    >
      <div
        v-for="(cell, i) in cells"
        :id="cellDomId(gridId, row.id, cell.column.id)"
        :key="cell.id"
        role="gridcell"
        :class="
          cn(
            'min-w-0 border-e',
            i < pinnedCount
              ? 'sticky z-[1] bg-background group-hover/row:bg-muted'
              : 'group-hover/row:bg-muted/50',
            i === pinnedCount - 1 && 'shadow-[4px_0_6px_-4px_rgb(0_0_0/0.15)]',
            selected && 'bg-accent',
          )
        "
        :style="
          i < pinnedCount ? { insetInlineStart: `${cell.column.getStart('start')}px` } : undefined
        "
      >
        <FlexRender :cell="cell" />
      </div>
    </div>
  </RowMenu>
</template>
