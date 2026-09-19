<script setup lang="ts">
import { ref, watch } from 'vue'
import { PlusIcon } from '@lucide/vue'

import CreateSheetDialog from '@/components/sheet/CreateSheetDialog.vue'
import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandSeparator,
} from '@/components/ui/command'
import { useErrorMessage } from '@/composables/useErrorMessage'
import { api } from '@/lib/api'
import type {
  LinkedSheet,
  Sheet,
  SheetId,
  SheetSummary,
  SheetsIndexResponse,
} from '@/types/contract'

/**
 * A palette over every sheet (they are all shared), for adding a tab to the
 * workspace. Sheets already linked to this conversation come first, since they
 * are what the user is most likely to want back.
 */
const props = defineProps<{ linkedSheets: LinkedSheet[] }>()
const open = defineModel<boolean>('open', { default: false })
const emit = defineEmits<{ (e: 'pick', sheetId: SheetId): void }>()

const errorMessage = useErrorMessage()

const sheets = ref<SheetSummary[]>([])
const loading = ref(false)
const loadError = ref<string | null>(null)
const creating = ref(false)

async function load() {
  loading.value = true
  loadError.value = null
  const res = await api.get<SheetsIndexResponse>('/api/sheets')
  loading.value = false
  if (res.ok) sheets.value = res.data.sheets
  else loadError.value = res.error.message ?? errorMessage(res.error.code)
}

// Reload on every open: the AI may have created sheets since last time.
watch(open, (isOpen) => {
  if (isOpen) void load()
})

function pick(sheetId: SheetId) {
  open.value = false
  emit('pick', sheetId)
}

function handleCreated(sheet: Sheet) {
  pick(sheet.id)
}
</script>

<template>
  <CommandDialog v-model:open="open">
    <CommandInput placeholder="Search sheets…" />
    <CommandList>
      <CommandEmpty>
        {{ loading ? 'Loading…' : (loadError ?? 'No sheets found.') }}
      </CommandEmpty>

      <CommandGroup v-if="props.linkedSheets.length > 0" heading="Used in this chat">
        <CommandItem
          v-for="link in props.linkedSheets"
          :key="link.sheet.id"
          :value="`linked-${link.sheet.id}-${link.sheet.name}`"
          @select="pick(link.sheet.id)"
        >
          <span class="truncate">{{ link.sheet.name }}</span>
          <span class="ms-auto text-xs text-muted-foreground">
            {{ link.sheet.row_count }} rows
          </span>
        </CommandItem>
      </CommandGroup>

      <CommandSeparator v-if="props.linkedSheets.length > 0" />

      <CommandGroup heading="All sheets">
        <CommandItem
          v-for="sheet in sheets"
          :key="sheet.id"
          :value="`all-${sheet.id}-${sheet.name}`"
          @select="pick(sheet.id)"
        >
          <span class="truncate">{{ sheet.name }}</span>
          <span class="ms-auto text-xs text-muted-foreground">{{ sheet.row_count }} rows</span>
        </CommandItem>
      </CommandGroup>

      <CommandSeparator />

      <CommandGroup>
        <CommandItem value="new-sheet" @select="((open = false), (creating = true))">
          <PlusIcon class="size-4" />
          New sheet
        </CommandItem>
      </CommandGroup>
    </CommandList>
  </CommandDialog>

  <CreateSheetDialog v-model:open="creating" @created="handleCreated" />
</template>
