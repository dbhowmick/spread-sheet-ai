<script setup lang="ts">
import { CheckIcon } from '@lucide/vue'

const props = defineProps<{ index: number; selected: boolean }>()
const emit = defineEmits<{ toggle: [value: boolean] }>()
</script>

<!--
  The row header: the 1-based row number, swapped for a selection checkbox on
  hover or once selected. A plain button rather than the shadcn Checkbox,
  since one renders per visible row. F4 hangs the row ContextMenu here.
-->
<template>
  <div class="group/gutter flex h-full items-center justify-center text-xs text-muted-foreground">
    <span :class="['tabular-nums', props.selected ? 'hidden' : 'group-hover/gutter:hidden']">
      {{ props.index + 1 }}
    </span>
    <button
      type="button"
      role="checkbox"
      :aria-checked="props.selected"
      :aria-label="`Select row ${props.index + 1}`"
      :data-state="props.selected ? 'checked' : 'unchecked'"
      :class="[
        'size-4 place-content-center rounded-[4px] border border-input shadow-xs',
        'focus-visible:ring-3 focus-visible:ring-ring/50 focus-visible:outline-none',
        'data-[state=checked]:border-primary data-[state=checked]:bg-primary data-[state=checked]:text-primary-foreground',
        props.selected ? 'grid' : 'hidden group-hover/gutter:grid',
      ]"
      @click="emit('toggle', !props.selected)"
    >
      <CheckIcon v-if="props.selected" class="size-3.5" />
    </button>
  </div>
</template>
