/**
 * Channel-backed implementation of the transport interfaces (contract §5, §7).
 *
 * Cannot be exercised against a real server until the backend reaches M1 —
 * `UserSocket` declares no channel routes yet, so a join currently replies
 * `{reason: "unmatched topic"}`, which `normalizeChannelError` handles.
 */
import type { Channel } from 'phoenix'

import { normalizeChannelError } from '@/lib/errors'
import { joinTopic } from '@/lib/socket'
import type {
  ConversationJoinReply,
  ConversationFocusSheetEvent,
  ConversationMessageEvent,
  ConversationQueuedEvent,
  ConversationSheetsEvent,
  ConversationStatusEvent,
  ConversationStreamDeltaEvent,
  ConversationTitleEvent,
  ConversationToolStatusEvent,
  OpAppliedEvent,
  OpenSheetReply,
  ParticipantsEvent,
  Sheet,
  SheetId,
  SheetJoinReply,
  SnapshotReply,
  Uuid,
} from '@/types/contract'

import {
  PUSH_TIMEOUT_MS,
  type ChannelResult,
  type ConversationTransport,
  type ConversationTransportHandlers,
  type Empty,
  type SheetTransport,
  type SheetTransportHandlers,
} from './types'

/**
 * Never rejects: every push resolves to a `ChannelResult`, exactly like
 * `lib/api.ts`, so callers never need try/catch.
 */
export function pushResult<T>(
  channel: Channel,
  event: string,
  payload: object,
): Promise<ChannelResult<T>> {
  return new Promise((resolve) => {
    channel
      .push(event, payload, PUSH_TIMEOUT_MS)
      .receive('ok', (reply: unknown) => resolve({ ok: true, data: reply as T }))
      .receive('error', (reply: unknown) =>
        resolve({ ok: false, error: normalizeChannelError(reply) }),
      )
      .receive('timeout', () => resolve({ ok: false, error: { code: 'timeout' } }))
  })
}

const notJoined = (): ChannelResult<never> => ({
  ok: false,
  error: { code: 'internal_error', message: 'not joined' },
})

/** Injected so tests can drive a fake Channel without a live socket. */
export interface ChannelDeps {
  joinTopic: (topic: string) => Promise<Channel>
}

const defaultDeps: ChannelDeps = { joinTopic }

/**
 * Wires a channel's join `Push` so the first reply resolves `join()` and every
 * later one becomes a `rejoined` handler call.
 *
 * Phoenix has no `rejoined` event of its own, but it gives us one for free: on
 * reconnect `Channel.rejoin` resends the *same* join `Push`, and
 * `Push.matchReceive` re-fires every registered hook. So one `receive('ok')`
 * plus a `settled` flag covers both cases. The hooks must be chained onto the
 * same statement as `join()`, because `Push.receive` fires immediately if the
 * status has already arrived.
 */
function joinOnce<R>(channel: Channel, onRejoin: (reply: R) => void): Promise<ChannelResult<R>> {
  let settled = false
  return new Promise((resolve) => {
    channel
      .join(PUSH_TIMEOUT_MS)
      .receive('ok', (reply: R) => {
        if (settled) {
          onRejoin(reply)
          return
        }
        settled = true
        resolve({ ok: true, data: reply })
      })
      .receive('error', (reply: unknown) => {
        if (settled) return // a *re*join failed; onError has already fired
        settled = true
        resolve({ ok: false, error: normalizeChannelError(reply) })
      })
      .receive('timeout', () => {
        if (settled) return
        settled = true
        resolve({ ok: false, error: { code: 'timeout' } })
      })
  })
}

export function createPhoenixSheetTransport(
  sheetId: SheetId,
  handlers: SheetTransportHandlers,
  deps: ChannelDeps = defaultDeps,
): SheetTransport {
  let channel: Channel | null = null

  return {
    async join(): Promise<ChannelResult<{ sheet: Sheet }>> {
      const ch = (channel = await deps.joinTopic(`sheet:${sheetId}`))

      ch.on('op_applied', (payload: OpAppliedEvent) => handlers.opApplied(payload))
      ch.on('participants', (payload: ParticipantsEvent) => handlers.participants(payload.users))
      ch.onError(() => handlers.disconnected?.())
      ch.onClose(() => handlers.disconnected?.())

      return joinOnce<SheetJoinReply>(ch, (reply) => handlers.rejoined(reply.sheet))
    },

    pushOp(clientOpId, op) {
      if (!channel) return Promise.resolve(notJoined())
      return pushResult<{ version: number }>(channel, 'op', { client_op_id: clientOpId, op })
    },

    snapshot() {
      if (!channel) return Promise.resolve(notJoined())
      return pushResult<SnapshotReply>(channel, 'snapshot', {})
    },

    leave() {
      channel?.leave()
      channel = null
    },
  }
}

export function createPhoenixConversationTransport(
  conversationId: Uuid,
  handlers: ConversationTransportHandlers,
  deps: ChannelDeps = defaultDeps,
): ConversationTransport {
  let channel: Channel | null = null

  return {
    async join(): Promise<ChannelResult<ConversationJoinReply>> {
      const ch = (channel = await deps.joinTopic(`conversation:${conversationId}`))

      ch.on('message', (p: ConversationMessageEvent) => handlers.message(p.message))
      ch.on('message_updated', (p: ConversationMessageEvent) => handlers.messageUpdated(p.message))
      ch.on('stream_delta', (p: ConversationStreamDeltaEvent) => handlers.streamDelta(p.text))
      ch.on('stream_reset', () => handlers.streamReset())
      ch.on('tool_status', (p: ConversationToolStatusEvent) => handlers.toolStatus(p))
      ch.on('status', (p: ConversationStatusEvent) => handlers.status(p))
      ch.on('message_queued', (p: ConversationQueuedEvent) => handlers.messageQueued(p))
      ch.on('title', (p: ConversationTitleEvent) => handlers.title(p.title))
      ch.on('sheets', (p: ConversationSheetsEvent) => handlers.sheets(p.sheets))
      ch.on('focus_sheet', (p: ConversationFocusSheetEvent) => handlers.focusSheet(p))
      ch.on('participants', (p: ParticipantsEvent) => handlers.participants(p.users))
      ch.onError(() => handlers.disconnected?.())
      ch.onClose(() => handlers.disconnected?.())

      return joinOnce<ConversationJoinReply>(ch, (reply) => handlers.rejoined(reply))
    },

    sendMessage(text) {
      if (!channel) return Promise.resolve(notJoined())
      return pushResult<Empty>(channel, 'send_message', { text })
    },

    cancel() {
      if (!channel) return Promise.resolve(notJoined())
      return pushResult<Empty>(channel, 'cancel', {})
    },

    openSheet(sheetId) {
      if (!channel) return Promise.resolve(notJoined())
      return pushResult<OpenSheetReply>(channel, 'open_sheet', { sheet_id: sheetId })
    },

    leave() {
      channel?.leave()
      channel = null
    },
  }
}
