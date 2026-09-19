<script setup lang="ts">
import { computed, ref } from 'vue'
import { CalendarDate, parseDate } from '@internationalized/date'
import type { DateValue } from 'reka-ui'
import { CalendarIcon } from '@lucide/vue'

import { Calendar } from '@/components/ui/calendar'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import type { Move } from '@/lib/sheet/navigation'
import type { CellValue, Column } from '@/types/contract'

import CellEditor from './CellEditor.vue'

/**
 * A date cell: the same typed ISO input as every other editor, plus a picker.
 * Typing stays the fast path for bulk entry, and because `formatValue` emits
 * `YYYY-MM-DD` a copied date pastes straight back.
 */
const props = defineProps<{
  column: Column
  value: CellValue
  initialInput?: string | null
  error?: string | null
}>()

const emit = defineEmits<{ commit: [input: string, next: Move | null]; cancel: [] }>()

const open = ref(false)

/**
 * `@internationalized/date` only appears at this boundary. `new Date(iso)` is
 * not an option: it silently rolls `2026-02-30` over into March, where both
 * the server and `values.ts` reject it.
 */
const selected = computed<DateValue | undefined>(() => {
  if (typeof props.value !== 'string') return undefined
  try {
    return parseDate(props.value)
  } catch {
    return undefined
  }
})

function pick(value: DateValue | undefined) {
  if (!value) return
  open.value = false
  const date = new CalendarDate(value.year, value.month, value.day)
  emit('commit', date.toString(), null)
}
</script>

<template>
  <CellEditor
    :column="column"
    :value="value"
    :initial-input="initialInput"
    :error="error"
    @commit="(input, next) => emit('commit', input, next)"
    @cancel="emit('cancel')"
  >
    <template #trailing>
      <Popover v-model:open="open">
        <PopoverTrigger
          type="button"
          aria-label="Pick a date"
          class="absolute end-1 z-[5] grid size-5 place-content-center rounded-sm text-muted-foreground hover:bg-accent hover:text-foreground"
        >
          <CalendarIcon class="size-3.5" />
        </PopoverTrigger>
        <PopoverContent class="w-auto p-0" align="end">
          <Calendar :model-value="selected" @update:model-value="pick" />
        </PopoverContent>
      </Popover>
    </template>
  </CellEditor>
</template>
