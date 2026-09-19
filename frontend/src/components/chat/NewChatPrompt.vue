<script setup lang="ts">
import { computed } from 'vue'

import {
  PromptInput,
  PromptInputSubmit,
  PromptInputTextarea,
  type PromptInputMessage,
} from '@/components/ai-elements/prompt-input'
import { InputGroupAddon } from '@/components/ui/input-group'
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
  <div class="flex h-full flex-col items-center justify-center px-6">
    <div class="w-full max-w-2xl">
      <h1 class="mb-5 font-display text-3xl font-semibold tracking-tight">Hello {{ firstName }}</h1>

      <!--
        The textarea and the addon must be DIRECT children of PromptInput:
        InputGroup switches layout with `has-[>…]` selectors, which match on
        the DOM tree. PromptInputBody is `display: contents`, so wrapping in it
        hides these from those selectors and the group stays collapsed at h-9.
      -->
      <PromptInput class="items-end rounded-2xl px-1 py-1" @submit="handleSubmit">
        <PromptInputTextarea
          autofocus
          placeholder="How can I help?"
          class="min-h-28 px-4 text-base"
        />
        <InputGroupAddon align="inline-end" class="self-center pr-2">
          <PromptInputSubmit class="size-9 rounded-full" />
        </InputGroupAddon>
      </PromptInput>
    </div>
  </div>
</template>
