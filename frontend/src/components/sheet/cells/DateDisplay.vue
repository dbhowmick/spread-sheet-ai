<script setup lang="ts">
import type { CellValue, Column } from '@/types/contract'

import { formatValue } from '@/lib/sheet/values'

const props = defineProps<{ value: CellValue; column: Column }>()
</script>

<template>
  <span class="truncate tabular-nums">{{ formatValue('date', props.value) }}</span>
</template>
