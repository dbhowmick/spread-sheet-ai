/**
 * Pure grid layout helpers (frontend-plan §7.1–7.3), kept out of the
 * components so they can be unit tested without TanStack or a DOM.
 */
import type { Column, ColumnId } from '@/types/contract'

import type { Cue } from './consistency'

/** The row-number / checkbox gutter's column id. */
export const GUTTER_COLUMN_ID = '__select'

export const ROW_HEIGHT = 32

export const GUTTER_WIDTH = 48
export const LABEL_WIDTH = 200
export const COLUMN_WIDTH = 140
export const MIN_COLUMN_WIDTH = 60

/** How long a remote change keeps its "changed by" marker. */
export const CUE_MARKER_MS = 30_000

/** The width a column starts at before the user resizes it. */
export function defaultWidth(column: Column): number {
  return column.is_label ? LABEL_WIDTH : COLUMN_WIDTH
}

/**
 * The columns pinned to the start edge: the gutter, then the label column.
 * The label column can be moved like any other (`move_column`), so it is
 * pinned by id, not by position.
 */
export function pinnedStart(labelColumnId: ColumnId): string[] {
  return labelColumnId ? [GUTTER_COLUMN_ID, labelColumnId] : [GUTTER_COLUMN_ID]
}

/**
 * The CSS `grid-template-columns` value for one row, from the column widths
 * in render order. Set once on the scroll container as `--grid-cols`, so a
 * resize restyles one variable rather than every cell.
 */
export function gridTemplate(widths: number[]): string {
  return widths.map((w) => `${w}px`).join(' ')
}

/** Whether a cue is recent enough to still show its marker. */
export function isCueFresh(cue: Cue | undefined, now: number): boolean {
  return cue !== undefined && now - cue.at < CUE_MARKER_MS
}
