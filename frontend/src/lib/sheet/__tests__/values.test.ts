import { describe, expect, it } from 'vitest'

import {
  MAX_NUMBER,
  castValue,
  convertValue,
  formatValue,
  normalizeKey,
  parseInput,
  validateLabel,
} from '@/lib/sheet/values'
import { fromSheet } from '@/lib/sheet/state'
import type { CellValue, ColumnType, Sheet } from '@/types/contract'

/**
 * The `castValue` and `convertValue` tables below are ports of the server's
 * own `test/spread_sheet_ai/sheets/values_test.exs`. Keeping them row-for-row
 * identical is the point: these two functions are exact mirrors, and the
 * Elixir suite is the oracle.
 */

const TYPES: ColumnType[] = ['text', 'number', 'boolean', 'date']

describe('castValue', () => {
  it('treats null as an empty cell in every type', () => {
    for (const type of TYPES) {
      expect(castValue(type, null)).toEqual({ ok: true, value: null })
    }
  })

  it.each<[ColumnType, unknown, CellValue]>([
    ['text', 'Revenue', 'Revenue'],
    // Ordinary text is stored verbatim — only names and labels are trimmed.
    ['text', '  padded  ', '  padded  '],
    ['text', '', null],
    ['number', 1200, 1200],
    ['number', -12.5, -12.5],
    ['number', 12.0, 12],
    ['number', MAX_NUMBER, MAX_NUMBER],
    ['boolean', true, true],
    ['boolean', false, false],
    ['date', '2026-09-20', '2026-09-20'],
    ['date', '2024-02-29', '2024-02-29'],
  ])('casts %s %p to %p', (type, input, stored) => {
    expect(castValue(type, input)).toEqual({ ok: true, value: stored })
  })

  it.each<[string, unknown]>([
    ['text', 12],
    ['text', true],
    // A wire-type check, not a parser: the string "12" is not a number.
    ['number', '12'],
    ['number', true],
    ['number', MAX_NUMBER + 2],
    ['boolean', 'true'],
    ['boolean', 1],
    ['date', '2026-02-30'],
    ['date', '20260920'],
    ['date', '+2026-09-20'],
    ['date', '2026-09-20T10:00:00Z'],
    ['date', 20260920],
    ['currency', 12],
  ])('rejects %s %p', (type, input) => {
    expect(castValue(type as ColumnType, input).ok).toBe(false)
  })
})

describe('convertValue', () => {
  it.each<[ColumnType, ColumnType, CellValue, CellValue]>([
    ['number', 'number', 12, 12],
    ['number', 'text', 1200, '1200'],
    ['number', 'text', 12.5, '12.5'],
    ['boolean', 'text', true, 'true'],
    ['date', 'text', '2026-09-20', '2026-09-20'],
    ['text', 'number', ' 1200 ', 1200],
    ['text', 'number', '12.5', 12.5],
    ['text', 'number', '1e3', 1000],
    ['text', 'date', '2026-09-20', '2026-09-20'],
    ['text', 'boolean', 'TRUE', true],
    ['text', 'boolean', ' false ', false],
    ['text', 'number', '   ', null],
    ['text', 'date', ' ', null],
    ['boolean', 'number', true, 1],
    ['boolean', 'number', false, 0],
    ['number', 'boolean', 1, true],
    ['number', 'boolean', 0, false],
    ['number', 'date', null, null],
  ])('converts %s -> %s %p to %p', (from, to, input, output) => {
    expect(convertValue(from, to, input)).toEqual({ ok: true, value: output })
  })

  it.each<[ColumnType, ColumnType, CellValue]>([
    ['text', 'number', '12 apples'],
    ['text', 'number', '1,200'],
    ['text', 'date', '20/09/2026'],
    // Strict where `parseInput` is lenient — see the values.ts module doc.
    ['text', 'boolean', 'yes'],
    ['number', 'boolean', 2],
    ['number', 'date', 20260920],
    ['date', 'number', '2026-09-20'],
    ['boolean', 'date', true],
    ['date', 'boolean', '2026-09-20'],
  ])('refuses %s -> %s %p', (from, to, input) => {
    expect(convertValue(from, to, input).ok).toBe(false)
  })

  it('leaves blank text alone when the type is unchanged', () => {
    // The same-type identity clause runs before the text-trimming one, so this
    // is "" and not the null that castValue would give.
    expect(convertValue('text', 'text', '')).toEqual({ ok: true, value: '' })
  })

  it.each(['12.', '.5', '1 200', '0x1f', 'Infinity'])(
    'refuses the non-decimal number text %p',
    (input) => {
      expect(convertValue('text', 'number', input).ok).toBe(false)
    },
  )
})

describe('parseInput', () => {
  it('is lenient about booleans where convertValue is strict', () => {
    for (const yes of ['yes', 'Y', '1', 'TRUE']) {
      expect(parseInput('boolean', yes)).toEqual({ ok: true, value: true })
    }
    for (const no of ['no', 'N', '0', 'false']) {
      expect(parseInput('boolean', no)).toEqual({ ok: true, value: false })
    }
    expect(parseInput('boolean', 'maybe').ok).toBe(false)
  })

  it('accepts grouped thousands', () => {
    expect(parseInput('number', '1,200')).toEqual({ ok: true, value: 1200 })
    expect(parseInput('number', '1,200.50')).toEqual({ ok: true, value: 1200.5 })
    expect(parseInput('number', '1,20')).toEqual({ ok: false, message: expect.any(String) })
  })

  it('clears a cell on empty input', () => {
    for (const type of TYPES) {
      expect(parseInput(type, '')).toEqual({ ok: true, value: null })
    }
  })

  it('keeps text verbatim', () => {
    expect(parseInput('text', '  padded  ')).toEqual({ ok: true, value: '  padded  ' })
  })

  it('round-trips through formatValue', () => {
    const cases: [ColumnType, CellValue][] = [
      ['text', 'Revenue'],
      ['number', 12.5],
      ['boolean', true],
      ['boolean', false],
      ['date', '2026-09-20'],
    ]
    for (const [type, value] of cases) {
      expect(parseInput(type, formatValue(type, value))).toEqual({ ok: true, value })
    }
  })
})

describe('normalizeKey', () => {
  it('trims and lower-cases, matching Sheets.Key', () => {
    expect(normalizeKey('  Revenue  ')).toBe('revenue')
    expect(normalizeKey('REVENUE')).toBe(normalizeKey('revenue'))
  })
})

describe('validateLabel', () => {
  const sheet: Sheet = {
    id: 's1',
    name: 'Budget',
    owner: { id: 'u1', display_name: 'Alice' },
    version: 3,
    columns: [
      { id: 'c-label', name: 'Line item', column_type: 'text', is_label: true },
      { id: 'c-amount', name: 'Amount', column_type: 'number', is_label: false },
    ],
    rows: [
      { id: 'r1', cells: { 'c-label': 'Revenue', 'c-amount': 1200 } },
      { id: 'r2', cells: { 'c-label': 'Costs' } },
    ],
    inserted_at: '2026-09-19T10:00:00Z',
    updated_at: '2026-09-19T10:05:00Z',
  }
  const state = fromSheet(sheet)

  it('requires a non-blank label', () => {
    expect(validateLabel('   ', state).ok).toBe(false)
  })

  it('stores labels trimmed', () => {
    expect(validateLabel('  Margin  ', state)).toEqual({ ok: true, value: 'Margin' })
  })

  it('rejects a duplicate ignoring case and whitespace', () => {
    expect(validateLabel(' revenue ', state).ok).toBe(false)
  })

  it('lets a row keep its own label', () => {
    expect(validateLabel('Revenue', state, 'r1')).toEqual({ ok: true, value: 'Revenue' })
  })
})
