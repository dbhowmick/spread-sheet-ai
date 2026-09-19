<script setup lang="ts">
import type { CellValue, Column } from '@/types/contract'

import { formatValue } from '@/lib/sheet/values'

const props = defineProps<{ value: CellValue; column: Column }>()

// Localized for display only; copy uses the raw value (frontend-plan §7.4).
const locale = typeof navigator === 'undefined' ? undefined : navigator.language
</script>

<template>
  <span class="truncate tabular-nums">{{ formatValue('number', props.value, locale) }}</span>
</template>
