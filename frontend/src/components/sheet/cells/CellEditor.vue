<script setup lang="ts">
import { onMounted, ref, useTemplateRef } from 'vue'

import { editorIntent, type Move } from '@/lib/sheet/navigation'
import { formatValue } from '@/lib/sheet/values'
import { cn } from '@/lib/utils'
import type { CellValue, Column } from '@/types/contract'

/**
 * The editor for every typed-text cell: text, number and the row label. They
 * differ only in `inputmode` and alignment — parsing and the label uniqueness
 * check happen once, in `useGridNavigation.commit`, so that paste and typing
 * take the same path.
 *
 * A bare `<input>` rather than the shadcn `Input`: one has to fit exactly
 * inside a 32px row, and the shadcn control brings its own height, border and
 * focus ring. Same reasoning as `BooleanDisplay`.
 */
const props = defineProps<{
  column: Column
  value: CellValue
  /** The character that started the edit, when it started by typing. */
  initialInput?: string | null
  /** A rejected value: shown inline while the editor stays open (§7.3). */
  error?: string | null
}>()

const emit = defineEmits<{ commit: [input: string, next: Move | null]; cancel: [] }>()

// Deliberately not a computed and with no watcher on `value`: a remote change
// to the cell being edited must leave the user's text alone (§7.4).
const text = ref(props.initialInput ?? formatValue(props.column.column_type, props.value))

const input = useTemplateRef<HTMLInputElement>('input')

onMounted(() => {
  const el = input.value
  if (!el) return
  el.focus()
  // Typing a character replaces the value, so the caret goes after it. Enter
  // or F2 opens the existing value ready to be replaced wholesale.
  if (props.initialInput === null || props.initialInput === undefined) el.select()
  else el.setSelectionRange(el.value.length, el.value.length)
})

/**
 * The editor swallows every key while it is open — arrows have to move the
 * caret, not the active cell.
 */
function onKeydown(event: KeyboardEvent) {
  const intent = editorIntent(event)
  if (intent.kind === 'ignore') return
  event.preventDefault()
  if (intent.kind === 'cancel') emit('cancel')
  else emit('commit', text.value, intent.next)
}

const numeric = props.column.column_type === 'number'
</script>

<template>
  <div class="absolute inset-0 z-[4] flex items-center">
    <input
      ref="input"
      v-model="text"
      type="text"
      :inputmode="numeric ? 'decimal' : undefined"
      :aria-label="`${column.name} value`"
      :aria-invalid="!!error"
      :class="
        cn(
          'h-full w-full min-w-full rounded-none border-0 bg-background px-2 text-sm outline-none',
          'ring-2 ring-inset ring-primary',
          numeric && 'text-end tabular-nums',
          error && 'ring-destructive',
        )
      "
      @keydown.stop="onKeydown"
    />

    <!-- `DateEditor` hangs its calendar button here. -->
    <slot name="trailing" />

    <p
      v-if="error"
      role="alert"
      class="absolute top-full start-0 z-[5] mt-0.5 w-max max-w-64 rounded-md bg-destructive px-2 py-1 text-xs text-destructive-foreground shadow-md"
    >
      {{ error }}
    </p>
  </div>
</template>
