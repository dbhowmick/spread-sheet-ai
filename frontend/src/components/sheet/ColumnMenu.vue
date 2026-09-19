<script setup lang="ts">
import { computed, ref } from 'vue'
import { ChevronDownIcon } from '@lucide/vue'

import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import type { SheetState } from '@/lib/sheet/state'
import type {
  ChangeColumnTypeOp,
  Column,
  ColumnType,
  DeleteColumnOp,
  MoveColumnOp,
  Op,
} from '@/types/contract'

import AddColumnDialog from './AddColumnDialog.vue'
import ConfirmDialog from './ConfirmDialog.vue'

/** The column structure menu (§7.5, UI-6). */
const props = defineProps<{
  column: Column
  view: SheetState
  apply: (op: Op) => Promise<void>
}>()

const emit = defineEmits<{ rename: [] }>()

const typeOptions: { value: ColumnType; label: string }[] = [
  { value: 'text', label: 'Text' },
  { value: 'number', label: 'Number' },
  { value: 'boolean', label: 'Checkbox' },
  { value: 'date', label: 'Date' },
]

const insertAt = ref<number | null>(null)
const confirmingDelete = ref(false)

const index = computed(() => props.view.columns.findIndex((c) => c.id === props.column.id))
const isFirst = computed(() => index.value === 0)
const isLast = computed(() => index.value === props.view.columns.length - 1)

/** The label column can't be deleted or retyped (contract §6). */
const isLabel = computed(() => props.column.is_label)

function changeType(next: unknown) {
  if (typeof next !== 'string' || next === props.column.column_type) return
  const op: ChangeColumnTypeOp = {
    type: 'change_column_type',
    column_id: props.column.id,
    column_type: next as ColumnType,
  }
  void props.apply(op)
}

function moveColumn(delta: number) {
  // `position` is the column's final index *after* the move (contract §6).
  const op: MoveColumnOp = {
    type: 'move_column',
    column_id: props.column.id,
    position: index.value + delta,
  }
  void props.apply(op)
}

function deleteColumn() {
  confirmingDelete.value = false
  const op: DeleteColumnOp = { type: 'delete_column', column_id: props.column.id }
  void props.apply(op)
}
</script>

<template>
  <DropdownMenu>
    <DropdownMenuTrigger
      type="button"
      :aria-label="`Column options for ${column.name}`"
      class="grid size-5 shrink-0 place-content-center rounded-sm text-muted-foreground opacity-0 transition-opacity hover:bg-background hover:text-foreground focus-visible:opacity-100 group-hover/header:opacity-100 data-[state=open]:opacity-100"
    >
      <ChevronDownIcon class="size-3.5" />
    </DropdownMenuTrigger>

    <DropdownMenuContent align="start" class="w-52">
      <DropdownMenuItem @select="emit('rename')">Rename</DropdownMenuItem>

      <DropdownMenuSub v-if="!isLabel">
        <DropdownMenuSubTrigger>Change type</DropdownMenuSubTrigger>
        <DropdownMenuSubContent>
          <DropdownMenuRadioGroup
            :model-value="column.column_type"
            @update:model-value="changeType"
          >
            <DropdownMenuRadioItem
              v-for="option in typeOptions"
              :key="option.value"
              :value="option.value"
            >
              {{ option.label }}
            </DropdownMenuRadioItem>
          </DropdownMenuRadioGroup>
        </DropdownMenuSubContent>
      </DropdownMenuSub>

      <DropdownMenuSeparator />

      <DropdownMenuItem @select="insertAt = index">Insert column left</DropdownMenuItem>
      <DropdownMenuItem @select="insertAt = index + 1">Insert column right</DropdownMenuItem>

      <DropdownMenuSeparator />

      <DropdownMenuItem :disabled="isFirst" @select="moveColumn(-1)">Move left</DropdownMenuItem>
      <DropdownMenuItem :disabled="isLast" @select="moveColumn(1)">Move right</DropdownMenuItem>

      <template v-if="!isLabel">
        <DropdownMenuSeparator />
        <DropdownMenuItem variant="destructive" @select="confirmingDelete = true">
          Delete column
        </DropdownMenuItem>
      </template>
    </DropdownMenuContent>
  </DropdownMenu>

  <AddColumnDialog
    :open="insertAt !== null"
    :view="view"
    :position="insertAt"
    :apply="apply"
    @close="insertAt = null"
  />

  <ConfirmDialog
    :open="confirmingDelete"
    :title="`Delete “${column.name}”?`"
    description="Its values are deleted with it. This can't be undone."
    confirm-label="Delete column"
    @confirm="deleteColumn"
    @close="confirmingDelete = false"
  />
</template>
