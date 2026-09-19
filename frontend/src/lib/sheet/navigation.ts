/**
 * Grid navigation as pure functions (frontend-plan §7.4).
 *
 * Everything here is plain data: where a move lands, what a keystroke means,
 * and how the active cell survives someone else deleting its row. The
 * composable in `composables/useGridNavigation.ts` owns the refs, the DOM and
 * the ops; this file owns the decisions, so they can be tested without a
 * browser.
 *
 * Positions are **visual**, not `SheetState` order: the label column is pinned
 * and renders first whatever its position, so Tab and Home must follow the
 * order the user sees. The caller passes the ids in render order.
 */
import type { ColumnId, ColumnType, RowId } from '@/types/contract'

export interface CellRef {
  rowId: RowId
  columnId: ColumnId
}

export interface CellPos {
  row: number
  column: number
}

/** Rows and columns in render order. The gutter is never navigable. */
export interface NavGrid {
  rowIds: readonly RowId[]
  columnIds: readonly ColumnId[]
  rowIndex: ReadonlyMap<RowId, number>
  columnIndex: ReadonlyMap<ColumnId, number>
}

export function navGrid(rowIds: readonly RowId[], columnIds: readonly ColumnId[]): NavGrid {
  return {
    rowIds,
    columnIds,
    rowIndex: new Map(rowIds.map((id, i) => [id, i])),
    columnIndex: new Map(columnIds.map((id, i) => [id, i])),
  }
}

export const EMPTY_NAV_GRID: NavGrid = navGrid([], [])

export function isEmpty(grid: NavGrid): boolean {
  return grid.rowIds.length === 0 || grid.columnIds.length === 0
}

export function posOf(grid: NavGrid, cell: CellRef): CellPos | null {
  const row = grid.rowIndex.get(cell.rowId)
  const column = grid.columnIndex.get(cell.columnId)
  if (row === undefined || column === undefined) return null
  return { row, column }
}

export function cellAt(grid: NavGrid, pos: CellPos): CellRef | null {
  const rowId = grid.rowIds[pos.row]
  const columnId = grid.columnIds[pos.column]
  if (rowId === undefined || columnId === undefined) return null
  return { rowId, columnId }
}

function clamp(value: number, max: number): number {
  return value < 0 ? 0 : value > max ? max : value
}

export type Move =
  /** Arrows and PageUp/PageDown. Clamps at the edges. */
  | { kind: 'delta'; rows: number; columns: number }
  /** Tab / Shift+Tab. Wraps onto the next or previous row, unlike an arrow. */
  | { kind: 'tab'; back: boolean }
  /** Home / End. */
  | { kind: 'rowEdge'; edge: 'first' | 'last' }
  /** Ctrl+Home / Ctrl+End. */
  | { kind: 'gridEdge'; edge: 'first' | 'last' }

export const MOVE_DOWN: Move = { kind: 'delta', rows: 1, columns: 0 }
export const MOVE_RIGHT: Move = { kind: 'delta', rows: 0, columns: 1 }
export const MOVE_LEFT: Move = { kind: 'delta', rows: 0, columns: -1 }

export function firstCell(grid: NavGrid): CellRef | null {
  return cellAt(grid, { row: 0, column: 0 })
}

function lastPos(grid: NavGrid): CellPos {
  return { row: grid.rowIds.length - 1, column: grid.columnIds.length - 1 }
}

/**
 * Where a move lands, or `null` on an empty grid. With no active cell any move
 * lands on the first cell, so the first arrow key after clicking into the grid
 * does something sensible.
 */
export function move(grid: NavGrid, from: CellRef | null, m: Move): CellRef | null {
  if (isEmpty(grid)) return null

  const at = from ? posOf(grid, from) : null
  if (!at) return firstCell(grid)

  const maxRow = grid.rowIds.length - 1
  const maxColumn = grid.columnIds.length - 1

  switch (m.kind) {
    case 'delta':
      return cellAt(grid, {
        row: clamp(at.row + m.rows, maxRow),
        column: clamp(at.column + m.columns, maxColumn),
      })

    case 'tab': {
      const next = at.column + (m.back ? -1 : 1)
      if (next >= 0 && next <= maxColumn) return cellAt(grid, { row: at.row, column: next })
      // Wrap: off the end goes to the next row's first column, and off the
      // start to the previous row's last. Stay put at the two grid corners.
      const row = at.row + (m.back ? -1 : 1)
      if (row < 0 || row > maxRow) return cellAt(grid, at)
      return cellAt(grid, { row, column: m.back ? maxColumn : 0 })
    }

    case 'rowEdge':
      return cellAt(grid, { row: at.row, column: m.edge === 'first' ? 0 : maxColumn })

    case 'gridEdge':
      return m.edge === 'first' ? firstCell(grid) : cellAt(grid, lastPos(grid))
  }
}

/**
 * The active cell, plus where it last sat. The index is what makes "the active
 * cell moves to the nearest remaining neighbour" possible: once the row is
 * gone there is nothing left to search from.
 */
export interface ActiveCell {
  cell: CellRef | null
  lastPos: CellPos | null
}

export const NO_ACTIVE: ActiveCell = { cell: null, lastPos: null }

export function setActive(grid: NavGrid, cell: CellRef | null): ActiveCell {
  if (!cell) return NO_ACTIVE
  return { cell, lastPos: posOf(grid, cell) }
}

/**
 * Re-anchors the active cell against a new view.
 *
 * If its ids still resolve, they are kept — so a remote insert above, or a
 * move, is a no-op for the user even though the cell's index changed. If they
 * don't, each axis clamps its remembered index into the new bounds: deleting
 * row `i` lands on whatever holds index `i` now (the row below), and deleting
 * the last row lands on the new last row.
 */
export function reconcileActive(prev: ActiveCell, grid: NavGrid): ActiveCell {
  if (isEmpty(grid)) return NO_ACTIVE
  if (!prev.cell) return NO_ACTIVE

  const at = posOf(grid, prev.cell)
  if (at) return { cell: prev.cell, lastPos: at }

  const from = prev.lastPos
  if (!from) return NO_ACTIVE

  const pos = {
    row: clamp(from.row, grid.rowIds.length - 1),
    column: clamp(from.column, grid.columnIds.length - 1),
  }
  const cell = cellAt(grid, pos)
  return cell ? { cell, lastPos: pos } : NO_ACTIVE
}

/** What the user is typing into, while an editor is open. */
export interface EditingState {
  cell: CellRef
  /** The character that started the edit, when it started by typing. */
  initialInput: string | null
  /** A failed parse or label check: the editor shows it and stays open. */
  error: string | null
}

/** An edit whose cell has been deleted under it is abandoned. */
export function reconcileEditing(editing: EditingState | null, grid: NavGrid): EditingState | null {
  if (!editing) return null
  return posOf(grid, editing.cell) ? editing : null
}

/** The part of a `KeyboardEvent` the pure mapping needs. */
export interface KeyEventLike {
  key: string
  ctrlKey: boolean
  metaKey: boolean
  shiftKey: boolean
  altKey: boolean
}

export interface GridKeyContext {
  hasActive: boolean
  /** The active column's type, or `null` when nothing is active. */
  columnType: ColumnType | null
  isLabelColumn: boolean
}

export type GridIntent =
  | { kind: 'move'; move: Move }
  | { kind: 'edit'; initialInput: string | null }
  | { kind: 'clear' }
  | { kind: 'toggle' }
  /** Delete on the label column: a label is required (contract §6). */
  | { kind: 'refuse'; reason: string }
  /** Ctrl/Cmd+C/V/X — let the browser fire its own clipboard event. */
  | { kind: 'native' }
  | { kind: 'ignore' }

const IGNORE: GridIntent = { kind: 'ignore' }

/** A single character typed with no modifier starts an edit with that text. */
export function printableChar(e: KeyEventLike): string | null {
  if (e.ctrlKey || e.metaKey || e.altKey) return null
  return e.key.length === 1 ? e.key : null
}

/** How far PageUp/PageDown jump. Roughly a screenful at `ROW_HEIGHT`. */
const PAGE_ROWS = 20

const ROW_START: Move = { kind: 'rowEdge', edge: 'first' }
const ROW_END: Move = { kind: 'rowEdge', edge: 'last' }

/**
 * What a keystroke means over the grid, when no editor is open. The caller
 * `preventDefault`s everything except `native` and `ignore`.
 */
export function gridIntent(e: KeyEventLike, ctx: GridKeyContext): GridIntent {
  const mod = e.ctrlKey || e.metaKey

  if (mod && (e.key === 'c' || e.key === 'v' || e.key === 'x')) return { kind: 'native' }

  switch (e.key) {
    case 'ArrowUp':
      return { kind: 'move', move: { kind: 'delta', rows: -1, columns: 0 } }
    case 'ArrowDown':
      return { kind: 'move', move: MOVE_DOWN }
    case 'ArrowLeft':
      return { kind: 'move', move: MOVE_LEFT }
    case 'ArrowRight':
      return { kind: 'move', move: MOVE_RIGHT }
    case 'PageUp':
      return { kind: 'move', move: { kind: 'delta', rows: -PAGE_ROWS, columns: 0 } }
    case 'PageDown':
      return { kind: 'move', move: { kind: 'delta', rows: PAGE_ROWS, columns: 0 } }
    case 'Tab':
      return { kind: 'move', move: { kind: 'tab', back: e.shiftKey } }
    case 'Home':
      return { kind: 'move', move: mod ? { kind: 'gridEdge', edge: 'first' } : ROW_START }
    case 'End':
      return { kind: 'move', move: mod ? { kind: 'gridEdge', edge: 'last' } : ROW_END }
  }

  if (!ctx.hasActive) return IGNORE

  switch (e.key) {
    case 'Enter':
    case 'F2':
      return { kind: 'edit', initialInput: null }

    case ' ':
      return ctx.columnType === 'boolean' ? { kind: 'toggle' } : { kind: 'edit', initialInput: ' ' }

    case 'Delete':
    case 'Backspace':
      return ctx.isLabelColumn
        ? { kind: 'refuse', reason: 'Every row needs a label.' }
        : { kind: 'clear' }
  }

  // Booleans have no editor; typing into one would have nowhere to go.
  if (ctx.columnType === 'boolean') return IGNORE

  const char = printableChar(e)
  return char === null ? IGNORE : { kind: 'edit', initialInput: char }
}

export type EditorIntent =
  /**
   * Commit, then optionally move: Enter goes down, Tab right, Shift+Tab left.
   * The field is `next`, not `then`: an object with a `then` is thenable, and
   * awaiting one anywhere would silently try to call it.
   */
  { kind: 'commit'; next: Move | null } | { kind: 'cancel' } | { kind: 'ignore' }

/** What a keystroke means inside an open editor (frontend-plan §7.4). */
export function editorIntent(e: KeyEventLike): EditorIntent {
  switch (e.key) {
    case 'Enter':
      return { kind: 'commit', next: MOVE_DOWN }
    case 'Tab':
      return { kind: 'commit', next: e.shiftKey ? MOVE_LEFT : MOVE_RIGHT }
    case 'Escape':
      return { kind: 'cancel' }
    default:
      return { kind: 'ignore' }
  }
}

/**
 * Horizontal scrolling. The row virtualizer only handles the vertical axis,
 * and `frozen` is the pinned start edge the target must clear, or it lands
 * underneath the sticky label column.
 */
export interface HScroll {
  scrollLeft: number
  /** The scroll container's inner width. */
  viewport: number
  /** Total width of the pinned start columns. */
  frozen: number
  /** The target column's offset and width. */
  start: number
  size: number
}

/** The `scrollLeft` that brings a column into view, or `null` if it already is. */
export function scrollLeftFor(v: HScroll): number | null {
  // The pinned columns sit on top of the scrolled content, so the usable
  // viewport starts after them.
  const visibleStart = v.scrollLeft + v.frozen
  const visibleEnd = v.scrollLeft + v.viewport

  if (v.start < visibleStart) return Math.max(0, v.start - v.frozen)
  if (v.start + v.size > visibleEnd) return v.start + v.size - v.viewport
  return null
}

/**
 * Forces an index into a sorted range, for the virtualizer's `rangeExtractor`.
 * Keeping the active row mounted is what lets an open editor survive being
 * scrolled away, and keeps `aria-activedescendant` pointing at a real element.
 */
export function withIndex(indices: number[], extra: number | null): number[] {
  if (extra === null || indices.includes(extra)) return indices
  return [...indices, extra].sort((a, b) => a - b)
}

/** A stable DOM id per cell, for `aria-activedescendant`. */
export function cellDomId(gridId: string, rowId: RowId, columnId: ColumnId): string {
  return `${gridId}-c-${rowId}-${columnId}`
}
