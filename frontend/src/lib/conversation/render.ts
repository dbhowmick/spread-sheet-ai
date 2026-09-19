/**
 * The chat transcript as a flat list of things to draw (frontend-plan §8.2).
 *
 * Pure, so the awkward parts — folding a `tool_result` into the `tool_call` it
 * answers, deciding a tool's state when only the live `tool_status` is known —
 * are unit-tested, and `ChatPanel.vue` stays a `v-for`.
 */
import type {
  ConversationToolStatusEvent,
  Message,
  ToolCallMessage,
  ToolResultMessage,
  Uuid,
} from '@/types/contract'

import type { ConversationEntry } from './conversation'

/**
 * The subset of AI Elements' `ToolUIPart['state']` this app can reach. HITL is
 * off server-side, so the approval and denied states never occur.
 */
export type ToolUiState =
  | 'input-streaming'
  | 'input-available'
  | 'output-available'
  | 'output-error'

export interface ChatMessageItem {
  kind: 'message'
  key: string
  message: Exclude<Message, ToolCallMessage | ToolResultMessage>
  /** The local user wrote it, so it aligns to the end and needs no name. */
  isSelf: boolean
  queued: boolean
}

export interface ChatToolItem {
  kind: 'tool'
  key: string
  call: ToolCallMessage
  result: ToolResultMessage | null
  state: ToolUiState
  /** `display_text` — "Adding a Q3 column", not `add_column`. */
  title: string
}

export interface ChatStreamingItem {
  kind: 'streaming'
  key: 'streaming'
  text: string
}

export type ChatItem = ChatMessageItem | ChatToolItem | ChatStreamingItem

const LIVE_STATES: Record<ConversationToolStatusEvent['status'], ToolUiState> = {
  identified: 'input-streaming',
  executing: 'input-available',
  completed: 'output-available',
  failed: 'output-error',
}

function isToolCall(message: Message): message is ToolCallMessage {
  return message.content_type === 'tool_call'
}

function isToolResult(message: Message): message is ToolResultMessage {
  return message.content_type === 'tool_result'
}

function toolState(
  result: ToolResultMessage | null,
  live: ConversationToolStatusEvent | undefined,
): ToolUiState {
  // A stored result is the truth; `tool_status` is only live progress, and the
  // server stops sending it once the call is done.
  if (result) return result.content.is_error ? 'output-error' : 'output-available'
  if (live) return LIVE_STATES[live.status]
  return 'input-streaming'
}

/**
 * Walks the transcript once, pairing each `tool_call` with the `tool_result`
 * carrying the same `call_id`. Results are drawn inside their call, never on
 * their own; an orphan result (its call not yet stored) is dropped rather than
 * shown bare.
 */
export function chatItems(entry: ConversationEntry, selfUserId: Uuid | null): ChatItem[] {
  const results = new Map<string, ToolResultMessage>()
  for (const message of entry.messages) {
    if (isToolResult(message)) results.set(message.content.tool_call_id, message)
  }

  const items: ChatItem[] = []
  for (const message of entry.messages) {
    if (isToolResult(message)) continue

    if (isToolCall(message)) {
      const callId = message.content.call_id
      const result = results.get(callId) ?? null
      items.push({
        kind: 'tool',
        key: message.id,
        call: message,
        result,
        state: toolState(result, entry.toolStatus.get(callId)),
        title: message.content.display_text || message.content.name,
      })
      continue
    }

    items.push({
      kind: 'message',
      key: message.id,
      message,
      isSelf: message.sender !== null && message.sender.id === selfUserId,
      queued: entry.queuedIds.has(message.id),
    })
  }

  if (entry.streamingText) {
    items.push({ kind: 'streaming', key: 'streaming', text: entry.streamingText })
  }

  return items
}

/**
 * A tool result's body is a string that is usually JSON. Pretty-printed when it
 * parses, left alone when it doesn't — the error results are plain prose
 * (`ERROR unknown_column: …`).
 */
export function formatToolOutput(content: string): string {
  try {
    return JSON.stringify(JSON.parse(content), null, 2)
  } catch {
    return content
  }
}
