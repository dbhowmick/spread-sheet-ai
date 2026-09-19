import { describe, expect, it } from 'vitest'

import {
  EMPTY_NAV_GRID,
  NO_ACTIVE,
  cellDomId,
  editorIntent,
  gridIntent,
  move,
  navGrid,
  printableChar,
  reconcileActive,
  reconcileEditing,
  scrollLeftFor,
  setActive,
  withIndex,
  type GridKeyContext,
  type KeyEventLike,
  type Move,
} from '@/lib/sheet/navigation'

// A 3 × 3 grid: rows r0..r2, columns label, a, b (label pinned first).
const grid = navGrid(['r0', 'r1', 'r2'], ['c-label', 'c-a', 'c-b'])

const at = (rowId: string, columnId: string) => ({ rowId, columnId })

describe('move', () => {
  const cases: [string, Move, string, string][] = [
    ['down', { kind: 'delta', rows: 1, columns: 0 }, 'r1:c-a', 'r2:c-a'],
    ['up', { kind: 'delta', rows: -1, columns: 0 }, 'r1:c-a', 'r0:c-a'],
    ['right', { kind: 'delta', rows: 0, columns: 1 }, 'r1:c-a', 'r1:c-b'],
    ['left', { kind: 'delta', rows: 0, columns: -1 }, 'r1:c-a', 'r1:c-label'],
    ['Home', { kind: 'rowEdge', edge: 'first' }, 'r1:c-a', 'r1:c-label'],
    ['End', { kind: 'rowEdge', edge: 'last' }, 'r1:c-a', 'r1:c-b'],
    ['Ctrl+Home', { kind: 'gridEdge', edge: 'first' }, 'r1:c-a', 'r0:c-label'],
    ['Ctrl+End', { kind: 'gridEdge', edge: 'last' }, 'r1:c-a', 'r2:c-b'],
  ]

  it.each(cases)('moves %s', (_name, m, from, expected) => {
    const [rowId, columnId] = from.split(':') as [string, string]
    expect(move(grid, at(rowId, columnId), m)).toEqual({
      rowId: expected.split(':')[0],
      columnId: expected.split(':')[1],
    })
  })

  it('clamps at every edge rather than wrapping', () => {
    const up: Move = { kind: 'delta', rows: -1, columns: 0 }
    const down: Move = { kind: 'delta', rows: 1, columns: 0 }
    const left: Move = { kind: 'delta', rows: 0, columns: -1 }
    const right: Move = { kind: 'delta', rows: 0, columns: 1 }

    expect(move(grid, at('r0', 'c-label'), up)).toEqual(at('r0', 'c-label'))
    expect(move(grid, at('r0', 'c-label'), left)).toEqual(at('r0', 'c-label'))
    expect(move(grid, at('r2', 'c-b'), down)).toEqual(at('r2', 'c-b'))
    expect(move(grid, at('r2', 'c-b'), right)).toEqual(at('r2', 'c-b'))
  })

  it('jumps a page at a time, stopping at the end', () => {
    const tall = navGrid(
      Array.from({ length: 30 }, (_, i) => `r${i}`),
      ['c-a'],
    )
    expect(move(tall, at('r0', 'c-a'), { kind: 'delta', rows: 20, columns: 0 })).toEqual(
      at('r20', 'c-a'),
    )
    expect(move(tall, at('r25', 'c-a'), { kind: 'delta', rows: 20, columns: 0 })).toEqual(
      at('r29', 'c-a'),
    )
  })

  it('lands on the first cell when nothing is active yet', () => {
    expect(move(grid, null, { kind: 'delta', rows: 1, columns: 0 })).toEqual(at('r0', 'c-label'))
  })

  it('has nowhere to go on an empty grid', () => {
    expect(move(EMPTY_NAV_GRID, null, { kind: 'delta', rows: 1, columns: 0 })).toBeNull()
    expect(move(navGrid([], ['c-a']), null, { kind: 'gridEdge', edge: 'last' })).toBeNull()
  })
})

describe('Tab', () => {
  const tab: Move = { kind: 'tab', back: false }
  const shiftTab: Move = { kind: 'tab', back: true }

  it('moves within the row like an arrow', () => {
    expect(move(grid, at('r1', 'c-label'), tab)).toEqual(at('r1', 'c-a'))
    expect(move(grid, at('r1', 'c-a'), shiftTab)).toEqual(at('r1', 'c-label'))
  })

  it('wraps to the next row, where ArrowRight would clamp', () => {
    expect(move(grid, at('r1', 'c-b'), tab)).toEqual(at('r2', 'c-label'))
    expect(move(grid, at('r1', 'c-b'), { kind: 'delta', rows: 0, columns: 1 })).toEqual(
      at('r1', 'c-b'),
    )
  })

  it('wraps backwards to the previous row', () => {
    expect(move(grid, at('r1', 'c-label'), shiftTab)).toEqual(at('r0', 'c-b'))
  })

  it('stays put at the two grid corners', () => {
    expect(move(grid, at('r2', 'c-b'), tab)).toEqual(at('r2', 'c-b'))
    expect(move(grid, at('r0', 'c-label'), shiftTab)).toEqual(at('r0', 'c-label'))
  })
})

describe('the active cell surviving remote changes', () => {
  const active = setActive(grid, at('r1', 'c-a'))

  it('remembers where the cell sat', () => {
    expect(active).toEqual({ cell: at('r1', 'c-a'), lastPos: { row: 1, column: 1 } })
  })

  it('keeps the same ids when a row is inserted above (§7.4)', () => {
    const inserted = navGrid(['new', 'r0', 'r1', 'r2'], ['c-label', 'c-a', 'c-b'])
    expect(reconcileActive(active, inserted)).toEqual({
      cell: at('r1', 'c-a'),
      lastPos: { row: 2, column: 1 },
    })
  })

  it('lands on the row that took its place when its row is deleted', () => {
    const without = navGrid(['r0', 'r2'], ['c-label', 'c-a', 'c-b'])
    expect(reconcileActive(active, without).cell).toEqual(at('r2', 'c-a'))
  })

  it('lands on the new last row when the last row is deleted', () => {
    const last = setActive(grid, at('r2', 'c-a'))
    const without = navGrid(['r0', 'r1'], ['c-label', 'c-a', 'c-b'])
    expect(reconcileActive(last, without).cell).toEqual(at('r1', 'c-a'))
  })

  it('moves to the neighbouring column when its column is deleted', () => {
    const without = navGrid(['r0', 'r1', 'r2'], ['c-label', 'c-b'])
    expect(reconcileActive(active, without).cell).toEqual(at('r1', 'c-b'))
  })

  it('clamps both axes when the row and the column go at once', () => {
    const corner = setActive(grid, at('r2', 'c-b'))
    const shrunk = navGrid(['r0'], ['c-label'])
    expect(reconcileActive(corner, shrunk).cell).toEqual(at('r0', 'c-label'))
  })

  it('has no active cell once the sheet is empty', () => {
    expect(reconcileActive(active, navGrid([], ['c-a']))).toEqual(NO_ACTIVE)
  })

  it('abandons an edit whose cell was deleted, and keeps one that survived', () => {
    const editing = { cell: at('r1', 'c-a'), initialInput: null, error: null }
    expect(reconcileEditing(editing, grid)).toBe(editing)
    expect(reconcileEditing(editing, navGrid(['r0'], ['c-label']))).toBeNull()
    expect(reconcileEditing(null, grid)).toBeNull()
  })
})

describe('gridIntent', () => {
  const key = (k: string, mods: Partial<KeyEventLike> = {}): KeyEventLike => ({
    key: k,
    ctrlKey: false,
    metaKey: false,
    shiftKey: false,
    altKey: false,
    ...mods,
  })

  const ctx = (over: Partial<GridKeyContext> = {}): GridKeyContext => ({
    hasActive: true,
    columnType: 'text',
    isLabelColumn: false,
    ...over,
  })

  it('maps the arrows and edges to moves', () => {
    expect(gridIntent(key('ArrowDown'), ctx())).toEqual({
      kind: 'move',
      move: { kind: 'delta', rows: 1, columns: 0 },
    })
    expect(gridIntent(key('Home'), ctx())).toEqual({
      kind: 'move',
      move: { kind: 'rowEdge', edge: 'first' },
    })
    expect(gridIntent(key('Home', { ctrlKey: true }), ctx())).toEqual({
      kind: 'move',
      move: { kind: 'gridEdge', edge: 'first' },
    })
    expect(gridIntent(key('Tab', { shiftKey: true }), ctx())).toEqual({
      kind: 'move',
      move: { kind: 'tab', back: true },
    })
  })

  it('leaves the clipboard shortcuts to the browser', () => {
    for (const k of ['c', 'v', 'x']) {
      expect(gridIntent(key(k, { ctrlKey: true }), ctx())).toEqual({ kind: 'native' })
      expect(gridIntent(key(k, { metaKey: true }), ctx())).toEqual({ kind: 'native' })
    }
  })

  it('starts an edit on Enter, F2 and a printable character', () => {
    expect(gridIntent(key('Enter'), ctx())).toEqual({ kind: 'edit', initialInput: null })
    expect(gridIntent(key('F2'), ctx())).toEqual({ kind: 'edit', initialInput: null })
    expect(gridIntent(key('7'), ctx({ columnType: 'number' }))).toEqual({
      kind: 'edit',
      initialInput: '7',
    })
  })

  it('clears a cell, but refuses to clear a label', () => {
    expect(gridIntent(key('Delete'), ctx())).toEqual({ kind: 'clear' })
    expect(gridIntent(key('Backspace'), ctx())).toEqual({ kind: 'clear' })
    expect(gridIntent(key('Delete'), ctx({ isLabelColumn: true }))).toEqual({
      kind: 'refuse',
      reason: expect.any(String),
    })
  })

  it('toggles a boolean on Space and never opens an editor on one', () => {
    const boolean = ctx({ columnType: 'boolean' })
    expect(gridIntent(key(' '), boolean)).toEqual({ kind: 'toggle' })
    expect(gridIntent(key('y'), boolean)).toEqual({ kind: 'ignore' })
    expect(gridIntent(key('Enter'), boolean)).toEqual({ kind: 'edit', initialInput: null })
  })

  it('ignores editing keys while nothing is active, but still moves', () => {
    const none = ctx({ hasActive: false, columnType: null })
    expect(gridIntent(key('Enter'), none)).toEqual({ kind: 'ignore' })
    expect(gridIntent(key('a'), none)).toEqual({ kind: 'ignore' })
    expect(gridIntent(key('ArrowDown'), none).kind).toBe('move')
  })

  it('ignores keys that mean nothing here', () => {
    expect(gridIntent(key('Shift'), ctx())).toEqual({ kind: 'ignore' })
    expect(gridIntent(key('a', { ctrlKey: true }), ctx())).toEqual({ kind: 'ignore' })
  })
})

describe('printableChar', () => {
  it('takes a single character typed with no modifier', () => {
    const base = { ctrlKey: false, metaKey: false, shiftKey: false, altKey: false }
    expect(printableChar({ ...base, key: 'a' })).toBe('a')
    expect(printableChar({ ...base, key: 'A', shiftKey: true })).toBe('A')
    expect(printableChar({ ...base, key: 'Enter' })).toBeNull()
    expect(printableChar({ ...base, key: 'a', ctrlKey: true })).toBeNull()
  })
})

describe('editorIntent', () => {
  const key = (k: string, shiftKey = false): KeyEventLike => ({
    key: k,
    ctrlKey: false,
    metaKey: false,
    shiftKey,
    altKey: false,
  })

  it('commits and moves down on Enter, right on Tab, left on Shift+Tab', () => {
    expect(editorIntent(key('Enter'))).toEqual({
      kind: 'commit',
      next: { kind: 'delta', rows: 1, columns: 0 },
    })
    expect(editorIntent(key('Tab'))).toEqual({
      kind: 'commit',
      next: { kind: 'delta', rows: 0, columns: 1 },
    })
    expect(editorIntent(key('Tab', true))).toEqual({
      kind: 'commit',
      next: { kind: 'delta', rows: 0, columns: -1 },
    })
  })

  it('cancels on Escape and leaves everything else to the input', () => {
    expect(editorIntent(key('Escape'))).toEqual({ kind: 'cancel' })
    expect(editorIntent(key('ArrowLeft'))).toEqual({ kind: 'ignore' })
    expect(editorIntent(key('a'))).toEqual({ kind: 'ignore' })
  })
})

describe('scrollLeftFor', () => {
  // 600px viewport, 248px of pinned columns.
  const base = { scrollLeft: 0, viewport: 600, frozen: 248 }

  it('leaves a fully visible column alone', () => {
    expect(scrollLeftFor({ ...base, start: 300, size: 140 })).toBeNull()
  })

  it('scrolls a column out from under the pinned edge', () => {
    expect(scrollLeftFor({ ...base, scrollLeft: 400, start: 500, size: 140 })).toBe(500 - 248)
  })

  it('scrolls a column past the right edge into view', () => {
    expect(scrollLeftFor({ ...base, start: 700, size: 140 })).toBe(700 + 140 - 600)
  })

  it('never scrolls past the start', () => {
    expect(scrollLeftFor({ ...base, scrollLeft: 100, start: 40, size: 140 })).toBe(0)
  })
})

describe('withIndex', () => {
  it('keeps the active row in the virtual range, in order', () => {
    expect(withIndex([10, 11, 12], 400)).toEqual([10, 11, 12, 400])
    expect(withIndex([10, 11, 12], 2)).toEqual([2, 10, 11, 12])
  })

  it('changes nothing when the row is already there, or there is none', () => {
    const range = [10, 11, 12]
    expect(withIndex(range, 11)).toBe(range)
    expect(withIndex(range, null)).toBe(range)
  })
})

describe('cellDomId', () => {
  it('is stable per cell, so rows never subscribe to the active cell', () => {
    expect(cellDomId('grid1', 'r1', 'c-a')).toBe('grid1-c-r1-c-a')
  })
})
