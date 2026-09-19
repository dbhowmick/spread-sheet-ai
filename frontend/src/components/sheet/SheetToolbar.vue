<script setup lang="ts">
import { computed, nextTick, ref, useTemplateRef } from 'vue'
import { RouterLink } from 'vue-router'
import { useIntervalFn } from '@vueuse/core'
import { ChevronLeftIcon, Loader2Icon, PlusIcon, Trash2Icon } from '@lucide/vue'

import ParticipantAvatars from '@/components/app/ParticipantAvatars.vue'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { actorName } from '@/lib/people'
import type { Cue, SheetStatus } from '@/lib/sheet/consistency'
import type { SheetState } from '@/lib/sheet/state'
import { timeAgo } from '@/lib/time'
import type { DeleteRowsOp, Op, RenameSheetOp, UserRef } from '@/types/contract'

import AddColumnDialog from './AddColumnDialog.vue'
import ConfirmDialog from './ConfirmDialog.vue'

const props = defineProps<{
  view: SheetState
  status: SheetStatus
  participants: UserRef[]
  lastChange: Cue | null
  apply: (op: Op) => Promise<void>
  selectedRowIds: string[]
}>()

const emit = defineEmits<{ clearSelection: [] }>()

const now = ref(Date.now())
useIntervalFn(() => {
  now.value = Date.now()
}, 5000)

const updated = computed(() => {
  const change = props.lastChange
  if (!change) return null
  return `Updated by ${actorName(change.actor)} · ${timeAgo(change.at, now.value)}`
})

const plural = (count: number, noun: string) => `${count} ${noun}${count === 1 ? '' : 's'}`
const size = computed(
  () => `${plural(props.view.rows.length, 'row')} · ${plural(props.view.columns.length, 'column')}`,
)
const selectedCount = computed(() => props.selectedRowIds.length)

const addingColumn = ref(false)
const confirmingDelete = ref(false)

const renaming = ref(false)
const draft = ref('')
const nameInput = useTemplateRef<HTMLInputElement>('nameInput')

async function startRename() {
  draft.value = props.view.name
  renaming.value = true
  await nextTick()
  nameInput.value?.select()
}

function commitRename() {
  if (!renaming.value) return
  renaming.value = false

  const trimmed = draft.value.trim()
  // A blank name is `invalid_op`, and an unchanged one would still bump the
  // version for every viewer — neither is worth sending.
  if (trimmed === '' || trimmed === props.view.name) return

  const op: RenameSheetOp = { type: 'rename_sheet', name: trimmed }
  void props.apply(op)
}

function deleteSelected() {
  confirmingDelete.value = false
  const op: DeleteRowsOp = { type: 'delete_rows', row_ids: props.selectedRowIds }
  void props.apply(op)
  emit('clearSelection')
}
</script>

<template>
  <header class="flex h-14 shrink-0 items-center gap-3 border-b px-3">
    <Button variant="ghost" size="icon-sm" as-child>
      <RouterLink :to="{ name: 'sheets' }" aria-label="All sheets">
        <ChevronLeftIcon />
      </RouterLink>
    </Button>

    <div class="min-w-0">
      <input
        v-if="renaming"
        ref="nameInput"
        v-model="draft"
        type="text"
        aria-label="Sheet name"
        class="w-64 rounded-sm bg-background text-sm font-semibold outline-none ring-2 ring-inset ring-primary"
        @keydown.enter.prevent="commitRename"
        @keydown.escape.prevent="renaming = false"
        @blur="commitRename"
      />
      <h1
        v-else
        class="cursor-text truncate rounded-sm text-sm font-semibold hover:bg-muted"
        role="button"
        tabindex="0"
        title="Rename sheet"
        @click="startRename"
        @keydown.enter.prevent="startRename"
      >
        {{ view.name }}
      </h1>
      <p class="truncate text-xs text-muted-foreground">
        {{ size }}<template v-if="updated"> · {{ updated }}</template>
      </p>
    </div>

    <Badge v-if="status === 'resyncing'" variant="secondary" class="shrink-0">
      <Loader2Icon class="animate-spin" />
      Syncing
    </Badge>

    <div class="ms-auto flex items-center gap-2">
      <Button
        v-if="selectedCount > 0"
        variant="outline"
        size="sm"
        class="text-destructive"
        @click="confirmingDelete = true"
      >
        <Trash2Icon />
        Delete {{ selectedCount }} {{ selectedCount === 1 ? 'row' : 'rows' }}
      </Button>

      <Button variant="outline" size="sm" @click="addingColumn = true">
        <PlusIcon />
        Add column
      </Button>

      <ParticipantAvatars :users="participants" />
    </div>
  </header>

  <AddColumnDialog
    :open="addingColumn"
    :view="view"
    :position="null"
    :apply="apply"
    @close="addingColumn = false"
  />

  <ConfirmDialog
    :open="confirmingDelete"
    :title="`Delete ${selectedCount} ${selectedCount === 1 ? 'row' : 'rows'}?`"
    description="This can't be undone."
    confirm-label="Delete"
    @confirm="deleteSelected"
    @close="confirmingDelete = false"
  />
</template>
