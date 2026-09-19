<script setup lang="ts">
import { computed, inject, ref } from 'vue'

import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { actorName } from '@/lib/people'
import type { Cue } from '@/lib/sheet/consistency'
import { isCueFresh } from '@/lib/sheet/grid'
import type { Move } from '@/lib/sheet/navigation'
import { cellKey, cellOf } from '@/lib/sheet/state'
import { cn } from '@/lib/utils'
import type { Column, Row } from '@/types/contract'

import { cellTypeFor } from './cells/registry'
import { sheetGridKey, sheetNavKey, type SheetGridContext, type SheetNavContext } from './context'

/** How long the background flash for a remote change lasts. */
const FLASH_MS = 1500

const props = defineProps<{ row: Row; column: Column }>()

const grid: SheetGridContext = inject(sheetGridKey, {
  cues: ref(new Map<string, Cue>()),
  pendingCells: ref(new Set<string>()),
  now: ref(Date.now()),
})

/** A read-only grid (and the F3 cell tests) simply provides no nav context. */
const nav = inject<SheetNavContext | null>(sheetNavKey, null)

const key = computed(() => cellKey(props.row.id, props.column.id))
const value = computed(() => cellOf(props.row, props.column.id))
const type = computed(() => cellTypeFor(props.column))
const pending = computed(() => grid.pendingCells.value.has(key.value))
const cue = computed(() => grid.cues.value.get(key.value))

const active = computed(() => nav?.activeKey.value === key.value)

// Short-circuited on purpose: a cell that isn't active never reads `editing`,
// so it never subscribes to it and one open editor re-renders one cell.
const editing = computed(() => (active.value && nav?.editing.value ? nav.editing.value : null))
const editor = computed(() => (editing.value ? type.value.editor : null))

// Read once per cue, not reactively: a cell scrolled back into view (and so
// remounted by the virtualizer) must not replay an old flash.
const flash = computed(() => cue.value !== undefined && Date.now() - cue.value.at < FLASH_MS)
const marker = computed(() => isCueFresh(cue.value, grid.now.value))

const cellRef = computed(() => ({ rowId: props.row.id, columnId: props.column.id }))

function onPointerdown() {
  if (!nav || editing.value) return
  // A boolean has no editor, so a click both activates and toggles it —
  // an empty one renders no glyph to aim at otherwise.
  if (props.column.column_type === 'boolean' && !props.column.is_label) {
    nav.toggleBoolean(cellRef.value)
    return
  }
  nav.activate(cellRef.value)
}

function onDblclick() {
  nav?.beginEdit(cellRef.value)
}

function onCommit(input: string, next: Move | null) {
  nav?.commit(input, next)
}

const alignClass = {
  start: 'justify-start text-start',
  end: 'justify-end text-end',
  center: 'justify-center',
} as const
</script>

<template>
  <div
    :data-pending="pending || undefined"
    :data-active="active || undefined"
    :data-editing="editing ? true : undefined"
    :class="
      cn(
        'relative flex h-full min-w-0 items-center px-2 text-sm',
        alignClass[type.align],
        pending && 'text-muted-foreground italic',
        active && !editing && 'ring-2 ring-inset ring-primary',
      )
    "
    @pointerdown="onPointerdown"
    @dblclick="onDblclick"
  >
    <component :is="type.display" :value="value" :column="column" />

    <component
      :is="editor"
      v-if="editor && editing"
      :column="column"
      :value="value"
      :initial-input="editing.initialInput"
      :error="editing.error"
      @commit="onCommit"
      @cancel="nav?.cancel()"
    />

    <span
      v-if="flash && cue"
      :key="cue.at"
      aria-hidden="true"
      class="sheet-cell-flash pointer-events-none absolute inset-0"
    />

    <Tooltip v-if="marker && cue">
      <TooltipTrigger as-child>
        <span
          data-cue-marker
          :aria-label="`Changed by ${actorName(cue.actor)}`"
          :class="
            cn(
              'absolute end-0 top-0 z-[5] size-0 border-s-[7px] border-t-[7px] border-s-transparent',
              cue.actor.type === 'agent' ? 'border-t-violet-500' : 'border-t-amber-500',
            )
          "
        />
      </TooltipTrigger>
      <TooltipContent>Changed by {{ actorName(cue.actor) }}</TooltipContent>
    </Tooltip>
  </div>
</template>

<style scoped>
.sheet-cell-flash {
  background: color-mix(in oklab, var(--color-amber-300) 55%, transparent);
  animation: sheet-cell-flash 1.5s ease-out forwards;
}

@keyframes sheet-cell-flash {
  from {
    opacity: 1;
  }
  to {
    opacity: 0;
  }
}

@media (prefers-reduced-motion: reduce) {
  .sheet-cell-flash {
    animation-duration: 0.01s;
  }
}
</style>
