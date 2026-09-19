/**
 * `applyOp(state, op)` — the one pure function that applies both a local
 * preview (`Op`) and a confirmed server broadcast (`AppliedOp`)
 * (frontend-plan §6.3).
 *
 * It **assumes validity**: invalid local ops are caught earlier by `values.ts`
 * and the store's pre-send checks, and the server is authoritative regardless.
 * So there is no error path — every call returns a new state at
 * `version + 1`. That matters: the server bumps the version for *every*
 * accepted op including no-ops (moving to the current index, renaming to the
 * same name), so a preview that skipped the bump would make the gap detector
 * in `consistency.ts` misfire.
 *
 * `AppliedOp` variants extend their `Op` counterparts, so a `switch` over
 * `Op | AppliedOp` narrows each branch to the *looser* variant. Applied-only
 * fields are read with an `in` check.
 *
 * Server source: `lib/spread_sheet_ai/sheets/engine.ex` and `engine/`.
 */
import type {
  AppliedOp,
  CellMap,
  CellValue,
  Column,
  ColumnId,
  Op,
  Row,
  RowId,
} from '@/types/contract'

import { putCell, withColumns, withRows, type SheetState } from './state'
import { convertValue } from './values'

/**
 * Mirrors the engine's `Enum.split/2` + concat. `at` is in `0..length`
 * inclusive; the server rejects anything outside that with `invalid_position`
 * rather than clamping, so this does not clamp either.
 */
function insertAt<T>(items: T[], at: number, inserted: T[]): T[] {
  return [...items.slice(0, at), ...inserted, ...items.slice(at)]
}

/**
 * Mirrors `State.move_id/3` = `List.delete(id) |> List.insert_at(to, id)`:
 * **remove first, then insert at `to` in the shortened list**. `to` is the
 * item's final index, in `0..length-1`. Splicing into the original array
 * instead would be off by one whenever the item moves rightward.
 */
function moveItem<T>(items: T[], from: number, to: number): T[] {
  const next = items.slice()
  const [item] = next.splice(from, 1)
  if (item === undefined) return items
  next.splice(to, 0, item)
  return next
}

/**
 * Normalizes a row's cells the way the server stores them: empty values are
 * *absent keys* rather than explicit nulls, and the label is trimmed (ordinary
 * text is not).
 */
function normalizeCells(cells: CellMap, labelColumnId: ColumnId): CellMap {
  const next: CellMap = {}
  for (const [columnId, value] of Object.entries(cells)) {
    if (value === null || value === undefined) continue
    next[columnId] = columnId === labelColumnId && typeof value === 'string' ? value.trim() : value
  }
  return next
}

/** Replaces one row by id, giving *only* that row a new object. */
function replaceRow(rows: Row[], rowId: RowId, update: (row: Row) => Row): Row[] {
  let changed = false
  const next = rows.map((row) => {
    if (row.id !== rowId) return row
    changed = true
    return update(row)
  })
  return changed ? next : rows
}

function bump(state: SheetState): SheetState {
  return { ...state, version: state.version + 1 }
}

export function applyOp(state: SheetState, op: Op | AppliedOp): SheetState {
  switch (op.type) {
    case 'rename_sheet':
      return { ...bump(state), name: op.name.trim() }

    case 'add_column': {
      const column: Column = {
        // A client-sent op always carries an id (the store generates one so the
        // preview and the confirmed result share it); the fallback is for an
        // AppliedOp replayed from elsewhere.
        id: op.id ?? crypto.randomUUID(),
        name: op.name.trim(),
        column_type: op.column_type,
        is_label: false,
      }
      const at = op.position ?? state.columns.length
      return withColumns(bump(state), insertAt(state.columns, at, [column]))
    }

    case 'rename_column': {
      const name = op.name.trim()
      const columns = state.columns.map((c) => (c.id === op.column_id ? { ...c, name } : c))
      return withColumns(bump(state), columns)
    }

    case 'change_column_type': {
      const target = state.columnsById[op.column_id]
      const columns = state.columns.map((c) =>
        c.id === op.column_id ? { ...c, column_type: op.column_type } : c,
      )

      // A confirmed AppliedOp carries the server's own converted values, which
      // always win over anything computed here.
      if ('cells' in op) {
        const byRow = new Map(op.cells.map((c) => [c.row_id, c.value]))
        const rows = state.rows.map((row) =>
          byRow.has(row.id)
            ? { ...row, cells: putCell(row.cells, op.column_id, byRow.get(row.id) ?? null) }
            : row,
        )
        return withRows(withColumns(bump(state), columns), rows)
      }

      // Local preview. Only rows with a stored value are touched, matching the
      // server's `convert_rows/3`, which skips absent keys. A value that fails
      // to convert would make the server reject the whole op; the store checks
      // that before sending, so clearing it here is a display-only fallback.
      const from = target?.column_type
      const rows = state.rows.map((row) => {
        const value = row.cells[op.column_id]
        if (value === undefined || value === null || !from) return row
        const result = convertValue(from, op.column_type, value)
        const next: CellValue = result.ok ? result.value : null
        return { ...row, cells: putCell(row.cells, op.column_id, next) }
      })
      return withRows(withColumns(bump(state), columns), rows)
    }

    case 'move_column': {
      const from = state.columns.findIndex((c) => c.id === op.column_id)
      if (from === -1) return bump(state)
      return withColumns(bump(state), moveItem(state.columns, from, op.position))
    }

    case 'delete_column': {
      const columns = state.columns.filter((c) => c.id !== op.column_id)
      // The server's `State.delete_column/2` also strips the column's key from
      // every row; only rows that actually held a value get a new object.
      const rows = state.rows.map((row) =>
        row.cells[op.column_id] === undefined
          ? row
          : { ...row, cells: putCell(row.cells, op.column_id, null) },
      )
      return withRows(withColumns(bump(state), columns), rows)
    }

    case 'add_rows': {
      const at = op.position ?? state.rows.length
      const rows: Row[] = op.rows.map((row) => ({
        id: row.id ?? crypto.randomUUID(),
        cells: normalizeCells(row.cells, state.labelColumnId),
      }))
      return withRows(bump(state), insertAt(state.rows, at, rows))
    }

    case 'delete_rows': {
      const doomed = new Set(op.row_ids)
      return withRows(
        bump(state),
        state.rows.filter((row) => !doomed.has(row.id)),
      )
    }

    case 'move_row': {
      const from = state.rowIndexById[op.row_id]
      if (from === undefined) return bump(state)
      return withRows(bump(state), moveItem(state.rows, from, op.position))
    }

    case 'set_cells': {
      // Folded in op order so two edits to the same row in one op compose,
      // matching the server's `apply_cells/2`.
      let rows = state.rows
      for (const edit of op.cells) {
        rows = replaceRow(rows, edit.row_id, (row) => {
          const value =
            edit.column_id === state.labelColumnId && typeof edit.value === 'string'
              ? edit.value.trim()
              : edit.value
          return { ...row, cells: putCell(row.cells, edit.column_id, value) }
        })
      }
      return withRows(bump(state), rows)
    }

    case 'create_sheet': {
      const next = withColumns(bump(state), op.columns)
      return withRows({ ...next, name: op.name }, op.rows)
    }
  }
}
