/**
 * Clipboard paste as pure functions (frontend-plan §7.4).
 *
 * Excel and Google Sheets both put tab-separated text on the clipboard as
 * `text/plain`, so that is what we parse. The block is laid out from the
 * active cell; anything that can't land is skipped rather than failing the
 * whole paste, because the server applies an op all-or-nothing and one bad
 * cell would throw away the rest.
 */
import type { CellEdit, CellValue, SetCellsOp } from '@/types/contract'

import type { CellRef, NavGrid } from './navigation'
import { cellAt, posOf } from './navigation'
import type { SheetState } from './state'
import { WRITE_MAX_CELLS, normalizeKey, parseInput } from './values'

/**
 * Splits `text/plain` into a grid of raw strings. A trailing newline is
 * dropped (spreadsheets add one), but blank lines inside the block are real
 * rows. `\r\n` and `\r` are both accepted.
 */
export function parseTsv(text: string): string[][] {
  if (text === '') return []
  const body = text.replace(/\r\n?/g, '\n').replace(/\n$/, '')
  return body.split('\n').map((line) => line.split('\t'))
}

export interface PastePlan {
  /** One or more `set_cells` ops, each within the server's cap. */
  ops: SetCellsOp[]
  written: number
  /** Cells dropped: out of bounds, unparseable, or an unusable label. */
  skipped: number
}

export const EMPTY_PLAN: PastePlan = { ops: [], written: 0, skipped: 0 }

/** A cell the block wants to write, before label uniqueness is settled. */
interface Candidate {
  cell: CellRef
  isLabel: boolean
  /** The parsed value; for a label, the trimmed string. */
  value: CellValue
}

/**
 * Lays `text` out from `anchor` and turns it into ops.
 *
 * Skipped, rather than sent and rejected:
 *   * cells past the last row or column — pasting never grows the sheet;
 *   * values `parseInput` rejects for their target column's type;
 *   * a blank into the label column, and a label that would collide, since
 *     both are `label_required` / `duplicate_label` on the server.
 */
export function planPaste(
  text: string,
  grid: NavGrid,
  anchor: CellRef,
  state: SheetState,
): PastePlan {
  const block = parseTsv(text)
  if (block.length === 0) return EMPTY_PLAN

  const at = posOf(grid, anchor)
  if (!at) return EMPTY_PLAN

  const candidates: Candidate[] = []
  let skipped = 0

  for (let r = 0; r < block.length; r++) {
    const line = block[r]
    if (!line) continue

    for (let c = 0; c < line.length; c++) {
      const cell = cellAt(grid, { row: at.row + r, column: at.column + c })
      const column = cell ? state.columnsById[cell.columnId] : undefined
      if (!cell || !column) {
        skipped++
        continue
      }

      const input = line[c] ?? ''
      const parsed = parseInput(column.column_type, input)
      if (!parsed.ok) {
        skipped++
        continue
      }

      // Labels are stored trimmed, unlike ordinary text (contract §6).
      const isLabel = column.is_label
      candidates.push({ cell, isLabel, value: isLabel ? input.trim() : parsed.value })
    }
  }

  const cells: CellEdit[] = []
  // The server checks labels on their *final* values, so two rows may swap
  // them in one op. That can only be decided once the whole block is known:
  // a row the paste renames no longer holds its old label.
  const renamed = new Set(candidates.filter((c) => c.isLabel).map((c) => c.cell.rowId))
  const taken = new Set<string>()
  for (const row of state.rows) {
    if (renamed.has(row.id)) continue
    const existing = row.cells[state.labelColumnId]
    if (typeof existing === 'string') taken.add(normalizeKey(existing))
  }

  for (const candidate of candidates) {
    if (!candidate.isLabel) {
      cells.push({
        row_id: candidate.cell.rowId,
        column_id: candidate.cell.columnId,
        value: candidate.value,
      })
      continue
    }

    const label = candidate.value as string
    const key = normalizeKey(label)
    if (label === '' || taken.has(key)) {
      skipped++
      // The row keeps the label it already had, so put it back in the way of
      // any later cell in this block.
      const kept =
        state.rows[state.rowIndexById[candidate.cell.rowId] ?? -1]?.cells[state.labelColumnId]
      if (typeof kept === 'string') taken.add(normalizeKey(kept))
      continue
    }
    taken.add(key)
    cells.push({ row_id: candidate.cell.rowId, column_id: candidate.cell.columnId, value: label })
  }

  return { ops: chunkCells(cells), written: cells.length, skipped }
}

/**
 * Splits edits into ops under the server's `write_max_cells` cap, which counts
 * cells for `set_cells` (contract §6).
 */
export function chunkCells(cells: CellEdit[], max: number = WRITE_MAX_CELLS): SetCellsOp[] {
  const ops: SetCellsOp[] = []
  for (let i = 0; i < cells.length; i += max) {
    ops.push({ type: 'set_cells', cells: cells.slice(i, i + max) })
  }
  return ops
}

/** "3 cells couldn't be pasted." — `null` when nothing was skipped. */
export function skippedMessage(plan: PastePlan): string | null {
  if (plan.skipped === 0) return null
  return plan.skipped === 1
    ? "1 cell couldn't be pasted."
    : `${plan.skipped} cells couldn't be pasted.`
}
