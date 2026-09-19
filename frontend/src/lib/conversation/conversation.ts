/**
 * The chat client state (contract §7.3, frontend-plan §8.1) as a **pure
 * reducer**: `(entry, event) -> {entry, effects}`.
 *
 * The same shape as `lib/sheet/consistency.ts`, and for the same reason: the
 * fiddly parts — upserting by id, pairing a queued notice with its stored
 * message, opening and closing the streaming bubble — are testable without a
 * socket, a store or a component. `stores/conversations.ts` is then thin.
 */
import type { NormalizedError } from '@/lib/errors'
import type {
  ConversationFocusSheetEvent,
  ConversationJoinReply,
  ConversationJoinStatus,
  ConversationQueuedEvent,
  ConversationStatusEvent,
  ConversationSummary,
  ConversationToolStatusEvent,
  LinkedSheet,
  Message,
  MessageId,
  SheetAccess,
  SheetId,
  UserRef,
  Uuid,
} from '@/types/contract'

export type ConversationStatus = 'joining' | 'ready' | 'error'

/**
 * A `message_queued` notice that has not been matched to a stored message yet.
 * The notice carries no message id, so `sender.id` plus the text is all there
 * is to match on.
 */
export interface QueuedMark {
  senderId: Uuid
  text: string
}

/** The latest `focus_sheet`. See `focusRequest` below. */
export interface FocusRequest {
  sheetId: SheetId
  reason: SheetAccess
  seq: number
}

export interface ConversationEntry {
  conversation: ConversationSummary | null
  /**
   * Upserted by id, in arrival order. Deliberately never re-sorted by
   * `inserted_at`: several parts of one assistant turn share a timestamp, and
   * the `sequence` that orders them server-side is not serialized.
   */
  messages: Message[]
  /** Live text from `stream_delta`. Cleared by `stream_reset`. */
  streamingText: string
  /**
   * Live tool progress by `call_id`. Only a fallback for rendering: once the
   * stored `tool_result` arrives it decides the state (see `render.ts`).
   */
  toolStatus: Map<string, ConversationToolStatusEvent>
  agentStatus: ConversationJoinStatus
  agentError: string | null
  /** Messages currently marked "Queued" (CS-4). */
  queuedIds: Set<MessageId>
  /** Notices still waiting for their stored message. */
  pendingQueued: QueuedMark[]
  linkedSheets: LinkedSheet[]
  participants: UserRef[]
  status: ConversationStatus
  /**
   * The AI touched a sheet and this UI should make its tab active (UI-4).
   *
   * A field rather than the callback frontend-plan §8.1 sketched: it keeps the
   * reducer the only place state changes, it is testable without a component,
   * and it avoids deciding whose callback wins when a ref-counted entry has
   * several holders. `seq` increments on every request, so two in a row for
   * the same sheet still fire a watcher twice.
   */
  focusRequest: FocusRequest | null
}

export type ConversationEvent =
  | { type: 'joined'; reply: ConversationJoinReply }
  | { type: 'rejoined'; reply: ConversationJoinReply }
  | { type: 'message'; message: Message }
  | { type: 'message_updated'; message: Message }
  | { type: 'stream_delta'; text: string }
  | { type: 'stream_reset' }
  | { type: 'tool_status'; event: ConversationToolStatusEvent }
  | { type: 'status'; event: ConversationStatusEvent }
  | { type: 'message_queued'; event: ConversationQueuedEvent }
  | { type: 'title'; title: string }
  | { type: 'sheets'; sheets: LinkedSheet[] }
  | { type: 'focus_sheet'; event: ConversationFocusSheetEvent }
  | { type: 'participants'; users: UserRef[] }
  | { type: 'send_failed'; error: NormalizedError }
  | { type: 'disconnected' }

export type ConversationEffect = {
  type: 'toast'
  level: 'error' | 'warning'
  message?: string
  code?: string
}

export interface Reduction {
  entry: ConversationEntry
  effects: ConversationEffect[]
}

export function emptyEntry(): ConversationEntry {
  return {
    conversation: null,
    messages: [],
    streamingText: '',
    toolStatus: new Map(),
    agentStatus: 'not_started',
    agentError: null,
    queuedIds: new Set(),
    pendingQueued: [],
    linkedSheets: [],
    participants: [],
    status: 'joining',
    focusRequest: null,
  }
}

/** A fresh entry from a join or rejoin reply. Participants are set separately. */
function entryFromReply(reply: ConversationJoinReply): ConversationEntry {
  return {
    ...emptyEntry(),
    conversation: reply.conversation,
    messages: reply.messages,
    linkedSheets: reply.sheets,
    agentStatus: reply.status,
    status: 'ready',
  }
}

/** A run-ending status: the turn is over, so nothing is streaming any more. */
function endsRun(status: ConversationStatusEvent['status']): boolean {
  return status !== 'running'
}

/** The text a `message_queued` notice would carry for this message. */
function queueKey(message: Message): QueuedMark | null {
  if (message.role !== 'user' || message.content_type !== 'text') return null
  if (!message.sender) return null
  return { senderId: message.sender.id, text: message.content.text.trim() }
}

function sameMark(a: QueuedMark, b: QueuedMark): boolean {
  return a.senderId === b.senderId && a.text === b.text
}

/**
 * Adds or replaces `message` by id, keeping its position when it is already
 * there. Upserting is not an optimization: the channel re-pushes every stored
 * message from `last_message_at` onwards whenever a pending agent subscription
 * is revived (`conversation_channel.ex`, `push_messages_since_last/1`).
 */
function upsert(messages: Message[], message: Message): Message[] {
  const at = messages.findIndex((m) => m.id === message.id)
  if (at === -1) return [...messages, message]
  const next = messages.slice()
  next[at] = message
  return next
}

export function reduce(entry: ConversationEntry, event: ConversationEvent): Reduction {
  switch (event.type) {
    case 'joined':
      return {
        entry: { ...entryFromReply(event.reply), participants: entry.participants },
        effects: [],
      }

    case 'rejoined':
      // Any stream in flight when the socket dropped is lost; its text arrives
      // again as stored messages. Participants survive — a `participants` push
      // follows the rejoin anyway.
      return {
        entry: { ...entryFromReply(event.reply), participants: entry.participants },
        effects: [],
      }

    case 'message': {
      const messages = upsert(entry.messages, event.message)

      // The notice and the stored message race: the server stores the display
      // message first and broadcasts `message_queued` after, but the two reach
      // a given subscriber in either order. So both cases try to match.
      const mark = queueKey(event.message)
      const at = mark ? entry.pendingQueued.findIndex((p) => sameMark(p, mark)) : -1
      if (at === -1) return { entry: { ...entry, messages }, effects: [] }

      const pendingQueued = entry.pendingQueued.slice()
      pendingQueued.splice(at, 1)
      return {
        entry: {
          ...entry,
          messages,
          pendingQueued,
          queuedIds: new Set(entry.queuedIds).add(event.message.id),
        },
        effects: [],
      }
    }

    case 'message_updated':
      // Only ever revises a message that already exists (a tool call
      // finishing), so there is no queue reconciliation to do.
      return { entry: { ...entry, messages: upsert(entry.messages, event.message) }, effects: [] }

    case 'stream_delta':
      return { entry: { ...entry, streamingText: entry.streamingText + event.text }, effects: [] }

    case 'stream_reset':
      return { entry: { ...entry, streamingText: '' }, effects: [] }

    case 'tool_status':
      return {
        entry: {
          ...entry,
          toolStatus: new Map(entry.toolStatus).set(event.event.call_id, event.event),
        },
        effects: [],
      }

    case 'status': {
      const { status, error } = event.event
      const ending = endsRun(status)
      return {
        entry: {
          ...entry,
          agentStatus: status,
          agentError: error,
          // The server pushes `status` only when it changes, so any status
          // event means the run boundary moved and nothing marked before it is
          // still waiting — whether the agent went idle first or stepped
          // straight into the queued turn.
          queuedIds: entry.queuedIds.size ? new Set() : entry.queuedIds,
          pendingQueued: entry.pendingQueued.length ? [] : entry.pendingQueued,
          // `stream_reset` normally precedes a run-ending status; clearing here
          // too means a dropped reset can't leave a bubble open forever.
          streamingText: ending ? '' : entry.streamingText,
          toolStatus: ending && entry.toolStatus.size ? new Map() : entry.toolStatus,
        },
        effects:
          status === 'error' ? [{ type: 'toast', level: 'error', message: errorText(error) }] : [],
      }
    }

    case 'message_queued': {
      const mark: QueuedMark = { senderId: event.event.sender.id, text: event.event.text.trim() }
      const match = entry.messages.find((m) => {
        const key = queueKey(m)
        return key !== null && sameMark(key, mark) && !entry.queuedIds.has(m.id)
      })

      if (!match) {
        return { entry: { ...entry, pendingQueued: [...entry.pendingQueued, mark] }, effects: [] }
      }
      return {
        entry: { ...entry, queuedIds: new Set(entry.queuedIds).add(match.id) },
        effects: [],
      }
    }

    case 'title':
      if (!entry.conversation) return { entry, effects: [] }
      return {
        entry: { ...entry, conversation: { ...entry.conversation, title: event.title } },
        effects: [],
      }

    case 'sheets':
      return { entry: { ...entry, linkedSheets: event.sheets }, effects: [] }

    case 'focus_sheet':
      return {
        entry: {
          ...entry,
          focusRequest: {
            sheetId: event.event.sheet_id,
            reason: event.event.reason,
            seq: (entry.focusRequest?.seq ?? 0) + 1,
          },
        },
        effects: [],
      }

    case 'participants':
      return { entry: { ...entry, participants: event.users }, effects: [] }

    case 'send_failed':
      return {
        entry,
        effects: [
          { type: 'toast', level: 'error', message: event.error.message, code: event.error.code },
        ],
      }

    case 'disconnected':
      // Nothing to roll back — chat has no pending-op bookkeeping. The open
      // bubble goes, because the deltas that would finish it are gone.
      return { entry: { ...entry, streamingText: '' }, effects: [] }
  }
}

function errorText(error: string | null): string {
  return error ? `The assistant stopped: ${error}` : 'The assistant stopped unexpectedly.'
}
