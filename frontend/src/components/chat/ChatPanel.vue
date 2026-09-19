<script setup lang="ts">
import { computed } from 'vue'

import {
  Conversation,
  ConversationContent,
  ConversationScrollButton,
} from '@/components/ai-elements/conversation'
import { Loader } from '@/components/ai-elements/loader'
import { Message, MessageContent, MessageResponse } from '@/components/ai-elements/message'
import {
  PromptInput,
  PromptInputFooter,
  PromptInputTextarea,
  PromptInputTools,
  type PromptInputMessage,
} from '@/components/ai-elements/prompt-input'
import { Suggestion, Suggestions } from '@/components/ai-elements/suggestion'
import ParticipantAvatars from '@/components/app/ParticipantAvatars.vue'
import ChatMessage from '@/components/chat/ChatMessage.vue'
import ChatSubmitButton from '@/components/chat/ChatSubmitButton.vue'
import ToolCallItem from '@/components/chat/ToolCallItem.vue'
import { useAuthStore } from '@/stores/auth'
import type { ChatItem } from '@/lib/conversation/render'
import type { ConversationJoinStatus, ConversationSummary, UserRef } from '@/types/contract'

/** The chat half of the workspace (UI-7). */
const props = defineProps<{
  conversation: ConversationSummary | null
  items: ChatItem[]
  agentStatus: ConversationJoinStatus
  participants: UserRef[]
  isEmpty: boolean
}>()

const emit = defineEmits<{ (e: 'send', text: string): void; (e: 'cancel'): void }>()

const auth = useAuthStore()

const title = computed(() => props.conversation?.title ?? 'New chat')

/** Just the given name — "Hello Tara", not "Hello Tarasankar Kundu". */
const firstName = computed(() => auth.displayName.trim().split(/\s+/)[0] ?? '')

/**
 * The gap between sending and the first delta: the message has gone but the
 * agent has not started streaming, so there is nothing else on screen to say so.
 */
const thinking = computed(
  () => props.agentStatus === 'running' && !props.items.some((i) => i.kind === 'streaming'),
)

const suggestions = [
  'Build a 2026 budget sheet with quarterly columns',
  'List the sheets I already have',
  'Add a Gross margin row that I can fill in',
]

function handleSubmit(message: PromptInputMessage) {
  const text = message.text.trim()
  if (!text) return
  emit('send', text)
}
</script>

<template>
  <div class="flex h-full min-h-0 flex-col">
    <header class="flex h-14 shrink-0 items-center gap-3 border-b px-4">
      <h1 class="min-w-0 flex-1 truncate text-sm font-semibold">{{ title }}</h1>
      <ParticipantAvatars :users="participants" :max="3" />
    </header>

    <Conversation class="min-h-0 flex-1">
      <ConversationContent class="mx-auto w-full max-w-3xl">
        <div v-if="isEmpty" class="flex flex-col gap-6 py-10">
          <div>
            <h2 class="mb-1 font-display text-3xl font-semibold tracking-tight">
              Hello {{ firstName }}
            </h2>
            <p class="text-sm text-muted-foreground">
              Ask for a sheet, or describe the numbers you want to work through.
            </p>
          </div>
          <Suggestions>
            <Suggestion
              v-for="suggestion in suggestions"
              :key="suggestion"
              :suggestion="suggestion"
              @click="emit('send', suggestion)"
            />
          </Suggestions>
        </div>

        <template v-for="item in items" :key="item.key">
          <ToolCallItem v-if="item.kind === 'tool'" :item="item" />
          <Message v-else-if="item.kind === 'streaming'" from="assistant">
            <MessageContent>
              <MessageResponse :content="item.text" />
            </MessageContent>
          </Message>
          <ChatMessage v-else :item="item" />
        </template>

        <Loader v-if="thinking" class="text-muted-foreground" />
      </ConversationContent>

      <ConversationScrollButton />
    </Conversation>

    <div class="shrink-0 border-t p-3">
      <!--
        The textarea and the footer must be DIRECT children of PromptInput:
        InputGroup switches to its stacked layout with `has-[>[data-align=block-end]]`,
        and those selectors match on the DOM tree.
      -->
      <PromptInput class="mx-auto w-full max-w-3xl rounded-2xl" @submit="handleSubmit">
        <PromptInputTextarea
          autofocus
          placeholder="Ask for a change, or a new sheet…"
          class="min-h-16 px-4 pt-3"
        />
        <PromptInputFooter class="pt-0">
          <PromptInputTools />
          <ChatSubmitButton :agent-status="agentStatus" @cancel="emit('cancel')" />
        </PromptInputFooter>
      </PromptInput>
    </div>
  </div>
</template>
