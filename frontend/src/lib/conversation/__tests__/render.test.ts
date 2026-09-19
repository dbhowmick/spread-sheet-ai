import { describe, expect, it } from 'vitest'

import { emptyEntry, type ConversationEntry } from '@/lib/conversation/conversation'
import { chatItems, formatToolOutput, type ChatToolItem } from '@/lib/conversation/render'
import type {
  ConversationToolStatusEvent,
  Message,
  TextMessage,
  ToolCallMessage,
  ToolResultMessage,
  UserRef,
} from '@/types/contract'

const alice: UserRef = { id: 'u-alice', display_name: 'Alice' }
const bob: UserRef = { id: 'u-bob', display_name: 'Bob' }

function entryWith(messages: Message[], overrides: Partial<ConversationEntry> = {}) {
  return { ...emptyEntry(), messages, status: 'ready' as const, ...overrides }
}

function call(id: string, callId: string, name = 'set_cells'): ToolCallMessage {
  return {
    id,
    role: 'assistant',
    content_type: 'tool_call',
    content: { call_id: callId, name, display_text: 'Updating cells', arguments: { rows: 2 } },
    sender: null,
    status: 'completed',
    inserted_at: '2026-09-20T10:00:02Z',
  }
}

function result(id: string, callId: string, isError = false): ToolResultMessage {
  return {
    id,
    role: 'tool',
    content_type: 'tool_result',
    content: {
      tool_call_id: callId,
      name: 'set_cells',
      content: isError ? 'ERROR unknown_column: no such column' : '{"version":2,"updated":1}',
      is_error: isError,
    },
    sender: null,
    status: 'completed',
    inserted_at: '2026-09-20T10:00:03Z',
  }
}

function text(id: string, sender: UserRef | null, body: string): TextMessage {
  return {
    id,
    role: sender ? 'user' : 'assistant',
    content_type: 'text',
    content: { text: body },
    sender,
    status: 'completed',
    inserted_at: '2026-09-20T10:00:00Z',
  }
}

describe('pairing tool calls with their results', () => {
  it('folds the result into its call and drops it from the top level', () => {
    const items = chatItems(entryWith([call('tc1', 'c1'), result('tr1', 'c1')]), null)

    expect(items).toHaveLength(1)
    const tool = items[0] as ChatToolItem
    expect(tool.kind).toBe('tool')
    expect(tool.result?.id).toBe('tr1')
    expect(tool.state).toBe('output-available')
    expect(tool.title).toBe('Updating cells')
  })

  it('pairs by call_id, not by adjacency', () => {
    const items = chatItems(
      entryWith([call('tc1', 'c1'), call('tc2', 'c2'), result('tr2', 'c2'), result('tr1', 'c1')]),
      null,
    )

    const tools = items.filter((i): i is ChatToolItem => i.kind === 'tool')
    expect(tools.map((t) => t.call.id)).toEqual(['tc1', 'tc2'])
    expect(tools.map((t) => t.result?.id)).toEqual(['tr1', 'tr2'])
  })

  it('reports an errored result as output-error', () => {
    const items = chatItems(entryWith([call('tc1', 'c1'), result('tr1', 'c1', true)]), null)
    expect((items[0] as ChatToolItem).state).toBe('output-error')
  })

  it('drops an orphan result rather than drawing it bare', () => {
    expect(chatItems(entryWith([result('tr1', 'c-missing')]), null)).toEqual([])
  })
})

describe('a call with no result yet', () => {
  const live = (status: ConversationToolStatusEvent['status']) =>
    new Map<string, ConversationToolStatusEvent>([
      ['c1', { call_id: 'c1', name: 'set_cells', display_text: 'Updating cells', status }],
    ])

  it('falls back to the live tool_status', () => {
    const items = chatItems(entryWith([call('tc1', 'c1')], { toolStatus: live('executing') }), null)
    expect((items[0] as ChatToolItem).state).toBe('input-available')
  })

  it('maps every contract status (frontend-plan §8.2)', () => {
    const states = (['identified', 'executing', 'completed', 'failed'] as const).map((status) => {
      const items = chatItems(entryWith([call('tc1', 'c1')], { toolStatus: live(status) }), null)
      return (items[0] as ChatToolItem).state
    })

    expect(states).toEqual([
      'input-streaming',
      'input-available',
      'output-available',
      'output-error',
    ])
  })

  it('shows as pending when nothing is known at all', () => {
    const items = chatItems(entryWith([call('tc1', 'c1')]), null)
    expect((items[0] as ChatToolItem).state).toBe('input-streaming')
  })

  it('lets a stored result beat a stale live status', () => {
    const items = chatItems(
      entryWith([call('tc1', 'c1'), result('tr1', 'c1', true)], { toolStatus: live('executing') }),
      null,
    )
    expect((items[0] as ChatToolItem).state).toBe('output-error')
  })
})

describe('messages', () => {
  it('marks the local user’s own messages', () => {
    const items = chatItems(
      entryWith([text('m1', alice, 'hi'), text('m2', bob, 'hello'), text('m3', null, 'Hi both')]),
      alice.id,
    )

    expect(items.map((i) => i.kind === 'message' && i.isSelf)).toEqual([true, false, false])
  })

  it('carries the queued flag through', () => {
    const items = chatItems(
      entryWith([text('m1', bob, 'and Q4?')], { queuedIds: new Set(['m1']) }),
      alice.id,
    )

    expect(items[0]).toMatchObject({ kind: 'message', queued: true })
  })

  it('keeps an unknown content type rather than dropping it', () => {
    // MessageJSON whitelists six types but passes anything else through raw.
    const exotic = {
      id: 'm1',
      role: 'assistant',
      content_type: 'todo_snapshot',
      content: { text: 'whatever' },
      sender: null,
      status: 'completed',
      inserted_at: '2026-09-20T10:00:00Z',
    } as unknown as Message

    const items = chatItems(entryWith([exotic]), null)
    expect(items).toHaveLength(1)
    expect(items[0]?.kind).toBe('message')
  })
})

describe('the streaming bubble', () => {
  it('goes last, and only when there is text', () => {
    expect(chatItems(entryWith([text('m1', alice, 'hi')]), alice.id)).toHaveLength(1)

    const items = chatItems(
      entryWith([text('m1', alice, 'hi')], { streamingText: 'Thinking' }),
      alice.id,
    )
    expect(items.at(-1)).toEqual({ kind: 'streaming', key: 'streaming', text: 'Thinking' })
  })
})

describe('formatToolOutput', () => {
  it('pretty-prints JSON', () => {
    expect(formatToolOutput('{"version":2}')).toBe('{\n  "version": 2\n}')
  })

  it('leaves prose alone', () => {
    const prose = 'ERROR unknown_column: column "Q3" does not exist'
    expect(formatToolOutput(prose)).toBe(prose)
  })
})
