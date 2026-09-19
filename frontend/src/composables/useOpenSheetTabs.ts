/**
 * Which sheets have a tab open in a conversation's workspace (frontend-plan §4).
 *
 * The list is **local to each user** — it is their view of the session, not
 * shared state — so it lives in `localStorage`, keyed by conversation id, like
 * the per-user column widths in `useSheetTable`. A read or write failure is
 * ignored; the tabs just don't survive a reload.
 */
import { ref, toValue, watch, type MaybeRefOrGetter, type Ref } from 'vue'

import type { ConversationId, SheetId } from '@/types/contract'

const storageKey = (conversationId: ConversationId) => `chat-tabs:${conversationId}`

function read(conversationId: ConversationId): SheetId[] {
  try {
    const raw = window.localStorage.getItem(storageKey(conversationId))
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed.filter((id): id is SheetId => typeof id === 'string')
  } catch {
    return []
  }
}

function write(conversationId: ConversationId, ids: SheetId[]): void {
  try {
    window.localStorage.setItem(storageKey(conversationId), JSON.stringify(ids))
  } catch {
    // The tabs just won't survive a reload.
  }
}

export interface UseOpenSheetTabs {
  openIds: Ref<SheetId[]>
  /** Adds a tab if it isn't already there. Idempotent, so `focus_sheet` is safe. */
  open: (sheetId: SheetId) => void
  close: (sheetId: SheetId) => void
}

export function useOpenSheetTabs(
  conversationId: MaybeRefOrGetter<ConversationId>,
): UseOpenSheetTabs {
  const openIds = ref<SheetId[]>(read(toValue(conversationId)))

  watch(
    () => toValue(conversationId),
    (next, previous) => {
      if (next === previous) return
      openIds.value = read(next)
    },
  )

  watch(openIds, (ids) => write(toValue(conversationId), ids), { deep: true })

  return {
    openIds,
    open(sheetId) {
      if (openIds.value.includes(sheetId)) return
      openIds.value = [...openIds.value, sheetId]
    },
    close(sheetId) {
      openIds.value = openIds.value.filter((id) => id !== sheetId)
    },
  }
}
