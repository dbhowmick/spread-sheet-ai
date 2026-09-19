import { createPinia, setActivePinia } from 'pinia'
import { flushPromises, mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it } from 'vitest'

import ChatMessage from '@/components/chat/ChatMessage.vue'
import ToolCallItem from '@/components/chat/ToolCallItem.vue'
import type { ChatMessageItem, ChatToolItem } from '@/lib/conversation/render'
import type {
  ErrorMessage,
  Message,
  NotificationMessage,
  TextMessage,
  ThinkingMessage,
  ToolCallMessage,
  ToolResultMessage,
  UserRef,
} from '@/types/contract'

const bob: UserRef = { id: 'u-bob', display_name: 'Bob' }

function messageItem(message: Message, overrides: Partial<ChatMessageItem> = {}): ChatMessageItem {
  return {
    kind: 'message',
    key: message.id,
    message: message as ChatMessageItem['message'],
    isSelf: false,
    queued: false,
    ...overrides,
  }
}

function text(body: string, sender: UserRef | null = null): TextMessage {
  return {
    id: 'm1',
    role: sender ? 'user' : 'assistant',
    content_type: 'text',
    content: { text: body },
    sender,
    status: 'completed',
    inserted_at: '2026-09-20T10:00:00Z',
  }
}

function mountMessage(item: ChatMessageItem) {
  setActivePinia(createPinia())
  return mount(ChatMessage, { props: { item } })
}

describe('ChatMessage', () => {
  beforeEach(() => setActivePinia(createPinia()))

  it('names other people above their message (CS-3)', async () => {
    const wrapper = mountMessage(messageItem(text('and Q4?', bob)))
    await flushPromises()
    expect(wrapper.text()).toContain('Bob')
    expect(wrapper.text()).toContain('and Q4?')
  })

  it('leaves the local user unnamed', () => {
    const wrapper = mountMessage(messageItem(text('hi', bob), { isSelf: true }))
    expect(wrapper.text()).not.toContain('Bob')
  })

  it('badges a queued message exactly once (CS-4)', () => {
    const wrapper = mountMessage(messageItem(text('and Q4?', bob), { queued: true }))
    expect(wrapper.text().match(/Queued/g)).toHaveLength(1)
  })

  it('renders a notification as a plain system line, not a bubble', () => {
    const notification: NotificationMessage = {
      id: 'm1',
      role: 'assistant',
      content_type: 'notification',
      content: { text: 'Stopped by Alice.', stop_reason: 'cancelled' },
      sender: null,
      status: 'cancelled',
      inserted_at: '2026-09-20T10:00:00Z',
    }

    const wrapper = mountMessage(messageItem(notification))
    expect(wrapper.text()).toContain('Stopped by Alice.')
    // `notification` is cancelled by definition, so no second "Stopped." marker.
    expect(wrapper.text()).not.toContain('Stopped.')
  })

  it('marks an unfinished message with its stop reason', () => {
    const cut: TextMessage = {
      ...text('a long answer'),
      content: { text: 'a long answer', stop_reason: 'length' },
    }
    const wrapper = mountMessage(messageItem(cut))
    expect(wrapper.text()).toContain('length limit')
  })

  it('renders an error message destructively', () => {
    const error: ErrorMessage = {
      id: 'm1',
      role: 'assistant',
      content_type: 'error',
      content: { text: 'The model is unavailable.', error_type: 'LangChainError' },
      sender: null,
      status: 'failed',
      inserted_at: '2026-09-20T10:00:00Z',
    }

    const wrapper = mountMessage(messageItem(error))
    expect(wrapper.text()).toContain('The model is unavailable.')
    expect(wrapper.find('.text-destructive').exists()).toBe(true)
  })

  it('puts thinking in a collapsible rather than the transcript', () => {
    const thinking: ThinkingMessage = {
      id: 'm1',
      role: 'assistant',
      content_type: 'thinking',
      content: { text: 'The user wants quarterly columns.' },
      sender: null,
      status: 'completed',
      inserted_at: '2026-09-20T10:00:00Z',
    }

    const wrapper = mountMessage(messageItem(thinking))
    expect(wrapper.html()).toContain('data-state')
  })

  it('still shows text for a content type the contract does not name', async () => {
    // MessageJSON passes unknown types through raw.
    const exotic = {
      id: 'm1',
      role: 'assistant',
      content_type: 'todo_snapshot',
      content: { text: 'one todo' },
      sender: null,
      status: 'completed',
      inserted_at: '2026-09-20T10:00:00Z',
    } as unknown as Message

    const wrapper = mountMessage(messageItem(exotic))
    await flushPromises()
    expect(wrapper.text()).toContain('one todo')
  })
})

function call(): ToolCallMessage {
  return {
    id: 'tc1',
    role: 'assistant',
    content_type: 'tool_call',
    content: {
      call_id: 'c1',
      name: 'set_cells',
      display_text: 'Updating cells',
      arguments: { sheet: 'P&L' },
    },
    sender: null,
    status: 'completed',
    inserted_at: '2026-09-20T10:00:02Z',
  }
}

function result(isError: boolean): ToolResultMessage {
  return {
    id: 'tr1',
    role: 'tool',
    content_type: 'tool_result',
    content: {
      tool_call_id: 'c1',
      name: 'set_cells',
      content: isError ? 'ERROR unknown_column: no column "Q3"' : '{"updated":1}',
      is_error: isError,
    },
    sender: null,
    status: isError ? 'failed' : 'completed',
    inserted_at: '2026-09-20T10:00:03Z',
  }
}

function toolItem(overrides: Partial<ChatToolItem> = {}): ChatToolItem {
  return {
    kind: 'tool',
    key: 'tc1',
    call: call(),
    result: result(false),
    state: 'output-available',
    title: 'Updating cells',
    ...overrides,
  }
}

describe('ToolCallItem', () => {
  it('titles the block with display_text, not the tool name (AI-7)', () => {
    const wrapper = mount(ToolCallItem, { props: { item: toolItem() } })
    expect(wrapper.text()).toContain('Updating cells')
    expect(wrapper.text()).toContain('Completed')
  })

  it('shows a failed call as an error', () => {
    const wrapper = mount(ToolCallItem, {
      props: { item: toolItem({ result: result(true), state: 'output-error' }) },
    })
    expect(wrapper.text()).toContain('Error')
    expect(wrapper.text()).toContain('no column "Q3"')
  })

  it('shows a call still running without an output section', () => {
    const wrapper = mount(ToolCallItem, {
      props: { item: toolItem({ result: null, state: 'input-available' }) },
    })
    expect(wrapper.text()).toContain('Running')
    expect(wrapper.text()).not.toContain('Result')
  })
})
