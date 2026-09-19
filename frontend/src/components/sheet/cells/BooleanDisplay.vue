<script setup lang="ts">
import { CheckIcon } from '@lucide/vue'

import type { CellValue, Column } from '@/types/contract'

defineProps<{ value: CellValue; column: Column }>()
</script>

<!--
  A static look-alike of the shadcn Checkbox rather than the component itself:
  a visible screen can hold hundreds of boolean cells, and each reka-ui
  checkbox is several components deep. F4 toggles the value from the cell.
-->
<template>
  <span
    v-if="value !== null"
    role="img"
    :aria-label="value ? 'true' : 'false'"
    :data-state="value ? 'checked' : 'unchecked'"
    class="grid size-4 place-content-center rounded-[4px] border border-input shadow-xs data-[state=checked]:border-primary data-[state=checked]:bg-primary data-[state=checked]:text-primary-foreground"
  >
    <CheckIcon v-if="value" class="size-3.5" />
  </span>
</template>
