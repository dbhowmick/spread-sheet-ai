<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { useIntervalFn } from '@vueuse/core'
import { PlusIcon, TableIcon } from '@lucide/vue'

import CreateSheetDialog from '@/components/sheet/CreateSheetDialog.vue'
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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { useErrorMessage } from '@/composables/useErrorMessage'
import { api } from '@/lib/api'
import { timeAgo } from '@/lib/time'
import type { Sheet, SheetSummary, SheetsIndexResponse } from '@/types/contract'

const router = useRouter()
const errorMessage = useErrorMessage()

const sheets = ref<SheetSummary[]>([])
const loading = ref(true)
const loadError = ref<string | null>(null)
const creating = ref(false)

const now = ref(Date.now())
useIntervalFn(() => {
  now.value = Date.now()
}, 30_000)

async function load() {
  loading.value = true
  loadError.value = null
  const res = await api.get<SheetsIndexResponse>('/api/sheets')
  loading.value = false
  if (res.ok) sheets.value = res.data.sheets
  else loadError.value = res.error.message ?? errorMessage(res.error.code)
}

function openSheet(sheetId: string) {
  void router.push({ name: 'sheet', params: { sheetId } })
}

function handleCreated(sheet: Sheet) {
  openSheet(sheet.id)
}

onMounted(load)
</script>

<template>
  <div class="flex h-full min-h-0 flex-col">
    <header class="flex h-14 shrink-0 items-center gap-3 border-b px-4">
      <h1 class="text-sm font-semibold">Sheets</h1>
      <Button v-if="sheets.length > 0" size="sm" class="ms-auto" @click="creating = true">
        <PlusIcon />
        New sheet
      </Button>
    </header>

    <div class="min-h-0 flex-1 overflow-auto">
      <div v-if="loading" class="space-y-3 p-4" aria-busy="true" aria-label="Loading sheets">
        <Skeleton v-for="i in 6" :key="i" class="h-9 w-full" />
      </div>

      <Empty v-else-if="loadError" class="h-full">
        <EmptyHeader>
          <EmptyTitle>Couldn't load sheets</EmptyTitle>
          <EmptyDescription>{{ loadError }}</EmptyDescription>
        </EmptyHeader>
        <EmptyContent>
          <Button variant="outline" @click="load">Retry</Button>
        </EmptyContent>
      </Empty>

      <Empty v-else-if="sheets.length === 0" class="h-full">
        <EmptyHeader>
          <EmptyMedia variant="icon"><TableIcon /></EmptyMedia>
          <EmptyTitle>No sheets yet</EmptyTitle>
          <EmptyDescription>
            Create one here, or ask the AI in a chat to build one for you.
          </EmptyDescription>
        </EmptyHeader>
        <EmptyContent>
          <Button @click="creating = true">
            <PlusIcon />
            New sheet
          </Button>
        </EmptyContent>
      </Empty>

      <Table v-else>
        <TableHeader>
          <TableRow>
            <TableHead class="ps-4">Name</TableHead>
            <TableHead>Owner</TableHead>
            <TableHead>Size</TableHead>
            <TableHead class="pe-4 text-end">Updated</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          <TableRow
            v-for="sheet in sheets"
            :key="sheet.id"
            class="cursor-pointer"
            @click="openSheet(sheet.id)"
          >
            <TableCell class="ps-4 font-medium">
              <RouterLink
                :to="{ name: 'sheet', params: { sheetId: sheet.id } }"
                class="hover:underline focus-visible:underline focus-visible:outline-none"
                @click.stop
              >
                {{ sheet.name }}
              </RouterLink>
            </TableCell>
            <TableCell class="text-muted-foreground">{{ sheet.owner.display_name }}</TableCell>
            <TableCell class="text-muted-foreground tabular-nums">
              {{ sheet.row_count }} rows · {{ sheet.column_count }} columns
            </TableCell>
            <TableCell class="pe-4 text-end text-muted-foreground">
              <time
                :datetime="sheet.updated_at"
                :title="new Date(sheet.updated_at).toLocaleString()"
              >
                {{ timeAgo(Date.parse(sheet.updated_at), now) }}
              </time>
            </TableCell>
          </TableRow>
        </TableBody>
      </Table>
    </div>

    <CreateSheetDialog v-model:open="creating" @created="handleCreated" />
  </div>
</template>
