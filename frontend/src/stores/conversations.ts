import { defineStore } from 'pinia'
import { computed, ref, shallowRef, triggerRef, type ComputedRef } from 'vue'
import { toast } from 'vue-sonner'

import { createConversationTransport, type ConversationTransport } from '@/lib/transport'
import {
  emptyEntry,
  reduce,
  type ConversationEffect,
  type ConversationEntry,
  type ConversationEvent,
} from '@/lib/conversation/conversation'
import type { NormalizedError } from '@/lib/errors'
import { useErrorMessage } from '@/composables/useErrorMessage'
import type { ConversationId, LinkedSheet, SheetId } from '@/types/contract'

interface OpenConversation {
  entry: ConversationEntry
  transport: ConversationTransport
  /** How many `useConversation` callers are holding this open (§6.4). */
  refs: number
  /** Why the join failed, while `entry.status` is `'error'`. */
  error: NormalizedError | null
}

/**
 * One entry per open conversation: the channel, the transcript, the agent's
 * status, linked sheets and participants (frontend-plan §8.1).
 *
 * The twin of `stores/sheets.ts`, down to the ref counting and the reducer
 * funnel. All the interesting logic is in `lib/conversation/conversation.ts`.
 */
export const useConversationsStore = defineStore('conversations', () => {
  const conversations = shallowRef(new Map<ConversationId, OpenConversation>())
  const joining = ref(new Map<ConversationId, Promise<void>>())
  const errorMessage = useErrorMessage()

  function entryOf(id: ConversationId): ConversationEntry | null {
    return conversations.value.get(id)?.entry ?? null
  }

  function runEffects(effects: ConversationEffect[]): void {
    for (const effect of effects) {
      const text = effect.message ?? errorMessage(effect.code)
      if (effect.level === 'error') toast.error(text)
      else toast.warning(text)
    }
  }

  /** The single funnel: every change to an entry goes through the reducer. */
  function dispatch(id: ConversationId, event: ConversationEvent): void {
    const open = conversations.value.get(id)
    if (!open) return
    const { entry, effects } = reduce(open.entry, event)
    open.entry = entry
    triggerRef(conversations)
    runEffects(effects)
  }

  async function join(id: ConversationId): Promise<void> {
    // Handlers at construction, never after `await join()`: `rejoined` can fire
    // during the first round-trip if the socket flaps (lib/transport/types.ts).
    const transport = createConversationTransport(id, {
      message: (message) => dispatch(id, { type: 'message', message }),
      messageUpdated: (message) => dispatch(id, { type: 'message_updated', message }),
      streamDelta: (text) => dispatch(id, { type: 'stream_delta', text }),
      streamReset: () => dispatch(id, { type: 'stream_reset' }),
      toolStatus: (event) => dispatch(id, { type: 'tool_status', event }),
      status: (event) => dispatch(id, { type: 'status', event }),
      messageQueued: (event) => dispatch(id, { type: 'message_queued', event }),
      title: (title) => dispatch(id, { type: 'title', title }),
      sheets: (sheets) => dispatch(id, { type: 'sheets', sheets }),
      focusSheet: (event) => dispatch(id, { type: 'focus_sheet', event }),
      participants: (users) => dispatch(id, { type: 'participants', users }),
      rejoined: (reply) => dispatch(id, { type: 'rejoined', reply }),
      disconnected: () => dispatch(id, { type: 'disconnected' }),
    })

    const result = await transport.join()
    const open = conversations.value.get(id)

    if (!result.ok) {
      transport.leave()
      // The entry stays, in `error`, so the view can say "Conversation not
      // found" instead of spinning forever.
      if (open) {
        open.entry = { ...open.entry, status: 'error' }
        open.error = result.error
        triggerRef(conversations)
      }
      return
    }

    if (!open) {
      // Every holder released it while the join was in flight.
      transport.leave()
      return
    }

    open.transport = transport
    const { entry } = reduce(open.entry, { type: 'joined', reply: result.data })
    open.entry = entry
    triggerRef(conversations)
  }

  /** Joins on first use; later callers await the same in-flight join. */
  async function open(id: ConversationId): Promise<void> {
    const existing = conversations.value.get(id)
    if (existing) {
      existing.refs += 1
      await joining.value.get(id)
      return
    }

    conversations.value.set(id, {
      entry: emptyEntry(),
      transport: placeholderTransport(),
      refs: 1,
      error: null,
    })
    triggerRef(conversations)

    const pending = join(id).finally(() => joining.value.delete(id))
    joining.value.set(id, pending)
    await pending
  }

  /** Leaves when the last holder releases it. */
  function close(id: ConversationId): void {
    const existing = conversations.value.get(id)
    if (!existing) return
    existing.refs -= 1
    if (existing.refs > 0) return
    existing.transport.leave()
    conversations.value.delete(id)
    triggerRef(conversations)
  }

  /**
   * There is no optimistic echo: `send_message` replies `{}` and the message
   * comes back with a server id as a `message` push. Contract §7.2 has no
   * `client_op_id` analogue, so a local preview could never be reconciled.
   */
  async function sendMessage(id: ConversationId, text: string): Promise<void> {
    const open = conversations.value.get(id)
    if (!open) return
    const result = await open.transport.sendMessage(text)
    if (!result.ok) dispatch(id, { type: 'send_failed', error: result.error })
  }

  async function cancel(id: ConversationId): Promise<void> {
    const open = conversations.value.get(id)
    if (!open) return
    const result = await open.transport.cancel()
    // `not_running` means the turn ended between the click and the push. That
    // is what the user wanted, so it is not worth a toast.
    if (!result.ok && result.error.code !== 'not_running') {
      dispatch(id, { type: 'send_failed', error: result.error })
    }
  }

  /**
   * Links a sheet the user opened (ST-2). The server broadcasts `sheets` to
   * everyone but deliberately sends no `focus_sheet`, so only this user's tab
   * moves — the caller does that.
   */
  async function openSheet(id: ConversationId, sheetId: SheetId): Promise<LinkedSheet | null> {
    const open = conversations.value.get(id)
    if (!open) return null
    const result = await open.transport.openSheet(sheetId)
    if (result.ok) return result.data.sheet
    dispatch(id, { type: 'send_failed', error: result.error })
    return null
  }

  function errorOf(id: ConversationId): ComputedRef<NormalizedError | null> {
    return computed(() => conversations.value.get(id)?.error ?? null)
  }

  return {
    conversations,
    entryOf,
    open,
    close,
    sendMessage,
    cancel,
    openSheet,
    errorOf,
  }
})

function placeholderTransport(): ConversationTransport {
  const notReady = () =>
    Promise.resolve({ ok: false as const, error: { code: 'internal_error', message: 'joining' } })
  return {
    join: notReady,
    sendMessage: notReady,
    cancel: notReady,
    openSheet: notReady,
    leave: () => {},
  }
}
