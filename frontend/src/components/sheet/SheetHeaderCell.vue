<script setup lang="ts">
import { computed } from 'vue'
import { CalendarIcon, HashIcon, SquareCheckIcon, TagIcon, TypeIcon } from '@lucide/vue'
import type { Header } from '@tanstack/vue-table'

import type { SheetFeatures } from '@/composables/useSheetTable'
import { cn } from '@/lib/utils'
import type { ColumnType, Row } from '@/types/contract'

const props = defineProps<{ header: Header<SheetFeatures, Row, unknown> }>()

const typeIcons: Record<ColumnType, typeof TypeIcon> = {
  text: TypeIcon,
  number: HashIcon,
  boolean: SquareCheckIcon,
  date: CalendarIcon,
}

const column = computed(() => props.header.column.columnDef.meta?.column ?? null)
const icon = computed(() => {
  const current = column.value
  if (!current) return null
  return current.is_label ? TagIcon : typeIcons[current.column_type]
})

function startResize(event: MouseEvent | TouchEvent) {
  props.header.getResizeHandler()(event)
}
</script>

<!-- F4 adds the column DropdownMenu (rename, type, insert, move, delete). -->
<template>
  <div
    class="relative flex h-full min-w-0 items-center gap-1.5 px-2 text-xs font-medium text-muted-foreground"
    :title="
      column ? `${column.name} (${column.is_label ? 'row label' : column.column_type})` : undefined
    "
  >
    <component :is="icon" v-if="icon" class="size-3.5 shrink-0" aria-hidden="true" />
    <span v-if="column" class="truncate text-foreground">{{ column.name }}</span>

    <div
      v-if="header.column.getCanResize()"
      role="separator"
      aria-orientation="vertical"
      :aria-label="column ? `Resize ${column.name}` : 'Resize column'"
      :class="
        cn(
          'absolute inset-y-0 -end-1 z-10 w-2 cursor-col-resize touch-none select-none',
          'after:absolute after:inset-y-1 after:start-1/2 after:w-0.5 after:-translate-x-1/2 after:rounded-full',
          'hover:after:bg-ring',
          header.column.getIsResizing() && 'after:bg-primary',
        )
      "
      @mousedown="startResize"
      @touchstart.passive="startResize"
      @dblclick="header.column.resetSize()"
    />
  </div>
</template>
