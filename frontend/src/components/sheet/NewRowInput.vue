<script setup lang="ts">
import { computed, ref } from 'vue'
import { PlusIcon } from '@lucide/vue'

import type { SheetState } from '@/lib/sheet/state'
import { validateLabel } from '@/lib/sheet/values'
import type { AddRowsOp, Op } from '@/types/contract'

/**
 * The row under the grid (§7.2): type a label, press Enter, and it is appended.
 * The input keeps focus so a list can be typed straight through.
 */
const props = defineProps<{ view: SheetState; apply: (op: Op) => Promise<void> }>()

const label = ref('')
const error = ref<string | null>(null)

const placeholder = computed(() => {
  const name = props.view.columnsById[props.view.labelColumnId]?.name ?? 'row'
  return `Add a ${name.toLowerCase()}…`
})

function submit() {
  if (label.value.trim() === '') return

  const checked = validateLabel(label.value, props.view)
  if (!checked.ok) {
    error.value = checked.message
    return
  }

  const op: AddRowsOp = {
    type: 'add_rows',
    rows: [{ cells: { [props.view.labelColumnId]: checked.value } }],
  }
  void props.apply(op)

  reset()
}

function reset() {
  label.value = ''
  error.value = null
}
</script>

<template>
  <div class="relative flex h-9 shrink-0 items-center gap-2 border-t bg-muted/40 px-3">
    <PlusIcon class="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
    <input
      v-model="label"
      type="text"
      :placeholder="placeholder"
      aria-label="Add a row"
      :aria-invalid="!!error"
      autocomplete="off"
      class="h-full w-64 bg-transparent text-sm outline-none placeholder:text-muted-foreground"
      @input="error = null"
      @keydown.enter.prevent="submit"
      @keydown.escape.prevent="reset"
    />
    <p v-if="error" role="alert" class="text-xs text-destructive">{{ error }}</p>
  </div>
</template>
