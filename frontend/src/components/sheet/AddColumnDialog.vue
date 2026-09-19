<script setup lang="ts">
import { ref, watch } from 'vue'

import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import type { SheetState } from '@/lib/sheet/state'
import { normalizeKey } from '@/lib/sheet/values'
import type { AddColumnOp, ColumnType, Op } from '@/types/contract'

/**
 * Adds a column, either at the end (from the toolbar) or beside another one
 * (from the column menu). `position` is the slot the new column lands in,
 * `0..length` (contract §6).
 */
const props = defineProps<{
  open: boolean
  view: SheetState
  /** `null` appends. */
  position: number | null
  apply: (op: Op) => Promise<void>
}>()

const emit = defineEmits<{ close: [] }>()

const typeOptions: { value: ColumnType; label: string }[] = [
  { value: 'text', label: 'Text' },
  { value: 'number', label: 'Number' },
  { value: 'boolean', label: 'Checkbox' },
  { value: 'date', label: 'Date' },
]

const name = ref('')
const columnType = ref<ColumnType>('text')
const error = ref<string | null>(null)

watch(
  () => props.open,
  (open) => {
    if (!open) return
    name.value = ''
    columnType.value = 'text'
    error.value = null
  },
)

function submit() {
  const trimmed = name.value.trim()
  if (trimmed === '') {
    error.value = 'A column needs a name.'
    return
  }

  // The server checks this too; checking here keeps the round-trip for real
  // errors, as `CreateSheetDialog` does.
  const key = normalizeKey(trimmed)
  if (props.view.columns.some((column) => normalizeKey(column.name) === key)) {
    error.value = `"${trimmed}" is already used. Column names must be unique.`
    return
  }

  const op: AddColumnOp = {
    type: 'add_column',
    name: trimmed,
    column_type: columnType.value,
    ...(props.position === null ? {} : { position: props.position }),
  }
  void props.apply(op)
  emit('close')
}
</script>

<template>
  <Dialog :open="open" @update:open="(next) => !next && emit('close')">
    <DialogContent class="sm:max-w-sm">
      <form class="grid gap-5" @submit.prevent="submit">
        <DialogHeader>
          <DialogTitle>New column</DialogTitle>
          <DialogDescription>
            Cells hold values of the column's type, or are left empty.
          </DialogDescription>
        </DialogHeader>

        <div class="grid gap-1.5">
          <Label for="add-column-name">Name</Label>
          <Input
            id="add-column-name"
            v-model="name"
            autocomplete="off"
            autofocus
            :aria-invalid="!!error"
            :aria-describedby="error ? 'add-column-error' : undefined"
            @input="error = null"
          />
          <p v-if="error" id="add-column-error" class="text-sm text-destructive">{{ error }}</p>
        </div>

        <div class="grid gap-1.5">
          <Label for="add-column-type">Type</Label>
          <Select v-model="columnType">
            <SelectTrigger id="add-column-type" class="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem v-for="option in typeOptions" :key="option.value" :value="option.value">
                {{ option.label }}
              </SelectItem>
            </SelectContent>
          </Select>
        </div>

        <DialogFooter>
          <Button type="button" variant="ghost" @click="emit('close')">Cancel</Button>
          <Button type="submit">Add column</Button>
        </DialogFooter>
      </form>
    </DialogContent>
  </Dialog>
</template>
