/**
 * Per-grid state that every cell reads, provided once by `SheetGrid` instead
 * of being threaded through TanStack's cell context. Each cell looks up only
 * its own key, so a new cue re-renders the one cell it names.
 */
import type { InjectionKey, Ref } from 'vue'

import type { Cue } from '@/lib/sheet/consistency'

export interface SheetGridContext {
  /** Remote-change cues, keyed by `cellKey`. */
  cues: Readonly<Ref<Map<string, Cue>>>
  /** Cells under an unconfirmed preview, keyed by `cellKey`. */
  pendingCells: Readonly<Ref<Set<string>>>
  /** A coarse clock (a few seconds) for expiring cue markers. */
  now: Readonly<Ref<number>>
}

export const sheetGridKey: InjectionKey<SheetGridContext> = Symbol('sheetGrid')
