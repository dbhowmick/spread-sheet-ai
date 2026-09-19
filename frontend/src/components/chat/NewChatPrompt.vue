<script setup lang="ts">
import { computed } from 'vue'

import {
  PromptInput,
  PromptInputFooter,
  PromptInputTextarea,
  PromptInputTools,
  type PromptInputMessage,
} from '@/components/ai-elements/prompt-input'
import ChatSubmitButton from '@/components/chat/ChatSubmitButton.vue'
import { useAuthStore } from '@/stores/auth'

const emit = defineEmits<{ (e: 'submit', text: string): void }>()

const auth = useAuthStore()

/** Just the given name — "Hello Tara", not "Hello Tarasankar Kundu". */
const firstName = computed(() => auth.displayName.trim().split(/\s+/)[0] ?? '')

function handleSubmit(message: PromptInputMessage) {
  const text = message.text.trim()
  if (!text) return
  emit('submit', text)
}
</script>

<template>
  <div class="flex h-full flex-col items-center justify-center px-6 pb-24">
    <div class="w-full max-w-2xl">
      <h1 class="mb-1 font-display text-4xl font-semibold tracking-tight">Hello {{ firstName }}</h1>
      <p class="mb-6 text-sm text-muted-foreground">
        Ask for a sheet, or describe the numbers you want to work through.
      </p>

      <!--
        The textarea and the footer must be DIRECT children of PromptInput:
        InputGroup switches to its stacked layout with `has-[>[data-align=block-end]]`,
        and those selectors match on the DOM tree. PromptInputBody is
        `display: contents`, so wrapping in it hides them and the group stays
        collapsed at h-9.
      -->
      <PromptInput
        class="rounded-2xl shadow-sm transition-shadow hover:shadow-md"
        @submit="handleSubmit"
      >
        <PromptInputTextarea
          autofocus
          placeholder="How can I help?"
          class="min-h-28 px-4 pt-4 text-base placeholder:text-muted-foreground/70"
        />
        <PromptInputFooter class="pt-0">
          <PromptInputTools />
          <ChatSubmitButton />
        </PromptInputFooter>
      </PromptInput>
    </div>
  </div>
</template>
