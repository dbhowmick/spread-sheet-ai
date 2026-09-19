<script setup lang="ts">
import { computed, nextTick, ref, useTemplateRef } from 'vue'
import { CalendarIcon, HashIcon, SquareCheckIcon, TagIcon, TypeIcon } from '@lucide/vue'
import type { Header } from '@tanstack/vue-table'

import type { SheetFeatures } from '@/composables/useSheetTable'
import type { SheetState } from '@/lib/sheet/state'
import { normalizeKey } from '@/lib/sheet/values'
import { cn } from '@/lib/utils'
import type { ColumnType, Op, RenameColumnOp, Row } from '@/types/contract'

import ColumnMenu from './ColumnMenu.vue'

const props = defineProps<{
  header: Header<SheetFeatures, Row, unknown>
  view: SheetState
  apply: (op: Op) => Promise<void>
}>()

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

const renaming = ref(false)
const draft = ref('')
const renameInput = useTemplateRef<HTMLInputElement>('renameInput')

async function startRename() {
  const current = column.value
  if (!current) return
  draft.value = current.name
  renaming.value = true
  await nextTick()
  renameInput.value?.select()
}

function commitRename() {
  const current = column.value
  if (!current || !renaming.value) return
  renaming.value = false

  const trimmed = draft.value.trim()
  // A no-op or a blank name is dropped rather than sent: the server would
  // reject a blank with `invalid_op`, and an unchanged name still bumps the
  // version for everyone.
  if (trimmed === '' || trimmed === current.name) return

  const key = normalizeKey(trimmed)
  if (
    props.view.columns.some((other) => other.id !== current.id && normalizeKey(other.name) === key)
  )
    return

  const op: RenameColumnOp = { type: 'rename_column', column_id: current.id, name: trimmed }
  void props.apply(op)
}

function startResize(event: MouseEvent | TouchEvent) {
  props.header.getResizeHandler()(event)
}
</script>

<template>
  <div
    class="group/header relative flex h-full min-w-0 items-center gap-1.5 px-2 text-xs font-medium text-muted-foreground"
    :title="
      column ? `${column.name} (${column.is_label ? 'row label' : column.column_type})` : undefined
    "
  >
    <component :is="icon" v-if="icon" class="size-3.5 shrink-0" aria-hidden="true" />

    <input
      v-if="renaming && column"
      ref="renameInput"
      v-model="draft"
      type="text"
      :aria-label="`Rename ${column.name}`"
      class="min-w-0 flex-1 rounded-sm bg-background px-1 text-xs text-foreground outline-none ring-2 ring-inset ring-primary"
      @keydown.enter.prevent="commitRename"
      @keydown.escape.prevent="renaming = false"
      @keydown.stop
      @blur="commitRename"
    />
    <span v-else-if="column" class="flex-1 truncate text-foreground">{{ column.name }}</span>

    <ColumnMenu
      v-if="column && !renaming"
      :column="column"
      :view="view"
      :apply="apply"
      @rename="startRename"
    />

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
