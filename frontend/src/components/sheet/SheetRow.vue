<script setup lang="ts">
import { computed } from 'vue'
import { FlexRender, type Row as TableRow } from '@tanstack/vue-table'

import type { SheetFeatures } from '@/composables/useSheetTable'
import { cn } from '@/lib/utils'
import type { Row } from '@/types/contract'

const props = defineProps<{
  row: TableRow<SheetFeatures, Row>
  /** Offset of the virtual row from the top of the body. */
  start: number
}>()

// Pinned cells first, matching the header order and `--grid-cols`.
const cells = computed(() => [
  ...props.row.getStartVisibleCells(),
  ...props.row.getCenterVisibleCells(),
])
const pinnedCount = computed(() => props.row.getStartVisibleCells().length)
const selected = computed(() => props.row.getIsSelected())
</script>

<template>
  <div
    role="row"
    :aria-rowindex="row.index + 2"
    :aria-selected="selected || undefined"
    class="group/row absolute top-0 start-0 grid h-8 w-max min-w-full grid-cols-(--grid-cols) border-b"
    :style="{ transform: `translateY(${start}px)` }"
  >
    <div
      v-for="(cell, i) in cells"
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
</template>
