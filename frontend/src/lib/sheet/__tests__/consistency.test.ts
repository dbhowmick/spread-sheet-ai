import { describe, expect, it } from 'vitest'

import {
  computeView,
  entryFromSheet,
  reduce,
  type SheetEntry,
  type SheetEvent,
} from '@/lib/sheet/consistency'
import { cellKey } from '@/lib/sheet/state'
import type { Actor, AppliedOp, Op, Sheet } from '@/types/contract'

/** Contract §5.4, rule by rule. */

const LABEL = 'c-label'
const Q1 = 'c-q1'
const SELF = 'u-self'
const OTHER = 'u-other'

function sheet(version = 5): Sheet {
  return {
    id: 's1',
    name: 'Budget',
    owner: { id: SELF, display_name: 'Alice' },
    version,
    columns: [
      { id: LABEL, name: 'Line item', column_type: 'text', is_label: true },
      { id: Q1, name: 'Q1', column_type: 'number', is_label: false },
    ],
    rows: [
      { id: 'r1', cells: { [LABEL]: 'Revenue', [Q1]: 1200 } },
      { id: 'r2', cells: { [LABEL]: 'Costs' } },
    ],
    inserted_at: '2026-09-19T10:00:00Z',
    updated_at: '2026-09-19T10:05:00Z',
  }
}

const selfActor: Actor = { type: 'user', user: { id: SELF, display_name: 'Alice' } }
const otherActor: Actor = { type: 'user', user: { id: OTHER, display_name: 'Bob' } }

const setQ1 = (value: number): Op => ({
  type: 'set_cells',
  cells: [{ row_id: 'r1', column_id: Q1, value }],
})

function opApplied(
  version: number,
  op: AppliedOp,
  actor: Actor = otherActor,
  clientOpId: string | null = null,
): SheetEvent {
  return {
    type: 'op_applied',
    event: { version, op, actor, client_op_id: clientOpId },
    selfUserId: SELF,
    at: 1000,
  }
}

/** Threads a list of events through the reducer, collecting every effect. */
function run(entry: SheetEntry, events: SheetEvent[]) {
  return events.reduce(
    (acc, event) => {
      const { entry: next, effects } = reduce(acc.entry, event)
      return { entry: next, effects: [...acc.effects, ...effects] }
    },
    { entry, effects: [] as ReturnType<typeof reduce>['effects'] },
  )
}

describe('rule 1 — apply in order', () => {
  it('applies an event exactly one version ahead', () => {
    const { entry } = reduce(entryFromSheet(sheet(5)), opApplied(6, setQ1(99) as AppliedOp))
    expect(entry.confirmed.version).toBe(6)
    expect(entry.confirmed.rows[0]?.cells[Q1]).toBe(99)
  })

  it('ignores an event at or below the local version', () => {
    const start = entryFromSheet(sheet(5))
    for (const stale of [5, 4, 1]) {
      const { entry, effects } = reduce(start, opApplied(stale, setQ1(99) as AppliedOp))
      expect(entry).toBe(start)
      expect(effects).toEqual([])
    }
  })
})

describe('rule 2 — gap', () => {
  it('requests a snapshot when an event skips a version', () => {
    const { entry, effects } = reduce(
      entryFromSheet(sheet(5)),
      opApplied(8, setQ1(99) as AppliedOp),
    )
    expect(entry.status).toBe('resyncing')
    expect(entry.resyncRequested).toBe(true)
    expect(effects).toEqual([{ type: 'request_snapshot' }])
    // The gap event is NOT applied.
    expect(entry.confirmed.version).toBe(5)
  })

  it('requests only one snapshot for a burst of future events', () => {
    const { effects } = run(entryFromSheet(sheet(5)), [
      opApplied(8, setQ1(1) as AppliedOp),
      opApplied(9, setQ1(2) as AppliedOp),
      opApplied(10, setQ1(3) as AppliedOp),
    ])
    expect(effects.filter((e) => e.type === 'request_snapshot')).toHaveLength(1)
  })

  it('replaces confirmed state from the snapshot and keeps pending', () => {
    const start = reduce(entryFromSheet(sheet(5)), {
      type: 'local_op',
      clientOpId: 'op-1',
      op: setQ1(42),
      at: 1,
    }).entry

    const { entry } = run(start, [
      opApplied(9, setQ1(1) as AppliedOp),
      { type: 'snapshot', sheet: sheet(9) },
    ])

    expect(entry.confirmed.version).toBe(9)
    expect(entry.status).toBe('ready')
    expect(entry.resyncRequested).toBe(false)
    // Kept: the reply or broadcast for op-1 is still coming
    // (frontend-plan §6.2 resolving §5.4 rules 2 vs 4).
    expect(entry.pending).toHaveLength(1)
  })

  it('can resync again after a reconnect drops the in-flight request', () => {
    const { entry, effects } = run(entryFromSheet(sheet(5)), [
      opApplied(8, setQ1(1) as AppliedOp),
      { type: 'disconnected' },
      opApplied(9, setQ1(2) as AppliedOp),
    ])
    expect(entry.resyncRequested).toBe(true)
    expect(effects.filter((e) => e.type === 'request_snapshot')).toHaveLength(2)
  })
})

describe('rule 3 — local preview', () => {
  it('shows the preview immediately, over confirmed state', () => {
    const { entry } = reduce(entryFromSheet(sheet(5)), {
      type: 'local_op',
      clientOpId: 'op-1',
      op: setQ1(42),
      at: 1,
    })
    expect(entry.confirmed.rows[0]?.cells[Q1]).toBe(1200)
    expect(computeView(entry).rows[0]?.cells[Q1]).toBe(42)
  })

  it('drops the preview when the matching client_op_id is confirmed', () => {
    const { entry } = run(entryFromSheet(sheet(5)), [
      { type: 'local_op', clientOpId: 'op-1', op: setQ1(42), at: 1 },
      opApplied(6, setQ1(42) as AppliedOp, selfActor, 'op-1'),
    ])
    expect(entry.pending).toEqual([])
    expect(entry.confirmed.rows[0]?.cells[Q1]).toBe(42)
    expect(computeView(entry)).toBe(entry.confirmed)
  })

  it("leaves another client's op alone", () => {
    const { entry } = run(entryFromSheet(sheet(5)), [
      { type: 'local_op', clientOpId: 'mine', op: setQ1(42), at: 1 },
      opApplied(6, { type: 'rename_sheet', name: 'Theirs' }, otherActor, 'theirs'),
    ])
    expect(entry.pending).toHaveLength(1)
  })

  it('rolls back and reports the server message on a rejection', () => {
    const start = reduce(entryFromSheet(sheet(5)), {
      type: 'local_op',
      clientOpId: 'op-1',
      op: setQ1(42),
      at: 1,
    }).entry

    const { entry, effects } = reduce(start, {
      type: 'op_rejected',
      clientOpId: 'op-1',
      error: { code: 'invalid_value', message: 'not a number' },
    })

    expect(entry.pending).toEqual([])
    expect(computeView(entry).rows[0]?.cells[Q1]).toBe(1200)
    expect(effects).toEqual([
      { type: 'toast', level: 'error', message: 'not a number', code: 'invalid_value' },
    ])
  })

  it('treats a push timeout as a rejection', () => {
    const start = reduce(entryFromSheet(sheet(5)), {
      type: 'local_op',
      clientOpId: 'op-1',
      op: setQ1(42),
      at: 1,
    }).entry

    const { entry, effects } = reduce(start, {
      type: 'op_rejected',
      clientOpId: 'op-1',
      error: { code: 'timeout' },
    })

    expect(entry.pending).toEqual([])
    // No server message: the store resolves the code through useErrorMessage.
    expect(effects).toEqual([
      { type: 'toast', level: 'error', message: undefined, code: 'timeout' },
    ])
  })

  it('ignores a rejection for an op it is not tracking', () => {
    const start = entryFromSheet(sheet(5))
    const { entry, effects } = reduce(start, {
      type: 'op_rejected',
      clientOpId: 'ghost',
      error: { code: 'timeout' },
    })
    expect(entry).toBe(start)
    expect(effects).toEqual([])
  })
})

describe('rule 4 — server wins, previews stack', () => {
  it('replays several pending ops over confirmed state in order', () => {
    const { entry } = run(entryFromSheet(sheet(5)), [
      { type: 'local_op', clientOpId: 'a', op: setQ1(1), at: 1 },
      { type: 'local_op', clientOpId: 'b', op: setQ1(2), at: 2 },
    ])
    expect(computeView(entry).rows[0]?.cells[Q1]).toBe(2)
    expect(computeView(entry).version).toBe(7)
  })

  it("keeps a pending preview on top of someone else's confirmed change", () => {
    const { entry } = run(entryFromSheet(sheet(5)), [
      { type: 'local_op', clientOpId: 'mine', op: setQ1(42), at: 1 },
      opApplied(6, setQ1(7) as AppliedOp, otherActor),
    ])
    expect(entry.confirmed.rows[0]?.cells[Q1]).toBe(7)
    expect(computeView(entry).rows[0]?.cells[Q1]).toBe(42)
  })
})

describe('cues', () => {
  it("records a cue for someone else's edit", () => {
    const { entry } = reduce(
      entryFromSheet(sheet(5)),
      opApplied(6, setQ1(7) as AppliedOp, otherActor),
    )
    expect(entry.cues.get(cellKey('r1', Q1))).toEqual({ actor: otherActor, at: 1000 })
    expect(entry.lastChange).toEqual({ actor: otherActor, at: 1000 })
  })

  it('records no cue for the local user', () => {
    const { entry } = reduce(
      entryFromSheet(sheet(5)),
      opApplied(6, setQ1(7) as AppliedOp, selfActor),
    )
    expect(entry.cues.size).toBe(0)
    // lastChange is still set, so the toolbar can show "Updated just now".
    expect(entry.lastChange).toEqual({ actor: selfActor, at: 1000 })
  })

  it('cues an agent actor like any other non-self actor', () => {
    const agent: Actor = { type: 'agent', conversation_id: 'c1', conversation_title: 'Budget' }
    const { entry } = reduce(entryFromSheet(sheet(5)), opApplied(6, setQ1(7) as AppliedOp, agent))
    expect(entry.cues.get(cellKey('r1', Q1))?.actor).toEqual(agent)
  })
})

describe('rejoined', () => {
  it('replaces confirmed state and clears pending, because replies are lost', () => {
    const start = run(entryFromSheet(sheet(5)), [
      { type: 'local_op', clientOpId: 'a', op: setQ1(1), at: 1 },
      { type: 'local_op', clientOpId: 'b', op: setQ1(2), at: 2 },
    ]).entry

    const { entry, effects } = reduce(start, { type: 'rejoined', sheet: sheet(11) })

    expect(entry.confirmed.version).toBe(11)
    expect(entry.pending).toEqual([])
    expect(entry.status).toBe('ready')
    expect(effects).toEqual([
      {
        type: 'toast',
        level: 'warning',
        message: 'Reconnected. 2 changes may not have been saved.',
      },
    ])
  })

  it('says nothing when there was nothing pending', () => {
    const { effects } = reduce(entryFromSheet(sheet(5)), { type: 'rejoined', sheet: sheet(11) })
    expect(effects).toEqual([])
  })
})

describe('participants', () => {
  it('replaces the full list', () => {
    const users = [{ id: OTHER, display_name: 'Bob' }]
    const { entry } = reduce(entryFromSheet(sheet(5)), { type: 'participants', users })
    expect(entry.participants).toEqual(users)
  })

  it('survives a later join', () => {
    const { entry } = run(entryFromSheet(sheet(5)), [
      { type: 'participants', users: [{ id: OTHER, display_name: 'Bob' }] },
      { type: 'joined', sheet: sheet(6) },
    ])
    expect(entry.participants).toHaveLength(1)
    expect(entry.confirmed.version).toBe(6)
  })
})

describe('purity', () => {
  it('never mutates the entry it is given', () => {
    const start = entryFromSheet(sheet(5))
    const events: SheetEvent[] = [
      { type: 'local_op', clientOpId: 'a', op: setQ1(1), at: 1 },
      opApplied(6, setQ1(2) as AppliedOp),
      opApplied(99, setQ1(3) as AppliedOp),
      { type: 'snapshot', sheet: sheet(9) },
      { type: 'rejoined', sheet: sheet(10) },
      { type: 'disconnected' },
    ]
    for (const event of events) reduce(start, event)
    expect(start.confirmed.version).toBe(5)
    expect(start.pending).toEqual([])
    expect(start.cues.size).toBe(0)
    expect(start.resyncRequested).toBe(false)
  })
})
