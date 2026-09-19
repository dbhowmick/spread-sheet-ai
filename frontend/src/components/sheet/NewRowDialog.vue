<script setup lang="ts">
import { ref, watch } from 'vue'

import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import type { SheetState } from '@/lib/sheet/state'
import { validateLabel } from '@/lib/sheet/values'

/** Asks for the one thing a new row must have: its label (contract §6). */
const props = defineProps<{ open: boolean; view: SheetState }>()
const emit = defineEmits<{ submit: [label: string]; close: [] }>()

const label = ref('')
const error = ref<string | null>(null)

watch(
  () => props.open,
  (open) => {
    if (!open) return
    label.value = ''
    error.value = null
  },
)

function submit() {
  const checked = validateLabel(label.value, props.view)
  if (!checked.ok) {
    error.value = checked.message
    return
  }
  emit('submit', checked.value as string)
}

const labelColumnName = () => props.view.columnsById[props.view.labelColumnId]?.name ?? 'Line item'
</script>

<template>
  <Dialog :open="open" @update:open="(next) => !next && emit('close')">
    <DialogContent class="sm:max-w-sm">
      <form class="grid gap-5" @submit.prevent="submit">
        <DialogHeader>
          <DialogTitle>New row</DialogTitle>
          <DialogDescription>
            Every row is named by its {{ labelColumnName().toLowerCase() }}.
          </DialogDescription>
        </DialogHeader>

        <div class="grid gap-1.5">
          <Label for="new-row-label">{{ labelColumnName() }}</Label>
          <Input
            id="new-row-label"
            v-model="label"
            autocomplete="off"
            autofocus
            :aria-invalid="!!error"
            :aria-describedby="error ? 'new-row-error' : undefined"
          />
          <p v-if="error" id="new-row-error" class="text-sm text-destructive">{{ error }}</p>
        </div>

        <DialogFooter>
          <Button type="button" variant="ghost" @click="emit('close')">Cancel</Button>
          <Button type="submit">Add row</Button>
        </DialogFooter>
      </form>
    </DialogContent>
  </Dialog>
</template>
