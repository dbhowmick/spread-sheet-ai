/**
 * The client consistency rules (contract §5.4, frontend-plan §6.2) as a
 * **pure reducer**: `(entry, event) -> {entry, effects}`.
 *
 * Keeping it pure is what makes the tricky part — ordering, gaps, preview
 * reconciliation — testable without a socket, a store or a component. The
 * store in `stores/sheets.ts` is then thin: it feeds transport callbacks in as
 * events and performs the effects that come back.
 */
import type { NormalizedError } from '@/lib/errors'
import type { Actor, AppliedOp, Op, OpAppliedEvent, Sheet, UserRef, Uuid } from '@/types/contract'

import { applyOp } from './apply-op'
import { cellKey, fromSheet, type SheetState } from './state'

export interface PendingOp {
  clientOpId: Uuid
  op: Op
  sentAt: number
}

export interface Cue {
  actor: Actor
  at: number
}

export type SheetStatus = 'joining' | 'ready' | 'resyncing' | 'error'

export interface SheetEntry {
  /** Last server-confirmed state, at `confirmed.version`. */
  confirmed: SheetState
  /** Local previews awaiting their reply, in send order. */
  pending: PendingOp[]
  participants: UserRef[]
  /** Cell flashes and "changed by" markers, keyed by `cellKey`. */
  cues: Map<string, Cue>
  lastChange: Cue | null
  status: SheetStatus
  /**
   * A `snapshot` push is already in flight. Without this, a burst of
   * out-of-order events would fire one snapshot request each.
   */
  resyncRequested: boolean
}

export type SheetEvent =
  | { type: 'joined'; sheet: Sheet }
  | { type: 'local_op'; clientOpId: Uuid; op: Op; at: number }
  | { type: 'op_applied'; event: OpAppliedEvent; selfUserId: Uuid | null; at: number }
  | { type: 'op_rejected'; clientOpId: Uuid; error: NormalizedError }
  | { type: 'snapshot'; sheet: Sheet }
  | { type: 'rejoined'; sheet: Sheet }
  | { type: 'participants'; users: UserRef[] }
  | { type: 'disconnected' }

export type Effect =
  | { type: 'request_snapshot' }
  | { type: 'toast'; level: 'error' | 'warning'; message?: string; code?: string }

export interface Reduction {
  entry: SheetEntry
  effects: Effect[]
}

export function entryFromSheet(sheet: Sheet): SheetEntry {
  return {
    confirmed: fromSheet(sheet),
    pending: [],
    participants: [],
    cues: new Map(),
    lastChange: null,
    status: 'ready',
    resyncRequested: false,
  }
}

function isSelf(actor: Actor, selfUserId: Uuid | null): boolean {
  return actor.type === 'user' && actor.user.id === selfUserId
}

/**
 * The cells an op touched, for cueing. Only value-level ops produce cell cues;
 * structural ops (add/delete/move row or column) are reflected by
 * `lastChange` instead, since there is no stable cell to flash.
 */
function touchedCells(state: SheetState, op: AppliedOp): string[] {
  switch (op.type) {
    case 'set_cells':
      return op.cells.map((c) => cellKey(c.row_id, c.column_id))
    case 'change_column_type':
      return 'cells' in op ? op.cells.map((c) => cellKey(c.row_id, op.column_id)) : []
    case 'add_rows':
      return op.rows.flatMap((row) => (row.id ? [cellKey(row.id, state.labelColumnId)] : []))
    default:
      return []
  }
}

function withCues(entry: SheetEntry, op: AppliedOp, actor: Actor, at: number): Map<string, Cue> {
  const keys = touchedCells(entry.confirmed, op)
  if (keys.length === 0) return entry.cues
  const cues = new Map(entry.cues)
  for (const key of keys) cues.set(key, { actor, at })
  return cues
}

export function reduce(entry: SheetEntry, event: SheetEvent): Reduction {
  switch (event.type) {
    case 'joined':
      return {
        entry: { ...entryFromSheet(event.sheet), participants: entry.participants },
        effects: [],
      }

    case 'participants':
      return { entry: { ...entry, participants: event.users }, effects: [] }

    case 'local_op':
      return {
        entry: {
          ...entry,
          pending: [
            ...entry.pending,
            { clientOpId: event.clientOpId, op: event.op, sentAt: event.at },
          ],
        },
        effects: [],
      }

    case 'op_applied': {
      const { version, op, actor, client_op_id } = event.event
      const expected = entry.confirmed.version + 1

      // Rule 1: ignore anything we have already applied.
      if (version <= entry.confirmed.version) return { entry, effects: [] }

      // Rule 2: a gap means we missed an event; resync from a snapshot.
      if (version > expected) {
        if (entry.resyncRequested) return { entry: { ...entry, status: 'resyncing' }, effects: [] }
        return {
          entry: { ...entry, status: 'resyncing', resyncRequested: true },
          effects: [{ type: 'request_snapshot' }],
        }
      }

      // Rule 3: in order. Apply it, and drop the preview it confirms.
      const confirmed = applyOp(entry.confirmed, op)
      const self = isSelf(actor, event.selfUserId)
      return {
        entry: {
          ...entry,
          confirmed,
          pending: client_op_id
            ? entry.pending.filter((p) => p.clientOpId !== client_op_id)
            : entry.pending,
          cues: self ? entry.cues : withCues(entry, op, actor, event.at),
          lastChange: { actor, at: event.at },
          status: entry.status === 'joining' ? 'ready' : entry.status,
        },
        effects: [],
      }
    }

    case 'op_rejected': {
      const found = entry.pending.some((p) => p.clientOpId === event.clientOpId)
      if (!found) return { entry, effects: [] }
      return {
        entry: {
          ...entry,
          pending: entry.pending.filter((p) => p.clientOpId !== event.clientOpId),
        },
        effects: [
          {
            type: 'toast',
            level: 'error',
            // §5.4 rule 3 says show `errors[0].message`; the code is the
            // fallback the store resolves through `useErrorMessage`.
            message: event.error.message,
            code: event.error.code,
          },
        ],
      }
    }

    case 'snapshot':
      // Pending ops are deliberately kept: their own replies or broadcasts are
      // still coming (frontend-plan §6.2, resolving the apparent conflict
      // between contract §5.4 rules 2 and 4).
      return {
        entry: {
          ...entry,
          confirmed: fromSheet(event.sheet),
          status: 'ready',
          resyncRequested: false,
        },
        effects: [],
      }

    case 'rejoined': {
      // Replies for ops sent before the disconnect never arrive, so their
      // previews can never be reconciled.
      const lost = entry.pending.length
      return {
        entry: {
          ...entry,
          confirmed: fromSheet(event.sheet),
          pending: [],
          cues: new Map(),
          lastChange: null,
          status: 'ready',
          resyncRequested: false,
        },
        effects: lost
          ? [
              {
                type: 'toast',
                level: 'warning',
                message:
                  lost === 1
                    ? 'Reconnected. One change may not have been saved.'
                    : `Reconnected. ${lost} changes may not have been saved.`,
              },
            ]
          : [],
      }
    }

    case 'disconnected':
      // Clear `resyncRequested`: a snapshot push made before the drop will
      // never be answered, and without this a resync could never be retried.
      return { entry: { ...entry, resyncRequested: false }, effects: [] }
  }
}

/**
 * What the grid shows: confirmed state with pending previews replayed on top
 * (contract §5.4 rule 4). This is the reason `AppliedOp` was made assignable
 * to `Op` — one `applyOp` serves both layers.
 */
export function computeView(entry: SheetEntry): SheetState {
  if (entry.pending.length === 0) return entry.confirmed
  return entry.pending.reduce((state, p) => applyOp(state, p.op), entry.confirmed)
}
