<script setup lang="ts">
import { computed } from 'vue'
import { ArrowUpIcon } from '@lucide/vue'

import { PromptInputSubmit, usePromptInput } from '@/components/ai-elements/prompt-input'
import { cn } from '@/lib/utils'

/**
 * The send button, split out so it can read the prompt context: `usePromptInput`
 * injects, so it has to live *inside* `<PromptInput>`, not alongside it.
 */
const { textInput, files } = usePromptInput()

const canSubmit = computed(() => textInput.value.trim().length > 0 || files.value.length > 0)
</script>

<template>
  <PromptInputSubmit
    :disabled="!canSubmit"
    :class="
      cn('size-9 rounded-full transition-opacity', !canSubmit && 'pointer-events-none opacity-40')
    "
  >
    <ArrowUpIcon class="size-[18px]" />
  </PromptInputSubmit>
</template>
