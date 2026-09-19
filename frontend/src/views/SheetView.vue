<script setup lang="ts">
import { computed, ref, useTemplateRef } from 'vue'
import { RouterLink } from 'vue-router'
import { TableIcon } from '@lucide/vue'

import SheetGrid from '@/components/sheet/SheetGrid.vue'
import SheetToolbar from '@/components/sheet/SheetToolbar.vue'
import { Button } from '@/components/ui/button'
import {
  Empty,
  EmptyContent,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from '@/components/ui/empty'
import { Skeleton } from '@/components/ui/skeleton'
import { useErrorMessage } from '@/composables/useErrorMessage'
import { useSheet } from '@/composables/useSheet'

/** A sheet on its own, outside any conversation (UI-5). */
const props = defineProps<{ sheetId: string }>()

const { view, status, error, participants, cues, lastChange, pendingCells, apply } = useSheet(
  () => props.sheetId,
)

const grid = useTemplateRef<{ clearSelection: () => void }>('grid')
const selectedRowIds = ref<string[]>([])
const errorMessage = useErrorMessage()

const errorTitle = computed(() =>
  error.value?.code === 'not_found' ? 'Sheet not found' : "Couldn't open this sheet",
)
const errorText = computed(() =>
  error.value?.code === 'not_found'
    ? "It doesn't exist, or it was deleted."
    : (error.value?.message ?? errorMessage(error.value?.code)),
)
</script>

<template>
  <div class="flex h-full min-h-0 flex-col">
    <Empty v-if="status === 'error'" class="h-full">
      <EmptyHeader>
        <EmptyMedia variant="icon"><TableIcon /></EmptyMedia>
        <EmptyTitle>{{ errorTitle }}</EmptyTitle>
        <EmptyDescription>{{ errorText }}</EmptyDescription>
      </EmptyHeader>
      <EmptyContent>
        <Button variant="outline" as-child>
          <RouterLink :to="{ name: 'sheets' }">Back to sheets</RouterLink>
        </Button>
      </EmptyContent>
    </Empty>

    <div
      v-else-if="status === 'joining' || !view"
      class="flex flex-col"
      aria-busy="true"
      aria-label="Loading sheet"
    >
      <div class="flex h-14 items-center gap-3 border-b px-3">
        <Skeleton class="size-8 rounded-md" />
        <div class="space-y-1.5">
          <Skeleton class="h-3.5 w-40" />
          <Skeleton class="h-3 w-28" />
        </div>
      </div>
      <div class="space-y-2 p-3">
        <Skeleton v-for="i in 12" :key="i" class="h-6 w-full" />
      </div>
    </div>

    <template v-else>
      <SheetToolbar
        :view="view"
        :status="status"
        :participants="participants"
        :last-change="lastChange"
        :apply="apply"
        :selected-row-ids="selectedRowIds"
        @clear-selection="grid?.clearSelection()"
      />
      <div class="min-h-0 flex-1">
        <SheetGrid
          :key="view.id"
          ref="grid"
          :view="view"
          :cues="cues"
          :pending-cells="pendingCells"
          :apply="apply"
          @update:selected-row-ids="selectedRowIds = $event"
        />
      </div>
    </template>
  </div>
</template>
