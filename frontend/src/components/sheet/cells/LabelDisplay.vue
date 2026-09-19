<script setup lang="ts">
import type { CellValue, Column } from '@/types/contract'

import { formatValue } from '@/lib/sheet/values'

const props = defineProps<{ value: CellValue; column: Column }>()
</script>

<template>
  <span class="truncate font-medium">{{ formatValue('text', props.value) }}</span>
</template>
