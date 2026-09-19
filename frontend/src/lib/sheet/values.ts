/**
 * Cell values per column type (contract §2.2, §6).
 *
 * This file holds **three different jobs** that are easy to conflate, and the
 * server only does two of them:
 *
 *   1. `castValue` mirrors `Sheets.Values.cast/2` — a *wire-type check*, not a
 *      parser. The server's `cast("number", v) when is_number(v)` rejects the
 *      string `"12"` outright. Use it to validate values before sending.
 *   2. `convertValue` mirrors `Sheets.Values.convert/3`, used only by
 *      `change_column_type`. This is the one place the server parses strings,
 *      and it is **strict**: booleans accept exactly `"true"` / `"false"`.
 *   3. `parseInput` has no server counterpart. It turns what a person typed
 *      into a JSON value for an `Op`, so it may be *lenient* (`yes`, `1`,
 *      grouped thousands) — whatever it returns is a properly typed JSON value
 *      that `castValue` then accepts.
 *
 * The distinction matters: a `change_column_type` preview is compared against
 * the server's `AppliedOp.cells`, so `convertValue` being lenient where the
 * server is strict would show a converted value and then have the whole op
 * rejected. `parseInput` has no such constraint.
 *
 * Server source: `lib/spread_sheet_ai/sheets/values.ex`.
 */
import type { CellValue, ColumnId, ColumnType, Row } from '@/types/contract'

import { cellOf, type SheetState } from './state'

export type ValueResult = { ok: true; value: CellValue } | { ok: false; message: string }

const ok = (value: CellValue): ValueResult => ({ ok: true, value })
const err = (message: string): ValueResult => ({ ok: false, message })

/**
 * The largest integer a double represents exactly, mirroring the server's
 * `@max_number 9_007_199_254_740_992`. Note this is `MAX_SAFE_INTEGER + 1`, so
 * the built-in constant is *not* the right thing to reach for.
 */
export const MAX_NUMBER = 9_007_199_254_740_992

/**
 * Mirrors `config :spread_sheet_ai, :sheets, write_max_cells`. It counts rows
 * for `add_rows` and cell edits for `set_cells`. The server never publishes it
 * except as `meta.max` on a `too_many_cells` error, so this is a hardcoded
 * mirror — unused until F4's paste chunking.
 */
export const WRITE_MAX_CELLS = 1000

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/

/** `Integer.parse/1` with an empty remainder. */
const INTEGER_RE = /^[+-]?\d+$/
/**
 * `Float.parse/1` with an empty remainder. Elixir requires digits on both
 * sides of the dot, so `"12."` and `".5"` both fail — unlike `parseFloat`.
 */
const FLOAT_RE = /^[+-]?\d+(\.\d+)?([eE][+-]?\d+)?$/

/** Trimmed and lower-cased, for column-name and row-label uniqueness (`Sheets.Key`). */
export function normalizeKey(value: string): string {
  return value.trim().toLowerCase()
}

function isLeapYear(year: number): boolean {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0
}

function daysInMonth(year: number, month: number): number {
  if (month === 2) return isLeapYear(year) ? 29 : 28
  return month === 4 || month === 6 || month === 9 || month === 11 ? 30 : 31
}

/**
 * The server is `@date_format` **and** `Date.from_iso8601/1`, so the calendar
 * has to be checked too: `new Date("2026-02-30")` silently rolls over to March
 * in JS, where Elixir rejects it.
 */
function castDate(value: string): ValueResult {
  if (!DATE_RE.test(value)) return err('Dates must look like YYYY-MM-DD.')
  const year = Number(value.slice(0, 4))
  const month = Number(value.slice(5, 7))
  const day = Number(value.slice(8, 10))
  if (month < 1 || month > 12) return err('That month does not exist.')
  if (day < 1 || day > daysInMonth(year, month))
    return err('That day does not exist in that month.')
  // The regex forces zero-padded YYYY-MM-DD, so re-emitting is the input.
  return ok(value)
}

/**
 * Whole floats are stored as integers (`12.0` → `12`). JS has no int/float
 * distinction, so this is a no-op — kept as a named function because the
 * server's `normalize_number/1` is a real step and the parity is worth stating.
 */
function normalizeNumber(value: number): number {
  return value
}

/** `Integer.parse/1`, then `Float.parse/1`, each requiring an empty remainder. */
function parseNumberStrict(text: string): number | null {
  if (INTEGER_RE.test(text) || FLOAT_RE.test(text)) {
    const parsed = Number(text)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

/**
 * Mirrors `Values.cast/2`: casts a JSON value for a column of `type` into its
 * stored form. `null` is an empty cell in every type, and `""` text is stored
 * as `null`. Ordinary text is **not** trimmed (only names and labels are).
 */
export function castValue(type: ColumnType, value: unknown): ValueResult {
  if (value === null || value === undefined) return ok(null)

  switch (type) {
    case 'text':
      if (typeof value !== 'string') return err('This column holds text.')
      return ok(value === '' ? null : value)

    case 'number':
      if (typeof value !== 'number' || !Number.isFinite(value)) {
        return err('This column holds numbers.')
      }
      if (Math.abs(value) > MAX_NUMBER) return err('That number is too large.')
      return ok(normalizeNumber(value))

    case 'boolean':
      if (typeof value !== 'boolean') return err('This column holds true or false.')
      return ok(value)

    case 'date':
      if (typeof value !== 'string') return err('This column holds dates.')
      return castDate(value)

    default:
      return err('Unknown column type.')
  }
}

/** Mirrors `Values.to_text/1`. Never fails. */
function toText(value: Exclude<CellValue, null>): string {
  if (typeof value === 'string') return value
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  // Only non-whole floats reach here as floats; whole ones were normalized to
  // integers at cast time. Elixir's Float.to_string and JS's String() agree on
  // ordinary magnitudes and diverge only at extremes (Elixir reaches `e`
  // notation sooner). The confirmed AppliedOp always carries the server's own
  // value and wins, so a preview divergence there is self-correcting.
  return String(value)
}

function fromText(to: ColumnType, trimmed: string): ValueResult {
  switch (to) {
    case 'number': {
      const parsed = parseNumberStrict(trimmed)
      if (parsed === null) return err(`"${trimmed}" is not a number.`)
      return castValue('number', parsed)
    }
    case 'date':
      return castDate(trimmed)
    case 'boolean': {
      const lower = trimmed.toLowerCase()
      if (lower === 'true') return ok(true)
      if (lower === 'false') return ok(false)
      return err(`"${trimmed}" is not true or false.`)
    }
    default:
      return err('Unknown column type.')
  }
}

/**
 * Mirrors `Values.convert/3`, used by `change_column_type`. Clause order is
 * load-bearing and matches the server's:
 *
 *   * `null` converts to `null` for every pair;
 *   * the same type is an identity — note this means `text → text` returns
 *     `""` unchanged rather than the `null` that `castValue` would give;
 *   * anything → `text` never fails;
 *   * `text → *` trims first, and blank becomes `null`;
 *   * `boolean ↔ number` only for `1` / `0`;
 *   * everything else fails, which rejects the whole op with
 *     `type_conversion_failed`. In particular `date ↔ number` and
 *     `date ↔ boolean` all fail.
 */
export function convertValue(from: ColumnType, to: ColumnType, value: CellValue): ValueResult {
  if (value === null) return ok(null)
  if (from === to) return ok(value)
  if (to === 'text') return ok(toText(value))

  if (from === 'text') {
    if (typeof value !== 'string') return err('Expected text.')
    const trimmed = value.trim()
    if (trimmed === '') return ok(null)
    return fromText(to, trimmed)
  }

  if (from === 'boolean' && to === 'number') return ok(value === true ? 1 : 0)

  if (from === 'number' && to === 'boolean') {
    if (value === 1) return ok(true)
    if (value === 0) return ok(false)
    return err(`${String(value)} is not true or false.`)
  }

  return err(`Values can't be converted from ${from} to ${to}.`)
}

/** `1,200` / `1 200` → `1200`, but only when the grouping is well formed. */
const GROUPED_NUMBER_RE = /^[+-]?\d{1,3}([,   ]\d{3})+(\.\d+)?$/

/**
 * Turns typed text into a JSON value for an `Op`. Frontend-only, and
 * deliberately more forgiving than `convertValue` — see the module doc. An
 * empty input clears the cell.
 */
export function parseInput(type: ColumnType, input: string): ValueResult {
  switch (type) {
    case 'text':
      // Not trimmed: the server stores ordinary text verbatim.
      return ok(input === '' ? null : input)

    case 'number': {
      const trimmed = input.trim()
      if (trimmed === '') return ok(null)
      const ungrouped = GROUPED_NUMBER_RE.test(trimmed) ? trimmed.replace(/[,   ]/g, '') : trimmed
      const parsed = parseNumberStrict(ungrouped)
      if (parsed === null) return err(`"${input}" is not a number.`)
      return castValue('number', parsed)
    }

    case 'boolean': {
      const lower = input.trim().toLowerCase()
      if (lower === '') return ok(null)
      if (['true', 'yes', 'y', '1'].includes(lower)) return ok(true)
      if (['false', 'no', 'n', '0'].includes(lower)) return ok(false)
      return err(`"${input}" is not true or false.`)
    }

    case 'date': {
      const trimmed = input.trim()
      if (trimmed === '') return ok(null)
      return castDate(trimmed)
    }

    default:
      return err('Unknown column type.')
  }
}

/**
 * The display string for a cell. Dates stay ISO and booleans stay
 * `true`/`false` so that copy → paste round-trips through `parseInput`;
 * numbers are localized only when a locale is given, which keeps the default
 * deterministic.
 */
export function formatValue(type: ColumnType, value: CellValue, locale?: string): string {
  if (value === null) return ''
  if (type === 'number' && typeof value === 'number' && locale) {
    return value.toLocaleString(locale)
  }
  return toText(value)
}

/**
 * Reads a cell, collapsing a missing key and `null` (contract §2.4).
 * Re-exported here so cell code has one import.
 */
export function cellValue(row: Row, columnId: ColumnId): CellValue {
  return cellOf(row, columnId)
}

/**
 * A row label must be non-empty and unique, ignoring case and trimmed
 * (contract §6). Labels are stored **trimmed**, unlike ordinary text cells.
 * Pass `exceptRowId` when renaming, so a row doesn't collide with itself.
 */
export function validateLabel(label: string, state: SheetState, exceptRowId?: string): ValueResult {
  const trimmed = label.trim()
  if (trimmed === '') return err('A row label is required.')

  const key = normalizeKey(trimmed)
  for (const row of state.rows) {
    if (row.id === exceptRowId) continue
    const existing = cellOf(row, state.labelColumnId)
    if (typeof existing === 'string' && normalizeKey(existing) === key) {
      return err(`"${trimmed}" is already used.`)
    }
  }
  return ok(trimmed)
}
