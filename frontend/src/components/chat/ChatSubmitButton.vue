<script setup lang="ts">
import { computed } from 'vue'
import { ArrowUpIcon, SquareIcon } from '@lucide/vue'

import { PromptInputSubmit, usePromptInput } from '@/components/ai-elements/prompt-input'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import type { ConversationJoinStatus } from '@/types/contract'

/**
 * The send button, split out so it can read the prompt context: `usePromptInput`
 * injects, so it has to live *inside* `<PromptInput>`, not alongside it.
 *
 * While the AI is answering it becomes a stop button (CS-5). That is a separate
 * `type="button"` rather than a `status` on `PromptInputSubmit`, because Enter
 * in the textarea always submits the form: a stop-on-submit would mean Enter
 * cancels the turn instead of *queueing* the message, which is what CS-4 wants.
 */
const props = defineProps<{ agentStatus?: ConversationJoinStatus }>()
const emit = defineEmits<{ (e: 'cancel'): void }>()

const { textInput, files } = usePromptInput()

const running = computed(() => props.agentStatus === 'running')
const canSubmit = computed(() => textInput.value.trim().length > 0 || files.value.length > 0)
</script>

<template>
  <Button
    v-if="running"
    type="button"
    aria-label="Stop the assistant"
    class="size-9 rounded-full"
    @click="emit('cancel')"
  >
    <SquareIcon class="size-[14px] fill-current" />
  </Button>

  <PromptInputSubmit
    v-else
    :disabled="!canSubmit"
    :class="
      cn('size-9 rounded-full transition-opacity', !canSubmit && 'pointer-events-none opacity-40')
    "
  >
    <ArrowUpIcon class="size-[18px]" />
  </PromptInputSubmit>
</template>
