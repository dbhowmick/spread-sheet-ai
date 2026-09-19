/**
 * Ref-counted join/leave of one sheet (frontend-plan §6.4). Anything showing
 * the same sheet shares one channel and one store entry, so a workspace with
 * the sheet in a tab and a dialog previewing it does not join twice.
 *
 * `sheetId` may be a ref or getter: when it changes (a route param, a switched
 * tab) the old sheet is released and the new one held, and every returned
 * computed follows.
 */
import {
  computed,
  onScopeDispose,
  toValue,
  watch,
  type ComputedRef,
  type MaybeRefOrGetter,
} from 'vue'

import { computeView, type SheetStatus } from '@/lib/sheet/consistency'
import type { SheetState } from '@/lib/sheet/state'
import { useSheetsStore } from '@/stores/sheets'
import type { Op, SheetId, UserRef } from '@/types/contract'

export interface UseSheet {
  view: ComputedRef<SheetState | null>
  status: ComputedRef<SheetStatus>
  participants: ComputedRef<UserRef[]>
  apply: (op: Op) => Promise<void>
  resync: () => Promise<void>
}

export function useSheet(sheetId: MaybeRefOrGetter<SheetId>): UseSheet {
  const store = useSheetsStore()
  let held: SheetId | null = null

  watch(
    () => toValue(sheetId),
    (next) => {
      if (held === next) return
      if (held) store.close(held)
      held = next || null
      if (held) void store.open(held)
    },
    { immediate: true },
  )

  onScopeDispose(() => {
    if (held) store.close(held)
    held = null
  })

  const entry = computed(() => store.entryOf(toValue(sheetId)))

  return {
    view: computed(() => {
      const current = entry.value
      return current ? computeView(current) : null
    }),
    status: computed<SheetStatus>(() => entry.value?.status ?? 'joining'),
    participants: computed(() => entry.value?.participants ?? []),
    apply: (op: Op) => store.sendOp(toValue(sheetId), op),
    resync: () => store.requestSnapshot(toValue(sheetId)),
  }
}
