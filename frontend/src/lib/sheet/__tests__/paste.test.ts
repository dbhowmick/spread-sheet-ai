import { describe, expect, it } from 'vitest'

import { navGrid } from '@/lib/sheet/navigation'
import { chunkCells, parseTsv, planPaste, skippedMessage } from '@/lib/sheet/paste'
import { fromSheet, type SheetState } from '@/lib/sheet/state'
import type { CellEdit, Column, Sheet } from '@/types/contract'

const label: Column = { id: 'c-label', name: 'Line item', column_type: 'text', is_label: true }
const amount: Column = { id: 'c-amt', name: 'Amount', column_type: 'number', is_label: false }
const done: Column = { id: 'c-done', name: 'Done', column_type: 'boolean', is_label: false }

function sheet(): SheetState {
  const raw: Sheet = {
    id: 's1',
    name: 'Budget',
    owner: { id: 'u1', display_name: 'Alice' },
    version: 1,
    columns: [label, amount, done],
    rows: [
      { id: 'r0', cells: { [label.id]: 'Revenue', [amount.id]: 10 } },
      { id: 'r1', cells: { [label.id]: 'COGS', [amount.id]: 20 } },
      { id: 'r2', cells: { [label.id]: 'Margin' } },
    ],
    inserted_at: '2026-09-19T10:00:00Z',
    updated_at: '2026-09-19T10:00:00Z',
  }
  return fromSheet(raw)
}

const state = sheet()
// Render order: the label column is pinned first, as the grid shows it.
const grid = navGrid(['r0', 'r1', 'r2'], [label.id, amount.id, done.id])

function plan(text: string, rowId = 'r0', columnId = amount.id) {
  return planPaste(text, grid, { rowId, columnId }, state)
}

function cellsOf(text: string, rowId?: string, columnId?: string): CellEdit[] {
  return plan(text, rowId, columnId).ops.flatMap((op) => op.cells)
}

describe('parseTsv', () => {
  it('splits rows on newlines and cells on tabs', () => {
    expect(parseTsv('a\tb\nc\td')).toEqual([
      ['a', 'b'],
      ['c', 'd'],
    ])
  })

  it('accepts CRLF and a trailing newline, as spreadsheets emit', () => {
    expect(parseTsv('a\tb\r\nc\td\r\n')).toEqual([
      ['a', 'b'],
      ['c', 'd'],
    ])
  })

  it('keeps a blank line inside the block as a real row', () => {
    expect(parseTsv('a\n\nb')).toEqual([['a'], [''], ['b']])
  })

  it('handles a single cell and an empty clipboard', () => {
    expect(parseTsv('42')).toEqual([['42']])
    expect(parseTsv('')).toEqual([])
  })
})

describe('planPaste', () => {
  it('lays a block out from the anchor', () => {
    expect(cellsOf('1\ttrue\n2\tfalse')).toEqual([
      { row_id: 'r0', column_id: amount.id, value: 1 },
      { row_id: 'r0', column_id: done.id, value: true },
      { row_id: 'r1', column_id: amount.id, value: 2 },
      { row_id: 'r1', column_id: done.id, value: false },
    ])
  })

  it('parses leniently, like a typed edit', () => {
    expect(cellsOf('1,200')).toEqual([{ row_id: 'r0', column_id: amount.id, value: 1200 }])
    expect(cellsOf('yes', 'r0', done.id)).toEqual([
      { row_id: 'r0', column_id: done.id, value: true },
    ])
  })

  it('clears a cell with an empty value', () => {
    expect(cellsOf('')).toEqual([])
    expect(cellsOf('\t')).toEqual([
      { row_id: 'r0', column_id: amount.id, value: null },
      { row_id: 'r0', column_id: done.id, value: null },
    ])
  })

  it('skips cells past the last row or column instead of growing the sheet', () => {
    // A 4 × 3 block anchored at r0 × Amount, where only 3 × 2 of the sheet is
    // left: one column and one row of it fall outside.
    const result = plan('1\ttrue\t3\n4\tfalse\t6\n7\ttrue\t9\n10\tfalse\t12')
    expect(result.written).toBe(6)
    expect(result.skipped).toBe(6)
  })

  it('skips values that do not fit the column type', () => {
    const result = plan('abc\nxyz')
    expect(result.written).toBe(0)
    expect(result.skipped).toBe(2)
    expect(result.ops).toEqual([])
  })

  it('writes labels trimmed', () => {
    expect(cellsOf('  Sales  ', 'r0', label.id)).toEqual([
      { row_id: 'r0', column_id: label.id, value: 'Sales' },
    ])
  })

  it('skips a blank pasted into the label column', () => {
    const result = plan('   ', 'r0', label.id)
    expect(result.written).toBe(0)
    expect(result.skipped).toBe(1)
  })

  it('skips a label another row already uses', () => {
    const result = plan('COGS', 'r0', label.id)
    expect(result.written).toBe(0)
    expect(result.skipped).toBe(1)
  })

  it('lets a row keep its own label, ignoring case', () => {
    expect(cellsOf('revenue', 'r0', label.id)).toEqual([
      { row_id: 'r0', column_id: label.id, value: 'revenue' },
    ])
  })

  it('refuses to hand the same new label to two rows in one paste', () => {
    const result = plan('Sales\nSales', 'r0', label.id)
    expect(result.written).toBe(1)
    expect(result.skipped).toBe(1)
  })

  it('lets a block move labels down a column, since each frees its own', () => {
    // r0 takes r1's label as r1 takes a fresh one.
    const result = plan('COGS\nSales', 'r0', label.id)
    expect(result.skipped).toBe(0)
    expect(result.ops[0]?.cells).toEqual([
      { row_id: 'r0', column_id: label.id, value: 'COGS' },
      { row_id: 'r1', column_id: label.id, value: 'Sales' },
    ])
  })

  it('does nothing for an empty clipboard or an anchor that is gone', () => {
    expect(plan('')).toEqual({ ops: [], written: 0, skipped: 0 })
    expect(planPaste('1', grid, { rowId: 'gone', columnId: amount.id }, state).written).toBe(0)
  })
})

describe('chunkCells', () => {
  const cells = (n: number): CellEdit[] =>
    Array.from({ length: n }, (_, i) => ({ row_id: `r${i}`, column_id: 'c', value: i }))

  it('sends one op while under the cap', () => {
    expect(chunkCells(cells(3), 10)).toEqual([{ type: 'set_cells', cells: cells(3) }])
  })

  it('splits at the cap, since the server rejects the whole op otherwise', () => {
    const ops = chunkCells(cells(25), 10)
    expect(ops.map((op) => op.cells.length)).toEqual([10, 10, 5])
  })

  it('is exact at the boundary', () => {
    expect(chunkCells(cells(10), 10)).toHaveLength(1)
    expect(chunkCells(cells(11), 10)).toHaveLength(2)
  })

  it('sends nothing for nothing', () => {
    expect(chunkCells([], 10)).toEqual([])
  })
})

describe('skippedMessage', () => {
  it('counts what could not land, and stays quiet otherwise', () => {
    expect(skippedMessage({ ops: [], written: 0, skipped: 0 })).toBeNull()
    expect(skippedMessage({ ops: [], written: 0, skipped: 1 })).toContain('1 cell')
    expect(skippedMessage({ ops: [], written: 0, skipped: 4 })).toContain('4 cells')
  })
})
