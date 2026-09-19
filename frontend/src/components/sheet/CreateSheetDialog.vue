<script setup lang="ts">
import { reactive, ref, watch } from 'vue'
import { Loader2Icon, PlusIcon, XIcon } from '@lucide/vue'

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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { useErrorMessage } from '@/composables/useErrorMessage'
import { api } from '@/lib/api'
import { normalizeKey } from '@/lib/sheet/values'
import type { ColumnType, CreateSheetRequest, Sheet, SheetShowResponse } from '@/types/contract'

const open = defineModel<boolean>('open', { default: false })
const emit = defineEmits<{ created: [sheet: Sheet] }>()

interface DraftColumn {
  key: number
  name: string
  column_type: ColumnType
}

const DEFAULT_LABEL = 'Line item'

const typeOptions: { value: ColumnType; label: string }[] = [
  { value: 'text', label: 'Text' },
  { value: 'number', label: 'Number' },
  { value: 'boolean', label: 'Checkbox' },
  { value: 'date', label: 'Date' },
]

const errorMessage = useErrorMessage()

const name = ref('')
const labelColumnName = ref('')
const columns = ref<DraftColumn[]>([])
const submitting = ref(false)
const errors = reactive<{
  name?: string
  label_column_name?: string
  columns?: string
  form?: string
}>({})
let nextKey = 0

function reset() {
  name.value = ''
  labelColumnName.value = ''
  columns.value = []
  clearErrors()
}

function clearErrors() {
  errors.name = undefined
  errors.label_column_name = undefined
  errors.columns = undefined
  errors.form = undefined
}

watch(open, (isOpen) => {
  if (isOpen) reset()
})

function addColumn() {
  columns.value.push({ key: nextKey++, name: '', column_type: 'text' })
}

function removeColumn(key: number) {
  columns.value = columns.value.filter((c) => c.key !== key)
}

/** The server checks all of this too; checking here keeps the round-trip for real errors. */
function validate(): boolean {
  if (!name.value.trim()) errors.name = 'A sheet needs a name.'

  const seen = new Set([normalizeKey(labelColumnName.value || DEFAULT_LABEL)])
  for (const column of columns.value) {
    const key = normalizeKey(column.name)
    if (!key) {
      errors.columns = 'Every column needs a name.'
      break
    }
    if (seen.has(key)) {
      errors.columns = `"${column.name.trim()}" is used twice. Column names must be unique.`
      break
    }
    seen.add(key)
  }

  return !errors.name && !errors.columns
}

async function handleSubmit() {
  clearErrors()
  if (!validate()) return

  const body: CreateSheetRequest = { name: name.value.trim() }
  if (labelColumnName.value.trim()) body.label_column_name = labelColumnName.value.trim()
  if (columns.value.length > 0) {
    body.columns = columns.value.map((c) => ({ name: c.name.trim(), column_type: c.column_type }))
  }

  submitting.value = true
  const res = await api.post<SheetShowResponse>('/api/sheets', body)
  submitting.value = false

  if (res.ok) {
    open.value = false
    emit('created', res.data.sheet)
    return
  }

  const fieldErrors = res.error.fieldErrors ?? {}
  errors.name = fieldErrors.name?.[0]
  errors.label_column_name = fieldErrors.label_column_name?.[0]
  errors.columns = fieldErrors.columns?.[0]
  if (!errors.name && !errors.label_column_name && !errors.columns) {
    errors.form = res.error.message ?? errorMessage(res.error.code)
  }
}
</script>

<template>
  <Dialog v-model:open="open">
    <DialogContent class="sm:max-w-lg">
      <form class="grid gap-5" @submit.prevent="handleSubmit">
        <DialogHeader>
          <DialogTitle>New sheet</DialogTitle>
          <DialogDescription>
            Every sheet has a label column that names its rows. You can add columns now or later.
          </DialogDescription>
        </DialogHeader>

        <div
          v-if="errors.form"
          role="alert"
          class="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
        >
          {{ errors.form }}
        </div>

        <div class="grid gap-1.5">
          <Label for="sheet-name">Name</Label>
          <Input
            id="sheet-name"
            v-model="name"
            placeholder="Budget 2026"
            autocomplete="off"
            :aria-invalid="!!errors.name"
            :aria-describedby="errors.name ? 'sheet-name-error' : undefined"
          />
          <p v-if="errors.name" id="sheet-name-error" class="text-sm text-destructive">
            {{ errors.name }}
          </p>
        </div>

        <div class="grid gap-1.5">
          <Label for="sheet-label-column">Label column</Label>
          <Input
            id="sheet-label-column"
            v-model="labelColumnName"
            :placeholder="DEFAULT_LABEL"
            autocomplete="off"
            :aria-invalid="!!errors.label_column_name"
          />
          <p v-if="errors.label_column_name" class="text-sm text-destructive">
            {{ errors.label_column_name }}
          </p>
        </div>

        <fieldset class="grid gap-2">
          <legend class="mb-1.5 text-sm leading-none font-medium">Columns</legend>

          <div v-for="(column, i) in columns" :key="column.key" class="flex items-center gap-2">
            <Input
              v-model="column.name"
              :aria-label="`Column ${i + 1} name`"
              placeholder="Column name"
              autocomplete="off"
              class="flex-1"
            />
            <Select v-model="column.column_type">
              <SelectTrigger class="w-32" :aria-label="`Column ${i + 1} type`">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem v-for="option in typeOptions" :key="option.value" :value="option.value">
                  {{ option.label }}
                </SelectItem>
              </SelectContent>
            </Select>
            <Button
              type="button"
              variant="ghost"
              size="icon-sm"
              :aria-label="`Remove column ${i + 1}`"
              @click="removeColumn(column.key)"
            >
              <XIcon />
            </Button>
          </div>

          <p v-if="errors.columns" class="text-sm text-destructive">{{ errors.columns }}</p>

          <Button
            type="button"
            variant="outline"
            size="sm"
            class="justify-self-start"
            @click="addColumn"
          >
            <PlusIcon />
            Add column
          </Button>
        </fieldset>

        <DialogFooter>
          <Button type="button" variant="ghost" @click="open = false">Cancel</Button>
          <Button type="submit" :disabled="submitting">
            <Loader2Icon v-if="submitting" class="animate-spin" />
            Create sheet
          </Button>
        </DialogFooter>
      </form>
    </DialogContent>
  </Dialog>
</template>
