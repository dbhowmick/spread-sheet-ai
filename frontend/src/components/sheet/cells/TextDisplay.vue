<script setup lang="ts">
import type { CellValue, Column } from '@/types/contract'

import { formatValue } from '@/lib/sheet/values'

const props = defineProps<{ value: CellValue; column: Column }>()
</script>

<template>
  <span class="truncate">{{ formatValue(props.column.column_type, props.value) }}</span>
</template>
