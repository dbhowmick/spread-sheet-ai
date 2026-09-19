<script setup lang="ts">
import { computed, ref } from 'vue'

import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuTrigger,
} from '@/components/ui/context-menu'
import type { SheetState } from '@/lib/sheet/state'
import type { AddRowsOp, DeleteRowsOp, MoveRowOp, Op } from '@/types/contract'

import ConfirmDialog from './ConfirmDialog.vue'
import NewRowDialog from './NewRowDialog.vue'

/**
 * The row structure menu (§7.5, UI-6): insert, move, delete. The whole row is
 * the trigger, so right-clicking the gutter or any cell opens it.
 */
const props = defineProps<{
  rowId: string
  index: number
  view: SheetState
  apply: (op: Op) => Promise<void>
  selectedRowIds: string[]
}>()

const emit = defineEmits<{ clearSelection: [] }>()

const insertAt = ref<number | null>(null)
const confirming = ref<'row' | 'selection' | null>(null)

const label = computed(() => {
  const value = props.view.rows[props.index]?.cells[props.view.labelColumnId]
  return typeof value === 'string' ? value : `Row ${props.index + 1}`
})

const selectedCount = computed(() => props.selectedRowIds.length)
const isFirst = computed(() => props.index === 0)
const isLast = computed(() => props.index === props.view.rows.length - 1)

function addRow(labelText: string) {
  const position = insertAt.value
  insertAt.value = null
  const op: AddRowsOp = {
    type: 'add_rows',
    // The label cell is required, or the server rejects with `label_required`.
    rows: [{ cells: { [props.view.labelColumnId]: labelText } }],
    ...(position === null ? {} : { position }),
  }
  void props.apply(op)
}

function moveRow(delta: number) {
  // `position` is the row's final index *after* the move (contract §6).
  const op: MoveRowOp = { type: 'move_row', row_id: props.rowId, position: props.index + delta }
  void props.apply(op)
}

function deleteRows(rowIds: string[]) {
  const op: DeleteRowsOp = { type: 'delete_rows', row_ids: rowIds }
  void props.apply(op)
  emit('clearSelection')
}

function confirmDelete() {
  const target = confirming.value
  confirming.value = null
  if (target === 'selection') deleteRows(props.selectedRowIds)
  else if (target === 'row') deleteRows([props.rowId])
}
</script>

<template>
  <ContextMenu>
    <ContextMenuTrigger as-child>
      <slot />
    </ContextMenuTrigger>

    <ContextMenuContent class="w-56">
      <ContextMenuItem @select="insertAt = index">Insert row above</ContextMenuItem>
      <ContextMenuItem @select="insertAt = index + 1">Insert row below</ContextMenuItem>

      <ContextMenuSeparator />

      <ContextMenuItem :disabled="isFirst" @select="moveRow(-1)">Move up</ContextMenuItem>
      <ContextMenuItem :disabled="isLast" @select="moveRow(1)">Move down</ContextMenuItem>

      <ContextMenuSeparator />

      <ContextMenuItem variant="destructive" @select="confirming = 'row'">
        Delete row
      </ContextMenuItem>
      <ContextMenuItem
        v-if="selectedCount > 0"
        variant="destructive"
        @select="confirming = 'selection'"
      >
        Delete {{ selectedCount }} selected {{ selectedCount === 1 ? 'row' : 'rows' }}
      </ContextMenuItem>
    </ContextMenuContent>
  </ContextMenu>

  <NewRowDialog :open="insertAt !== null" :view="view" @submit="addRow" @close="insertAt = null" />

  <ConfirmDialog
    :open="confirming !== null"
    :title="confirming === 'selection' ? `Delete ${selectedCount} rows?` : `Delete “${label}”?`"
    description="This can't be undone."
    confirm-label="Delete"
    @confirm="confirmDelete"
    @close="confirming = null"
  />
</template>
