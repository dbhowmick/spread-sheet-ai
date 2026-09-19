import { h, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import SheetCell from '@/components/sheet/SheetCell.vue'
import { sheetGridKey } from '@/components/sheet/context'
import { TooltipProvider } from '@/components/ui/tooltip'
import type { Cue } from '@/lib/sheet/consistency'
import { CUE_MARKER_MS } from '@/lib/sheet/grid'
import { cellKey } from '@/lib/sheet/state'
import type { Actor, CellValue, Column, Row } from '@/types/contract'

const ROW_ID = 'r1'

const label: Column = { id: 'c-label', name: 'Line item', column_type: 'text', is_label: true }
const number: Column = { id: 'c-q1', name: 'Q1', column_type: 'number', is_label: false }
const flag: Column = { id: 'c-ok', name: 'Done', column_type: 'boolean', is_label: false }
const date: Column = { id: 'c-due', name: 'Due', column_type: 'date', is_label: false }

function row(column: Column, value: CellValue): Row {
  return { id: ROW_ID, cells: value === null ? {} : { [column.id]: value } }
}

interface GridState {
  cues?: Map<string, Cue>
  pendingCells?: Set<string>
  now?: number
}

/** `SheetCell` reads cues, pending state and the clock from `SheetGrid`. */
function mountCell(column: Column, value: CellValue, grid: GridState = {}) {
  const now: Ref<number> = ref(grid.now ?? Date.now())
  return mount(TooltipProvider, {
    slots: {
      default: () => h(SheetCell, { row: row(column, value), column }),
    },
    global: {
      provide: {
        [sheetGridKey as symbol]: {
          cues: ref(grid.cues ?? new Map<string, Cue>()),
          pendingCells: ref(grid.pendingCells ?? new Set<string>()),
          now,
        },
      },
    },
  })
}

describe('display by column type', () => {
  it('formats text and the row label', () => {
    expect(mountCell(label, 'Revenue').text()).toBe('Revenue')
  })

  it('formats numbers, right-aligned', () => {
    const cell = mountCell(number, 1200)
    expect(cell.text()).toContain('1,200')
    expect(cell.get('div').classes()).toContain('justify-end')
  })

  it('keeps dates ISO, so copy round-trips', () => {
    expect(mountCell(date, '2026-03-01').text()).toBe('2026-03-01')
  })

  it('renders a checkbox for booleans, checked only when true', () => {
    expect(mountCell(flag, true).get('[role="img"]').attributes('data-state')).toBe('checked')
    expect(mountCell(flag, false).get('[role="img"]').attributes('data-state')).toBe('unchecked')
  })

  it('renders nothing for an empty cell', () => {
    expect(mountCell(number, null).text()).toBe('')
    expect(mountCell(flag, null).find('[role="img"]').exists()).toBe(false)
  })
})

describe('pending previews', () => {
  it('marks a cell covered by an unconfirmed op', () => {
    const cell = mountCell(number, 42, {
      pendingCells: new Set([cellKey(ROW_ID, number.id)]),
    })
    expect(cell.get('[data-pending]').classes()).toContain('italic')
  })

  it('leaves other cells alone', () => {
    const cell = mountCell(number, 42, { pendingCells: new Set([cellKey('r9', number.id)]) })
    expect(cell.find('[data-pending]').exists()).toBe(false)
  })
})

describe('remote change cues', () => {
  const at = 1_000_000

  function cueFor(actor: Actor): Map<string, Cue> {
    return new Map([[cellKey(ROW_ID, number.id), { actor, at }]])
  }

  it('names the user who changed the cell', () => {
    const cues = cueFor({ type: 'user', user: { id: 'u2', display_name: 'Bob' } })
    const marker = mountCell(number, 42, { cues, now: at }).get('[data-cue-marker]')
    expect(marker.attributes('aria-label')).toBe('Changed by Bob')
  })

  it('names the conversation for an agent change (AI-6)', () => {
    const cues = cueFor({ type: 'agent', conversation_id: 'c1', conversation_title: 'Budget' })
    const marker = mountCell(number, 42, { cues, now: at }).get('[data-cue-marker]')
    expect(marker.attributes('aria-label')).toBe('Changed by AI · Budget')
  })

  it('drops the marker once the cue is stale', () => {
    const cues = cueFor({ type: 'user', user: { id: 'u2', display_name: 'Bob' } })
    const cell = mountCell(number, 42, { cues, now: at + CUE_MARKER_MS })
    expect(cell.find('[data-cue-marker]').exists()).toBe(false)
  })
})
