<script setup lang="ts">
import { RouterLink } from 'vue-router'

import SheetPane from '@/components/workspace/SheetPane.vue'
import { Button } from '@/components/ui/button'

/** A sheet on its own, outside any conversation (UI-5). */
defineProps<{ sheetId: string }>()
</script>

<template>
  <SheetPane :sheet-id="sheetId">
    <template #error-action>
      <Button variant="outline" as-child>
        <RouterLink :to="{ name: 'sheets' }">Back to sheets</RouterLink>
      </Button>
    </template>
  </SheetPane>
</template>
