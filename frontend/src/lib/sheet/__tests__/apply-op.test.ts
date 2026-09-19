import { describe, expect, it } from 'vitest'

import { applyOp } from '@/lib/sheet/apply-op'
import { fromSheet, type SheetState } from '@/lib/sheet/state'
import type { AppliedOp, Op, Sheet } from '@/types/contract'

/**
 * The fixture mirrors the shape the server's `engine_test.exs` uses: a label
 * column first, then Q1 / Q2 / Notes.
 */
const LABEL = 'c-label'
const Q1 = 'c-q1'
const Q2 = 'c-q2'
const NOTES = 'c-notes'

function sheet(): Sheet {
  return {
    id: 's1',
    name: 'Budget',
    owner: { id: 'u1', display_name: 'Alice' },
    version: 7,
    columns: [
      { id: LABEL, name: 'Line item', column_type: 'text', is_label: true },
      { id: Q1, name: 'Q1', column_type: 'number', is_label: false },
      { id: Q2, name: 'Q2', column_type: 'number', is_label: false },
      { id: NOTES, name: 'Notes', column_type: 'text', is_label: false },
    ],
    rows: [
      { id: 'r1', cells: { [LABEL]: 'Revenue', [Q1]: 1200, [NOTES]: 'steady' } },
      { id: 'r2', cells: { [LABEL]: 'Costs', [Q1]: 800 } },
      { id: 'r3', cells: { [LABEL]: 'Margin' } },
    ],
    inserted_at: '2026-09-19T10:00:00Z',
    updated_at: '2026-09-19T10:05:00Z',
  }
}

const state = (): SheetState => fromSheet(sheet())
const names = (s: SheetState) => s.columns.map((c) => c.name)
const labels = (s: SheetState) => s.rows.map((r) => r.cells[LABEL])

describe('version', () => {
  it('bumps by one for every op', () => {
    expect(applyOp(state(), { type: 'rename_sheet', name: 'Q3' }).version).toBe(8)
  })

  it('bumps for a no-op too, because the server does', () => {
    // Moving Q2 to the index it already occupies is accepted server-side and
    // still advances the version; a preview that skipped the bump would make
    // the gap detector misfire.
    const next = applyOp(state(), { type: 'move_column', column_id: Q2, position: 2 })
    expect(next.version).toBe(8)
    expect(names(next)).toEqual(['Line item', 'Q1', 'Q2', 'Notes'])
  })
})

describe('rename_sheet', () => {
  it('stores the name trimmed', () => {
    expect(applyOp(state(), { type: 'rename_sheet', name: '  Q3 plan  ' }).name).toBe('Q3 plan')
  })
})

describe('add_column', () => {
  it('appends when position is omitted', () => {
    const next = applyOp(state(), {
      type: 'add_column',
      id: 'c-new',
      name: 'Q3',
      column_type: 'number',
    })
    expect(names(next)).toEqual(['Line item', 'Q1', 'Q2', 'Notes', 'Q3'])
  })

  it('inserts before the given index', () => {
    const next = applyOp(state(), {
      type: 'add_column',
      id: 'c-new',
      name: 'Q0',
      column_type: 'number',
      position: 1,
    })
    expect(names(next)).toEqual(['Line item', 'Q0', 'Q1', 'Q2', 'Notes'])
  })

  it('accepts position === length as an append', () => {
    const next = applyOp(state(), {
      type: 'add_column',
      id: 'c-new',
      name: 'Q3',
      column_type: 'number',
      position: 4,
    })
    expect(names(next)).toEqual(['Line item', 'Q1', 'Q2', 'Notes', 'Q3'])
  })

  it('keeps the client-generated id and trims the name', () => {
    const next = applyOp(state(), {
      type: 'add_column',
      id: 'c-new',
      name: '  Q3  ',
      column_type: 'number',
    })
    expect(next.columnsById['c-new']).toEqual({
      id: 'c-new',
      name: 'Q3',
      column_type: 'number',
      is_label: false,
    })
  })
})

describe('rename_column', () => {
  it('trims and reindexes', () => {
    const next = applyOp(state(), { type: 'rename_column', column_id: Q1, name: '  First  ' })
    expect(next.columnsById[Q1]?.name).toBe('First')
    expect(names(next)).toEqual(['Line item', 'First', 'Q2', 'Notes'])
  })
})

describe('change_column_type', () => {
  it('converts only rows that hold a value, as a preview', () => {
    const next = applyOp(state(), {
      type: 'change_column_type',
      column_id: Q1,
      column_type: 'text',
    })
    expect(next.columnsById[Q1]?.column_type).toBe('text')
    expect(next.rows[0]?.cells[Q1]).toBe('1200')
    expect(next.rows[1]?.cells[Q1]).toBe('800')
    // r3 never had a Q1 value, so it stays absent rather than becoming "".
    expect(next.rows[2]?.cells[Q1]).toBeUndefined()
  })

  it("prefers the server's converted cells when they are present", () => {
    const applied: AppliedOp = {
      type: 'change_column_type',
      column_id: Q1,
      column_type: 'text',
      cells: [
        { row_id: 'r1', value: 'server-said-this' },
        { row_id: 'r2', value: null },
      ],
    }
    const next = applyOp(state(), applied)
    expect(next.rows[0]?.cells[Q1]).toBe('server-said-this')
    // A value that converts to empty is null on the wire and an absent key here.
    expect(next.rows[1]?.cells[Q1]).toBeUndefined()
  })
})

describe('move_column', () => {
  it('moves to a final index, remove-then-insert', () => {
    // The case engine_test.exs asserts: [label, Q1, Q2, Notes] -> label to 3.
    const next = applyOp(state(), { type: 'move_column', column_id: LABEL, position: 3 })
    expect(names(next)).toEqual(['Q1', 'Q2', 'Notes', 'Line item'])
  })

  it('moves leftward', () => {
    const next = applyOp(state(), { type: 'move_column', column_id: NOTES, position: 0 })
    expect(names(next)).toEqual(['Notes', 'Line item', 'Q1', 'Q2'])
  })
})

describe('delete_column', () => {
  it('removes the column and strips its key from every row', () => {
    const next = applyOp(state(), { type: 'delete_column', column_id: Q1 })
    expect(names(next)).toEqual(['Line item', 'Q2', 'Notes'])
    expect(next.rows.every((r) => r.cells[Q1] === undefined)).toBe(true)
  })

  it('leaves rows that never held the column untouched by identity', () => {
    const before = state()
    const next = applyOp(before, { type: 'delete_column', column_id: Q1 })
    // r3 had no Q1 value, so it keeps its object.
    expect(next.rows[2]).toBe(before.rows[2])
    expect(next.rows[0]).not.toBe(before.rows[0])
  })
})

describe('add_rows', () => {
  it('inserts at the position, with the label trimmed and empties dropped', () => {
    const next = applyOp(state(), {
      type: 'add_rows',
      position: 1,
      rows: [{ id: 'r-new', cells: { [LABEL]: '  Tax  ', [Q1]: null, [Q2]: 5 } }],
    })
    expect(labels(next)).toEqual(['Revenue', 'Tax', 'Costs', 'Margin'])
    expect(next.rows[1]?.cells).toEqual({ [LABEL]: 'Tax', [Q2]: 5 })
    expect(next.rowIndexById['r-new']).toBe(1)
  })

  it('appends when position is omitted', () => {
    const next = applyOp(state(), {
      type: 'add_rows',
      rows: [{ id: 'r-new', cells: { [LABEL]: 'Tax' } }],
    })
    expect(labels(next)).toEqual(['Revenue', 'Costs', 'Margin', 'Tax'])
  })

  it('keeps consecutive order for several rows', () => {
    const next = applyOp(state(), {
      type: 'add_rows',
      position: 0,
      rows: [
        { id: 'a', cells: { [LABEL]: 'A' } },
        { id: 'b', cells: { [LABEL]: 'B' } },
      ],
    })
    expect(labels(next)).toEqual(['A', 'B', 'Revenue', 'Costs', 'Margin'])
  })
})

describe('delete_rows', () => {
  it('removes every listed row and reindexes', () => {
    const next = applyOp(state(), { type: 'delete_rows', row_ids: ['r1', 'r3'] })
    expect(labels(next)).toEqual(['Costs'])
    expect(next.rowIndexById['r2']).toBe(0)
    expect(next.rowIndexById['r1']).toBeUndefined()
  })
})

describe('move_row', () => {
  it('moves to a final index', () => {
    const next = applyOp(state(), { type: 'move_row', row_id: 'r1', position: 2 })
    expect(labels(next)).toEqual(['Costs', 'Margin', 'Revenue'])
  })
})

describe('set_cells', () => {
  it('writes values and deletes the key on null', () => {
    const next = applyOp(state(), {
      type: 'set_cells',
      cells: [
        { row_id: 'r1', column_id: Q2, value: 99 },
        { row_id: 'r1', column_id: NOTES, value: null },
      ],
    })
    expect(next.rows[0]?.cells[Q2]).toBe(99)
    expect(next.rows[0]?.cells).not.toHaveProperty(NOTES)
  })

  it('composes two edits to the same row, in op order', () => {
    const next = applyOp(state(), {
      type: 'set_cells',
      cells: [
        { row_id: 'r1', column_id: Q2, value: 1 },
        { row_id: 'r1', column_id: Q2, value: 2 },
      ],
    })
    expect(next.rows[0]?.cells[Q2]).toBe(2)
  })

  it('trims a label cell, because setting one renames the row', () => {
    const next = applyOp(state(), {
      type: 'set_cells',
      cells: [{ row_id: 'r2', column_id: LABEL, value: '  Expenses  ' }],
    })
    expect(next.rows[1]?.cells[LABEL]).toBe('Expenses')
  })

  it('does not trim an ordinary text cell', () => {
    const next = applyOp(state(), {
      type: 'set_cells',
      cells: [{ row_id: 'r2', column_id: NOTES, value: '  loose  ' }],
    })
    expect(next.rows[1]?.cells[NOTES]).toBe('  loose  ')
  })

  it('swaps two labels in one op', () => {
    const next = applyOp(state(), {
      type: 'set_cells',
      cells: [
        { row_id: 'r1', column_id: LABEL, value: 'Costs' },
        { row_id: 'r2', column_id: LABEL, value: 'Revenue' },
      ],
    })
    expect(labels(next)).toEqual(['Costs', 'Revenue', 'Margin'])
  })

  it('gives only the touched rows new objects', () => {
    const before = state()
    const next = applyOp(before, {
      type: 'set_cells',
      cells: [{ row_id: 'r2', column_id: Q2, value: 5 }],
    })
    expect(next.rows[1]).not.toBe(before.rows[1])
    expect(next.rows[0]).toBe(before.rows[0])
    expect(next.rows[2]).toBe(before.rows[2])
    // The array itself is always replaced, so TanStack's shallow watch fires.
    expect(next.rows).not.toBe(before.rows)
  })
})

describe('create_sheet', () => {
  it('replaces the columns and rows wholesale', () => {
    const applied: AppliedOp = {
      type: 'create_sheet',
      name: 'Fresh',
      columns: [{ id: 'x', name: 'Item', column_type: 'text', is_label: true }],
      rows: [{ id: 'y', cells: { x: 'One' } }],
    }
    const next = applyOp(state(), applied)
    expect(next.name).toBe('Fresh')
    expect(next.labelColumnId).toBe('x')
    expect(next.rows).toHaveLength(1)
    expect(next.rowIndexById['y']).toBe(0)
  })
})

describe('purity', () => {
  it('never mutates the input state', () => {
    const before = state()
    const snapshot = JSON.stringify(before)
    const ops: Op[] = [
      { type: 'rename_sheet', name: 'x' },
      { type: 'add_column', id: 'c', name: 'C', column_type: 'text' },
      { type: 'delete_column', column_id: Q1 },
      { type: 'add_rows', rows: [{ id: 'n', cells: { [LABEL]: 'N' } }] },
      { type: 'delete_rows', row_ids: ['r1'] },
      { type: 'move_row', row_id: 'r1', position: 2 },
      { type: 'move_column', column_id: Q1, position: 0 },
      { type: 'set_cells', cells: [{ row_id: 'r1', column_id: Q1, value: 1 }] },
      { type: 'change_column_type', column_id: Q1, column_type: 'text' },
    ]
    for (const op of ops) applyOp(before, op)
    expect(JSON.stringify(before)).toBe(snapshot)
  })
})
