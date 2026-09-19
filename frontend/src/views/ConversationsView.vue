<script setup lang="ts">
import { toast } from 'vue-sonner'

import NewChatPrompt from '@/components/chat/NewChatPrompt.vue'

/**
 * With no conversations yet, this is the "new chat" landing.
 *
 * F5 wires the conversation list and `POST /api/conversations`; until then
 * there is nothing to list, so the new-chat state is always what renders.
 */
function handleSubmit(text: string) {
  toast.info('Chat lands in F5.', { description: text })
}
</script>

<template>
  <NewChatPrompt @submit="handleSubmit" />
</template>
