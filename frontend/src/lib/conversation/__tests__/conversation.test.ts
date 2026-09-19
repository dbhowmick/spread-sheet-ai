import { describe, expect, it } from 'vitest'

import {
  emptyEntry,
  reduce,
  type ConversationEntry,
  type ConversationEvent,
} from '@/lib/conversation/conversation'
import type {
  ConversationJoinReply,
  ConversationSummary,
  Message,
  TextMessage,
  ToolCallMessage,
  ToolResultMessage,
  UserRef,
} from '@/types/contract'

const alice: UserRef = { id: 'u-alice', display_name: 'Alice' }
const bob: UserRef = { id: 'u-bob', display_name: 'Bob' }

const conversation: ConversationSummary = {
  id: 'c1',
  title: null,
  created_by: alice,
  inserted_at: '2026-09-20T10:00:00Z',
  updated_at: '2026-09-20T10:00:00Z',
}

function userMessage(id: string, sender: UserRef, text: string, at = '2026-09-20T10:00:00Z') {
  return {
    id,
    role: 'user',
    content_type: 'text',
    content: { text },
    sender,
    status: 'completed',
    inserted_at: at,
  } satisfies TextMessage
}

function aiMessage(id: string, text: string, at = '2026-09-20T10:00:01Z') {
  return {
    id,
    role: 'assistant',
    content_type: 'text',
    content: { text },
    sender: null,
    status: 'completed',
    inserted_at: at,
  } satisfies TextMessage
}

function joinReply(overrides: Partial<ConversationJoinReply> = {}): ConversationJoinReply {
  return { conversation, messages: [], sheets: [], status: 'idle', ...overrides }
}

/** Applies a sequence of events, the way the store's dispatch does. */
function run(entry: ConversationEntry, ...events: ConversationEvent[]): ConversationEntry {
  return events.reduce((current, event) => reduce(current, event).entry, entry)
}

function joined(...events: ConversationEvent[]): ConversationEntry {
  return run(emptyEntry(), { type: 'joined', reply: joinReply() }, ...events)
}

describe('joining', () => {
  it('takes the transcript, sheets and status from the reply', () => {
    const entry = joined()
    expect(entry.status).toBe('ready')
    expect(entry.agentStatus).toBe('idle')
    expect(entry.conversation).toEqual(conversation)
  })

  it('keeps participants across a rejoin, and drops the open stream', () => {
    const before = joined(
      { type: 'participants', users: [alice, bob] },
      { type: 'stream_delta', text: 'half a sen' },
    )

    const after = reduce(before, {
      type: 'rejoined',
      reply: joinReply({ messages: [aiMessage('m1', 'half a sentence')] }),
    }).entry

    expect(after.participants).toEqual([alice, bob])
    expect(after.streamingText).toBe('')
    expect(after.messages).toHaveLength(1)
  })
})

describe('messages', () => {
  it('appends in arrival order and never re-sorts by inserted_at', () => {
    // One assistant turn: every part shares a timestamp, and the `sequence`
    // that orders them server-side is not serialized.
    const same = '2026-09-20T10:00:05.123456Z'
    const entry = joined(
      { type: 'message', message: aiMessage('m1', 'first', same) },
      { type: 'message', message: aiMessage('m2', 'second', same) },
      { type: 'message', message: aiMessage('m3', 'third', same) },
    )

    expect(entry.messages.map((m) => m.id)).toEqual(['m1', 'm2', 'm3'])
  })

  it('upserts by id in place, as the re-push after an agent revival needs', () => {
    const entry = joined(
      { type: 'message', message: aiMessage('m1', 'one') },
      { type: 'message', message: aiMessage('m2', 'two') },
      // The channel re-pushes everything from `last_message_at` onwards.
      { type: 'message', message: aiMessage('m1', 'one') },
      { type: 'message', message: aiMessage('m2', 'two') },
    )

    expect(entry.messages.map((m) => m.id)).toEqual(['m1', 'm2'])
  })

  it('replaces a message by id on message_updated, keeping its position', () => {
    const entry = joined(
      { type: 'message', message: aiMessage('m1', 'one') },
      { type: 'message', message: aiMessage('m2', 'two') },
      { type: 'message_updated', message: aiMessage('m1', 'one, revised') },
    )

    expect(entry.messages.map((m) => m.id)).toEqual(['m1', 'm2'])
    expect((entry.messages[0] as TextMessage).content.text).toBe('one, revised')
  })
})

describe('streaming', () => {
  it('accumulates deltas and clears on reset', () => {
    const streaming = joined(
      { type: 'stream_delta', text: 'Hello ' },
      { type: 'stream_delta', text: 'Alice!' },
    )
    expect(streaming.streamingText).toBe('Hello Alice!')

    expect(reduce(streaming, { type: 'stream_reset' }).entry.streamingText).toBe('')
  })

  it('closes the bubble on a run-ending status even without a reset', () => {
    const entry = joined(
      { type: 'stream_delta', text: 'partial' },
      { type: 'status', event: { status: 'idle', error: null } },
    )
    expect(entry.streamingText).toBe('')
  })

  it('leaves the bubble open while the run is still going', () => {
    const entry = joined(
      { type: 'stream_delta', text: 'partial' },
      { type: 'status', event: { status: 'running', error: null } },
    )
    expect(entry.streamingText).toBe('partial')
  })

  it('drops the bubble on a disconnect, because its deltas are gone', () => {
    const entry = joined({ type: 'stream_delta', text: 'partial' }, { type: 'disconnected' })
    expect(entry.streamingText).toBe('')
  })
})

describe('queued messages (CS-4)', () => {
  // The server stores the display message AND broadcasts `message_queued`, so
  // the notice must mark the stored message rather than add a second bubble.
  it('marks the stored message when the notice arrives after it', () => {
    const entry = joined(
      { type: 'message', message: userMessage('m1', bob, 'and Q4?') },
      { type: 'message_queued', event: { sender: bob, text: 'and Q4?' } },
    )

    expect(entry.messages).toHaveLength(1)
    expect([...entry.queuedIds]).toEqual(['m1'])
    expect(entry.pendingQueued).toEqual([])
  })

  it('marks it when the notice arrives first', () => {
    const entry = joined(
      { type: 'message_queued', event: { sender: bob, text: 'and Q4?' } },
      { type: 'message', message: userMessage('m1', bob, 'and Q4?') },
    )

    expect(entry.messages).toHaveLength(1)
    expect([...entry.queuedIds]).toEqual(['m1'])
    expect(entry.pendingQueued).toEqual([])
  })

  it('does not mark an identical message from a different sender', () => {
    const entry = joined(
      { type: 'message', message: userMessage('m1', alice, 'and Q4?') },
      { type: 'message_queued', event: { sender: bob, text: 'and Q4?' } },
    )

    expect(entry.queuedIds.size).toBe(0)
    expect(entry.pendingQueued).toHaveLength(1)
  })

  it('marks two identical messages one at a time, not both at once', () => {
    const entry = joined(
      { type: 'message', message: userMessage('m1', bob, 'again') },
      { type: 'message', message: userMessage('m2', bob, 'again') },
      { type: 'message_queued', event: { sender: bob, text: 'again' } },
    )

    expect([...entry.queuedIds]).toEqual(['m1'])
  })

  it('clears every mark at the next run boundary', () => {
    const entry = joined(
      { type: 'message', message: userMessage('m1', bob, 'and Q4?') },
      { type: 'message_queued', event: { sender: bob, text: 'and Q4?' } },
      { type: 'message_queued', event: { sender: bob, text: 'never stored' } },
      { type: 'status', event: { status: 'idle', error: null } },
    )

    expect(entry.queuedIds.size).toBe(0)
    expect(entry.pendingQueued).toEqual([])
  })
})

describe('status', () => {
  it('records the error and asks for a toast', () => {
    const { entry, effects } = reduce(joined(), {
      type: 'status',
      event: { status: 'error', error: 'model refused' },
    })

    expect(entry.agentStatus).toBe('error')
    expect(entry.agentError).toBe('model refused')
    expect(effects).toEqual([
      { type: 'toast', level: 'error', message: 'The assistant stopped: model refused' },
    ])
  })

  it('says nothing when a run simply ends', () => {
    const { effects } = reduce(joined(), { type: 'status', event: { status: 'idle', error: null } })
    expect(effects).toEqual([])
  })
})

describe('sheets and focus', () => {
  it('bumps seq so the same sheet twice is two requests', () => {
    const entry = joined(
      { type: 'focus_sheet', event: { sheet_id: 's1', reason: 'created' } },
      { type: 'focus_sheet', event: { sheet_id: 's1', reason: 'written' } },
    )

    expect(entry.focusRequest).toEqual({ sheetId: 's1', reason: 'written', seq: 2 })
  })

  it('replaces the whole linked-sheet list', () => {
    const link = {
      sheet: {
        id: 's1',
        name: 'P&L',
        owner: alice,
        row_count: 0,
        column_count: 1,
        version: 1,
        inserted_at: '2026-09-20T10:00:00Z',
        updated_at: '2026-09-20T10:00:00Z',
      },
      created_here: true,
      last_access: 'created' as const,
      first_accessed_at: '2026-09-20T10:00:00Z',
      last_accessed_at: '2026-09-20T10:00:00Z',
    }

    expect(joined({ type: 'sheets', sheets: [link] }).linkedSheets).toEqual([link])
  })

  it('patches the title in place', () => {
    const entry = joined({ type: 'title', title: 'Budget planning' })
    expect(entry.conversation?.title).toBe('Budget planning')
  })
})

describe('tool status', () => {
  it('keeps the latest status per call_id', () => {
    const entry = joined(
      {
        type: 'tool_status',
        event: { call_id: 'c1', name: 'set_cells', display_text: 'Setting', status: 'identified' },
      },
      {
        type: 'tool_status',
        event: { call_id: 'c1', name: 'set_cells', display_text: 'Setting', status: 'executing' },
      },
    )

    expect(entry.toolStatus.get('c1')?.status).toBe('executing')
  })

  it('forgets live statuses once the run ends', () => {
    const entry = joined(
      {
        type: 'tool_status',
        event: { call_id: 'c1', name: 'set_cells', display_text: 'Setting', status: 'completed' },
      },
      { type: 'status', event: { status: 'idle', error: null } },
    )

    expect(entry.toolStatus.size).toBe(0)
  })
})

describe('send failures', () => {
  it('surfaces the server message', () => {
    const { effects } = reduce(joined(), {
      type: 'send_failed',
      error: { code: 'validation_failed', message: 'Message text is required.' },
    })

    expect(effects).toEqual([
      {
        type: 'toast',
        level: 'error',
        message: 'Message text is required.',
        code: 'validation_failed',
      },
    ])
  })
})

// A compile-time guard: the union must keep covering every content type the
// contract names, so `ChatMessage.vue`'s branches stay exhaustive.
const everyContentType: Message['content_type'][] = [
  'text',
  'thinking',
  'tool_call',
  'tool_result',
  'notification',
  'error',
]

describe('contract coverage', () => {
  it('knows all six content types', () => {
    expect(everyContentType).toHaveLength(6)
  })

  it('accepts tool call and result messages', () => {
    const call: ToolCallMessage = {
      id: 'tc1',
      role: 'assistant',
      content_type: 'tool_call',
      content: { call_id: 'c1', name: 'add_column', display_text: 'Adding Q3', arguments: {} },
      sender: null,
      status: 'completed',
      inserted_at: '2026-09-20T10:00:02Z',
    }
    const result: ToolResultMessage = {
      id: 'tr1',
      role: 'tool',
      content_type: 'tool_result',
      content: { tool_call_id: 'c1', name: 'add_column', content: '{}', is_error: false },
      sender: null,
      status: 'completed',
      inserted_at: '2026-09-20T10:00:03Z',
    }

    const entry = joined({ type: 'message', message: call }, { type: 'message', message: result })
    expect(entry.messages).toHaveLength(2)
  })
})
