/**
 * Per-grid state that every cell reads, provided once by `SheetGrid` instead
 * of being threaded through TanStack's cell context. Each cell looks up only
 * its own key, so a new cue re-renders the one cell it names.
 */
import type { InjectionKey, Ref, ShallowRef } from 'vue'

import type { Cue } from '@/lib/sheet/consistency'
import type { CellRef, EditingState, Move } from '@/lib/sheet/navigation'

export interface SheetGridContext {
  /** Remote-change cues, keyed by `cellKey`. */
  cues: Readonly<Ref<Map<string, Cue>>>
  /** Cells under an unconfirmed preview, keyed by `cellKey`. */
  pendingCells: Readonly<Ref<Set<string>>>
  /** A coarse clock (a few seconds) for expiring cue markers. */
  now: Readonly<Ref<number>>
}

export const sheetGridKey: InjectionKey<SheetGridContext> = Symbol('sheetGrid')

/**
 * The editing half, kept behind its own key so `SheetGridContext` stays about
 * server-derived data and a cell can take one without the other.
 *
 * `activeKey` is a plain `cellKey` string rather than a `CellRef`, so a cell's
 * `isActive` is one string comparison against a value it already memoises. The
 * editor's draft text deliberately does **not** live here: it stays local to
 * the editor component, or every mounted cell would re-evaluate on each
 * keystroke.
 */
export interface SheetNavContext {
  activeKey: Readonly<Ref<string | null>>
  editing: Readonly<ShallowRef<EditingState | null>>
  activate(cell: CellRef): void
  beginEdit(cell: CellRef, initialInput?: string | null): void
  /** Commits the raw text; parsing and label checks happen in one place. */
  commit(input: string, next: Move | null): void
  cancel(): void
  /** Booleans have no editor: a click or Space sends `set_cells` directly. */
  toggleBoolean(cell: CellRef): void
}

export const sheetNavKey: InjectionKey<SheetNavContext> = Symbol('sheetNav')
