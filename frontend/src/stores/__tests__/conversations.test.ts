import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import type { ConversationTransport, ConversationTransportHandlers } from '@/lib/transport/types'
import type { ConversationJoinReply, ConversationSummary, UserRef } from '@/types/contract'

const alice: UserRef = { id: 'u-alice', display_name: 'Alice' }
const bob: UserRef = { id: 'u-bob', display_name: 'Bob' }

const conversation: ConversationSummary = {
  id: 'c1',
  title: 'Budget planning',
  created_by: alice,
  inserted_at: '2026-09-20T10:00:00Z',
  updated_at: '2026-09-20T10:00:00Z',
}

const reply: ConversationJoinReply = {
  conversation,
  messages: [],
  sheets: [],
  status: 'idle',
}

const join = vi.fn()
const leave = vi.fn()
const sendMessage = vi.fn()
const cancel = vi.fn()
const openSheet = vi.fn()
let lastHandlers: ConversationTransportHandlers | null = null

vi.mock('@/lib/transport', () => ({
  createConversationTransport: (
    _id: string,
    handlers: ConversationTransportHandlers,
  ): ConversationTransport => {
    lastHandlers = handlers
    return { join, leave, sendMessage, cancel, openSheet }
  },
}))

const toastError = vi.fn()
vi.mock('vue-sonner', () => ({
  toast: { error: (...args: unknown[]) => toastError(...args), warning: vi.fn() },
}))

const { useConversationsStore } = await import('@/stores/conversations')

function ok<T>(data: T) {
  return { ok: true as const, data }
}

describe('joining a conversation', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    lastHandlers = null
    join.mockReset()
    leave.mockReset()
    sendMessage.mockReset()
    cancel.mockReset()
    openSheet.mockReset()
    toastError.mockReset()
  })

  it('is ready once the join reply arrives', async () => {
    join.mockResolvedValue(ok(reply))
    const store = useConversationsStore()

    await store.open('c1')

    expect(store.entryOf('c1')?.status).toBe('ready')
    expect(store.entryOf('c1')?.conversation).toEqual(conversation)
    expect(store.errorOf('c1').value).toBeNull()
    expect(lastHandlers).not.toBeNull()
  })

  it('keeps a failed join visible as an error instead of joining forever', async () => {
    join.mockResolvedValue({
      ok: false,
      error: { code: 'not_found', message: 'Conversation not found.' },
    })
    const store = useConversationsStore()

    await store.open('missing')

    expect(store.entryOf('missing')?.status).toBe('error')
    expect(store.errorOf('missing').value?.code).toBe('not_found')
    expect(leave).toHaveBeenCalledOnce()
  })

  it('leaves only when the last holder releases it (§6.4)', async () => {
    join.mockResolvedValue(ok(reply))
    const store = useConversationsStore()

    await store.open('c1')
    await store.open('c1')

    store.close('c1')
    expect(leave).not.toHaveBeenCalled()
    expect(store.entryOf('c1')?.status).toBe('ready')

    store.close('c1')
    expect(leave).toHaveBeenCalledOnce()
    expect(store.entryOf('c1')).toBeNull()
  })

  it('joins once when two holders arrive together', async () => {
    join.mockResolvedValue(ok(reply))
    const store = useConversationsStore()

    await Promise.all([store.open('c1'), store.open('c1')])

    expect(join).toHaveBeenCalledOnce()
  })
})

describe('channel events reach the reducer', () => {
  beforeEach(async () => {
    setActivePinia(createPinia())
    lastHandlers = null
    join.mockReset().mockResolvedValue(ok(reply))
    leave.mockReset()
    toastError.mockReset()
    await useConversationsStore().open('c1')
  })

  it('streams deltas into the entry', () => {
    const store = useConversationsStore()

    lastHandlers?.streamDelta('Hello ')
    lastHandlers?.streamDelta('Alice!')

    expect(store.entryOf('c1')?.streamingText).toBe('Hello Alice!')
  })

  it('records participants', () => {
    lastHandlers?.participants([alice, bob])
    expect(useConversationsStore().entryOf('c1')?.participants).toEqual([alice, bob])
  })

  it('bumps focusRequest so the workspace can watch it (UI-4)', () => {
    const store = useConversationsStore()

    lastHandlers?.focusSheet({ sheet_id: 's1', reason: 'created' })
    expect(store.entryOf('c1')?.focusRequest).toEqual({
      sheetId: 's1',
      reason: 'created',
      seq: 1,
    })

    lastHandlers?.focusSheet({ sheet_id: 's1', reason: 'written' })
    expect(store.entryOf('c1')?.focusRequest?.seq).toBe(2)
  })

  it('replaces the transcript on a rejoin', () => {
    const store = useConversationsStore()

    lastHandlers?.streamDelta('half a sen')
    lastHandlers?.rejoined({
      ...reply,
      messages: [
        {
          id: 'm1',
          role: 'assistant',
          content_type: 'text',
          content: { text: 'half a sentence' },
          sender: null,
          status: 'completed',
          inserted_at: '2026-09-20T10:00:01Z',
        },
      ],
    })

    expect(store.entryOf('c1')?.streamingText).toBe('')
    expect(store.entryOf('c1')?.messages).toHaveLength(1)
  })
})

describe('actions', () => {
  beforeEach(async () => {
    setActivePinia(createPinia())
    join.mockReset().mockResolvedValue(ok(reply))
    leave.mockReset()
    sendMessage.mockReset()
    cancel.mockReset()
    openSheet.mockReset()
    toastError.mockReset()
    await useConversationsStore().open('c1')
  })

  it('sends text without an optimistic echo (contract §7.2)', async () => {
    sendMessage.mockResolvedValue(ok({}))
    const store = useConversationsStore()

    await store.sendMessage('c1', 'hi')

    expect(sendMessage).toHaveBeenCalledWith('hi')
    // The bubble only appears when the server pushes it back.
    expect(store.entryOf('c1')?.messages).toEqual([])
  })

  it('toasts when a send is rejected', async () => {
    sendMessage.mockResolvedValue({
      ok: false,
      error: { code: 'validation_failed', message: 'Message text is required.' },
    })

    await useConversationsStore().sendMessage('c1', '   ')

    expect(toastError).toHaveBeenCalledWith('Message text is required.')
  })

  it('stays quiet when cancelling a turn that just ended', async () => {
    cancel.mockResolvedValue({ ok: false, error: { code: 'not_running' } })

    await useConversationsStore().cancel('c1')

    expect(toastError).not.toHaveBeenCalled()
  })

  it('returns the link from open_sheet (ST-2)', async () => {
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
      created_here: false,
      last_access: 'opened' as const,
      first_accessed_at: '2026-09-20T10:00:00Z',
      last_accessed_at: '2026-09-20T10:00:00Z',
    }
    openSheet.mockResolvedValue(ok({ sheet: link }))

    await expect(useConversationsStore().openSheet('c1', 's1')).resolves.toEqual(link)
    expect(openSheet).toHaveBeenCalledWith('s1')
  })
})
