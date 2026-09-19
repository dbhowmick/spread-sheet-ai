/**
 * Ref-counted join/leave of one conversation (frontend-plan §6.4), the twin of
 * `useSheet`. Anything showing the same conversation shares one channel and one
 * store entry.
 *
 * `conversationId` may be a ref or getter: when it changes the old conversation
 * is released and the new one held, and every returned computed follows.
 */
import {
  computed,
  onScopeDispose,
  toValue,
  watch,
  type ComputedRef,
  type MaybeRefOrGetter,
} from 'vue'

import type {
  ConversationEntry,
  ConversationStatus,
  FocusRequest,
} from '@/lib/conversation/conversation'
import { chatItems, type ChatItem } from '@/lib/conversation/render'
import type { NormalizedError } from '@/lib/errors'
import { useConversationsStore } from '@/stores/conversations'
import { useAuthStore } from '@/stores/auth'
import type {
  ConversationId,
  ConversationJoinStatus,
  ConversationSummary,
  LinkedSheet,
  SheetId,
  UserRef,
} from '@/types/contract'

export interface UseConversation {
  conversation: ComputedRef<ConversationSummary | null>
  /** The transcript, ready to render (tool results folded into their calls). */
  items: ComputedRef<ChatItem[]>
  /** Whether anything has been said yet, for the new-chat empty state. */
  isEmpty: ComputedRef<boolean>
  agentStatus: ComputedRef<ConversationJoinStatus>
  agentError: ComputedRef<string | null>
  participants: ComputedRef<UserRef[]>
  linkedSheets: ComputedRef<LinkedSheet[]>
  /** The AI touched a sheet; the workspace should make its tab active (UI-4). */
  focusRequest: ComputedRef<FocusRequest | null>
  status: ComputedRef<ConversationStatus>
  /** Why the join failed, while `status` is `'error'`. */
  error: ComputedRef<NormalizedError | null>
  send: (text: string) => Promise<void>
  cancel: () => Promise<void>
  openSheet: (sheetId: SheetId) => Promise<LinkedSheet | null>
}

const EMPTY_ITEMS: ChatItem[] = []
const EMPTY_SHEETS: LinkedSheet[] = []
const EMPTY_USERS: UserRef[] = []

export function useConversation(conversationId: MaybeRefOrGetter<ConversationId>): UseConversation {
  const store = useConversationsStore()
  const auth = useAuthStore()
  let held: ConversationId | null = null

  watch(
    () => toValue(conversationId),
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

  const entry = computed<ConversationEntry | null>(() => store.entryOf(toValue(conversationId)))

  return {
    conversation: computed(() => entry.value?.conversation ?? null),
    items: computed(() => {
      const current = entry.value
      if (!current) return EMPTY_ITEMS
      return chatItems(current, auth.currentUser?.id ?? null)
    }),
    isEmpty: computed(() => (entry.value?.messages.length ?? 0) === 0),
    agentStatus: computed(() => entry.value?.agentStatus ?? 'not_started'),
    agentError: computed(() => entry.value?.agentError ?? null),
    participants: computed(() => entry.value?.participants ?? EMPTY_USERS),
    linkedSheets: computed(() => entry.value?.linkedSheets ?? EMPTY_SHEETS),
    focusRequest: computed(() => entry.value?.focusRequest ?? null),
    status: computed<ConversationStatus>(() => entry.value?.status ?? 'joining'),
    error: computed(() => store.conversations.get(toValue(conversationId))?.error ?? null),
    send: (text: string) => store.sendMessage(toValue(conversationId), text),
    cancel: () => store.cancel(toValue(conversationId)),
    openSheet: (sheetId: SheetId) => store.openSheet(toValue(conversationId), sheetId),
  }
}
