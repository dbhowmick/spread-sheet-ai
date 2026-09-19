import { describe, expect, it } from 'vitest'

import type { Cue } from '@/lib/sheet/consistency'
import {
  COLUMN_WIDTH,
  CUE_MARKER_MS,
  GUTTER_COLUMN_ID,
  LABEL_WIDTH,
  defaultWidth,
  gridTemplate,
  isCueFresh,
  pinnedStart,
} from '@/lib/sheet/grid'
import type { Actor, Column } from '@/types/contract'

const label: Column = { id: 'c-label', name: 'Line item', column_type: 'text', is_label: true }
const q1: Column = { id: 'c-q1', name: 'Q1', column_type: 'number', is_label: false }

describe('defaultWidth', () => {
  it('gives the label column more room than the rest', () => {
    expect(defaultWidth(label)).toBe(LABEL_WIDTH)
    expect(defaultWidth(q1)).toBe(COLUMN_WIDTH)
    expect(LABEL_WIDTH).toBeGreaterThan(COLUMN_WIDTH)
  })
})

describe('pinnedStart', () => {
  it('pins the gutter and the label column, by id', () => {
    expect(pinnedStart(label.id)).toEqual([GUTTER_COLUMN_ID, label.id])
  })

  it('pins the gutter alone while no sheet is loaded', () => {
    expect(pinnedStart('')).toEqual([GUTTER_COLUMN_ID])
  })
})

describe('gridTemplate', () => {
  it('lays out one track per column, in order', () => {
    expect(gridTemplate([48, 200, 140])).toBe('48px 200px 140px')
  })

  it('is empty for no columns', () => {
    expect(gridTemplate([])).toBe('')
  })
})

describe('isCueFresh', () => {
  const now = 1_000_000
  const actor: Actor = { type: 'user', user: { id: 'u1', display_name: 'Bob' } }
  const cue = (at: number): Cue => ({ actor, at })

  it('is fresh up to the marker window', () => {
    expect(isCueFresh(cue(now), now)).toBe(true)
    expect(isCueFresh(cue(now - CUE_MARKER_MS + 1), now)).toBe(true)
  })

  it('expires at the window', () => {
    expect(isCueFresh(cue(now - CUE_MARKER_MS), now)).toBe(false)
    expect(isCueFresh(cue(now - CUE_MARKER_MS * 2), now)).toBe(false)
  })

  it('handles a missing cue', () => {
    expect(isCueFresh(undefined, now)).toBe(false)
  })
})
