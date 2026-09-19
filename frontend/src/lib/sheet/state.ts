/**
 * `SheetState` — the client's view of a sheet (frontend-plan §6.1).
 *
 * Deliberately *not* in `types/contract.ts`: that file mirrors the wire, this
 * is derived. It is also flatter than the server's `Sheets.State`, which keeps
 * order as separate id lists and holds a row's label outside its `values`. Two
 * reasons to diverge:
 *
 *   * the wire `Row.cells` already includes the label column's value
 *     (contract §2.4), so there is nothing to splice back in; and
 *   * F3's TanStack grid wants `rows: Row[]` in display order so it can use
 *     `accessorFn: r => r.cells[columnId]` and a shallow `data` watch.
 *
 * The `*ById` maps are derived indexes, always rebuilt alongside the arrays
 * they index.
 *
 * **Identity rules (frontend-plan §6.1).** A changed row gets a *new* object;
 * every unchanged row keeps its old object, which keeps Vue's per-row render
 * work down. The `rows` array itself is replaced on every change, so
 * TanStack's shallow `data` watch fires. Same for `columns`.
 */
import type {
  CellValue,
  Column,
  ColumnId,
  Iso8601,
  Row,
  RowId,
  Sheet,
  SheetId,
  UserRef,
} from '@/types/contract'

export interface SheetState {
  id: SheetId
  name: string
  owner: UserRef
  version: number
  /** Display order; a column's position is its index here. */
  columns: Column[]
  columnsById: Record<ColumnId, Column>
  /** The one `is_label` column. Always `text`, never empty (contract §2.2). */
  labelColumnId: ColumnId
  /** Display order; a row's position is its index here. */
  rows: Row[]
  rowIndexById: Record<RowId, number>
  inserted_at: Iso8601
  updated_at: Iso8601
}

/** Keys a single cell for the cue map. */
export function cellKey(rowId: RowId, columnId: ColumnId): string {
  return `${rowId}:${columnId}`
}

export function indexColumns(columns: Column[]): Record<ColumnId, Column> {
  const byId: Record<ColumnId, Column> = {}
  for (const column of columns) byId[column.id] = column
  return byId
}

export function indexRows(rows: Row[]): Record<RowId, number> {
  const byId: Record<RowId, number> = {}
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]
    if (row) byId[row.id] = i
  }
  return byId
}

/**
 * Finds the label column. The server guarantees exactly one per sheet (a
 * partial unique index plus a check constraint that it is text), so the
 * fallback to the first column is defensive only.
 */
export function findLabelColumnId(columns: Column[]): ColumnId {
  return columns.find((c) => c.is_label)?.id ?? columns[0]?.id ?? ''
}

/** Builds state from a join reply or a `snapshot` reply (contract §2.6). */
export function fromSheet(sheet: Sheet): SheetState {
  return {
    id: sheet.id,
    name: sheet.name,
    owner: sheet.owner,
    version: sheet.version,
    columns: sheet.columns,
    columnsById: indexColumns(sheet.columns),
    labelColumnId: findLabelColumnId(sheet.columns),
    rows: sheet.rows,
    rowIndexById: indexRows(sheet.rows),
    inserted_at: sheet.inserted_at,
    updated_at: sheet.updated_at,
  }
}

/**
 * Replaces `columns` and reindexes. `labelColumnId` is recomputed because
 * `delete_column` can (in principle) remove columns around it, and a fresh
 * lookup is cheaper than reasoning about which ops can move it.
 */
export function withColumns(state: SheetState, columns: Column[]): SheetState {
  return {
    ...state,
    columns,
    columnsById: indexColumns(columns),
    labelColumnId: findLabelColumnId(columns),
  }
}

export function withRows(state: SheetState, rows: Row[]): SheetState {
  return { ...state, rows, rowIndexById: indexRows(rows) }
}

/**
 * Reads a cell, collapsing "missing key" and `null` — contract §2.4 says they
 * mean the same thing, and `noUncheckedIndexedAccess` types the raw read as
 * `CellValue | undefined` precisely so this normalizer has to be used.
 */
export function cellOf(row: Row, columnId: ColumnId): CellValue {
  return row.cells[columnId] ?? null
}

/**
 * Writes a cell the way the server stores it: `null` **deletes the key**
 * rather than storing an explicit null (`Engine.Checks.put_value/3` does
 * `Map.delete`). Keeping that exact is what lets state built by replaying ops
 * compare equal to a fresh snapshot.
 */
export function putCell(cells: Row['cells'], columnId: ColumnId, value: CellValue): Row['cells'] {
  const next = { ...cells }
  if (value === null) delete next[columnId]
  else next[columnId] = value
  return next
}
