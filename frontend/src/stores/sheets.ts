import { defineStore } from 'pinia'
import { computed, ref, shallowRef, triggerRef, type ComputedRef } from 'vue'
import { toast } from 'vue-sonner'

import { createSheetTransport, type SheetTransport } from '@/lib/transport'
import {
  computeView,
  entryFromSheet,
  reduce,
  type Effect,
  type SheetEntry,
  type SheetEvent,
  type SheetStatus,
} from '@/lib/sheet/consistency'
import type { NormalizedError } from '@/lib/errors'
import type { SheetState } from '@/lib/sheet/state'
import { useErrorMessage } from '@/composables/useErrorMessage'
import { useAuthStore } from '@/stores/auth'
import type { Op, Sheet, SheetId, UserRef } from '@/types/contract'

interface OpenSheet {
  entry: SheetEntry
  transport: SheetTransport
  /** How many `useSheet` callers are holding this sheet open (§6.4). */
  refs: number
  /** Why the join failed, while `entry.status` is `'error'`. */
  error: NormalizedError | null
}

/**
 * One entry per open sheet: the channel, the confirmed state, pending
 * previews, participants and cues (frontend-plan §6.1).
 *
 * All the interesting logic lives in the pure reducer in
 * `lib/sheet/consistency.ts`. This store's job is to own the transport, turn
 * its callbacks into events, and perform the effects the reducer returns.
 */
export const useSheetsStore = defineStore('sheets', () => {
  // A shallowRef of a plain Map: entries are replaced wholesale by the
  // reducer, so deep reactivity would only cost proxy churn on every op.
  const sheets = shallowRef(new Map<SheetId, OpenSheet>())
  const joining = ref(new Map<SheetId, Promise<void>>())
  const errorMessage = useErrorMessage()

  function entryOf(sheetId: SheetId): SheetEntry | null {
    return sheets.value.get(sheetId)?.entry ?? null
  }

  function runEffects(sheetId: SheetId, effects: Effect[]): void {
    for (const effect of effects) {
      if (effect.type === 'request_snapshot') {
        void requestSnapshot(sheetId)
      } else {
        const text = effect.message ?? errorMessage(effect.code)
        if (effect.level === 'error') toast.error(text)
        else toast.warning(text)
      }
    }
  }

  /** The single funnel: every change to an entry goes through the reducer. */
  function dispatch(sheetId: SheetId, event: SheetEvent): void {
    const open = sheets.value.get(sheetId)
    if (!open) return
    const { entry, effects } = reduce(open.entry, event)
    open.entry = entry
    triggerRef(sheets)
    runEffects(sheetId, effects)
  }

  async function requestSnapshot(sheetId: SheetId): Promise<void> {
    const open = sheets.value.get(sheetId)
    if (!open) return
    const result = await open.transport.snapshot()
    if (result.ok) dispatch(sheetId, { type: 'snapshot', sheet: result.data.sheet })
    else toast.error(result.error.message ?? errorMessage(result.error.code))
  }

  function selfUserId(): string | null {
    return useAuthStore().currentUser?.id ?? null
  }

  async function join(sheetId: SheetId): Promise<void> {
    // Handlers are passed at construction, never after `await join()`:
    // `rejoined` can fire *during* the first join round-trip if the socket
    // flaps (see the note in `lib/transport/types.ts`).
    const transport = createSheetTransport(sheetId, {
      opApplied: (event) =>
        dispatch(sheetId, { type: 'op_applied', event, selfUserId: selfUserId(), at: Date.now() }),
      participants: (users: UserRef[]) => dispatch(sheetId, { type: 'participants', users }),
      rejoined: (sheet: Sheet) => dispatch(sheetId, { type: 'rejoined', sheet }),
      disconnected: () => dispatch(sheetId, { type: 'disconnected' }),
    })

    const result = await transport.join()
    const open = sheets.value.get(sheetId)

    if (!result.ok) {
      transport.leave()
      // The entry stays, in `error`, so the view can say why (a deleted or
      // mistyped sheet id would otherwise read as `joining` forever). It is
      // released through `close()` like any other.
      if (open) {
        open.entry = { ...open.entry, status: 'error' }
        open.error = result.error
        triggerRef(sheets)
      }
      return
    }

    const entry = entryFromSheet(result.data.sheet)
    if (open) {
      open.transport = transport
      open.entry = entry
    } else {
      // Every holder released the sheet while the join was in flight.
      transport.leave()
      return
    }
    triggerRef(sheets)
  }

  /** Joins on first use; later callers await the same in-flight join. */
  async function open(sheetId: SheetId): Promise<void> {
    const existing = sheets.value.get(sheetId)
    if (existing) {
      existing.refs += 1
      await joining.value.get(sheetId)
      return
    }

    sheets.value.set(sheetId, {
      entry: { ...entryFromSheet(emptySheet(sheetId)), status: 'joining' },
      transport: placeholderTransport(),
      refs: 1,
      error: null,
    })
    triggerRef(sheets)

    const pending = join(sheetId).finally(() => joining.value.delete(sheetId))
    joining.value.set(sheetId, pending)
    await pending
  }

  /** Leaves when the last holder releases it. */
  function close(sheetId: SheetId): void {
    const existing = sheets.value.get(sheetId)
    if (!existing) return
    existing.refs -= 1
    if (existing.refs > 0) return
    existing.transport.leave()
    sheets.value.delete(sheetId)
    triggerRef(sheets)
  }

  /**
   * Applies `op` as a local preview and pushes it. `add_column` and `add_rows`
   * always get client-generated ids so the preview and the confirmed result
   * share them and the active cell stays put across confirmation
   * (frontend-plan §6.2).
   */
  async function sendOp(sheetId: SheetId, op: Op): Promise<void> {
    const openSheet = sheets.value.get(sheetId)
    if (!openSheet) return

    const withIds = withClientIds(op)
    const clientOpId = crypto.randomUUID()
    dispatch(sheetId, { type: 'local_op', clientOpId, op: withIds, at: Date.now() })

    const result = await openSheet.transport.pushOp(clientOpId, withIds)
    if (!result.ok) {
      dispatch(sheetId, { type: 'op_rejected', clientOpId, error: result.error })
    }
    // On success we do nothing: the `op_applied` broadcast (which the sender
    // also receives) is what drops the preview and advances the version.
  }

  function viewOf(sheetId: SheetId): ComputedRef<SheetState | null> {
    return computed(() => {
      const entry = sheets.value.get(sheetId)?.entry
      return entry ? computeView(entry) : null
    })
  }

  function statusOf(sheetId: SheetId): ComputedRef<SheetStatus> {
    return computed(() => sheets.value.get(sheetId)?.entry.status ?? 'joining')
  }

  function errorOf(sheetId: SheetId): ComputedRef<NormalizedError | null> {
    return computed(() => sheets.value.get(sheetId)?.error ?? null)
  }

  function participantsOf(sheetId: SheetId): ComputedRef<UserRef[]> {
    return computed(() => sheets.value.get(sheetId)?.entry.participants ?? [])
  }

  return {
    sheets,
    entryOf,
    open,
    close,
    sendOp,
    viewOf,
    statusOf,
    errorOf,
    participantsOf,
    requestSnapshot,
  }
})

function withClientIds(op: Op): Op {
  if (op.type === 'add_column') return { ...op, id: op.id ?? crypto.randomUUID() }
  if (op.type === 'add_rows') {
    return { ...op, rows: op.rows.map((row) => ({ ...row, id: row.id ?? crypto.randomUUID() })) }
  }
  return op
}

/** The placeholder state an entry holds while its join is in flight. */
function emptySheet(sheetId: SheetId): Sheet {
  return {
    id: sheetId,
    name: '',
    owner: { id: '', display_name: '' },
    version: 0,
    columns: [],
    rows: [],
    inserted_at: '',
    updated_at: '',
  }
}

function placeholderTransport(): SheetTransport {
  const notReady = () =>
    Promise.resolve({ ok: false as const, error: { code: 'internal_error', message: 'joining' } })
  return { join: notReady, pushOp: notReady, snapshot: notReady, leave: () => {} }
}
