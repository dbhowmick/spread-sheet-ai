<script setup lang="ts">
import { computed } from 'vue'
import { AlertTriangleIcon } from '@lucide/vue'

import { Message, MessageContent, MessageResponse } from '@/components/ai-elements/message'
import { Reasoning, ReasoningContent, ReasoningTrigger } from '@/components/ai-elements/reasoning'
import { Badge } from '@/components/ui/badge'
import type { ChatMessageItem } from '@/lib/conversation/render'

/**
 * One transcript message (frontend-plan §8.2). Tool calls do not come through
 * here — `chatItems` folds those into `ToolCallItem`.
 */
const props = defineProps<{ item: ChatMessageItem }>()

const message = computed(() => props.item.message)

/** Other people's messages are named above the bubble (CS-3). */
const senderName = computed(() =>
  props.item.isSelf ? null : (message.value.sender?.display_name ?? null),
)

const from = computed(() => (message.value.role === 'user' ? 'user' : 'assistant'))

/**
 * §2.10 puts `stop_reason` on the last item of a message that did not finish.
 * `notification` carries `cancelled` by definition and says so in its own text,
 * so it needs no second marker.
 */
const stopReason = computed(() =>
  message.value.content_type === 'notification'
    ? null
    : (message.value.content.stop_reason ?? null),
)

const STOP_TEXT: Record<string, string> = {
  length: 'Cut off — the reply hit the length limit.',
  cancelled: 'Stopped.',
  content_filtered: 'Cut off by a content filter.',
  stream_error: 'Cut off — the stream failed.',
}
</script>

<template>
  <!-- Notification and error are system lines, not bubbles. -->
  <p
    v-if="message.content_type === 'notification'"
    class="text-center text-xs text-muted-foreground"
  >
    {{ message.content.text }}
  </p>

  <p
    v-else-if="message.content_type === 'error'"
    class="flex items-start gap-2 text-xs text-destructive"
  >
    <AlertTriangleIcon class="mt-px size-3.5 shrink-0" />
    <span>{{ message.content.text }}</span>
  </p>

  <Reasoning v-else-if="message.content_type === 'thinking'" :default-open="false">
    <ReasoningTrigger />
    <ReasoningContent :content="message.content.text" />
  </Reasoning>

  <div v-else class="flex flex-col gap-1" :class="item.isSelf && 'items-end'">
    <span v-if="senderName" class="px-1 text-xs font-medium text-muted-foreground">
      {{ senderName }}
    </span>

    <Message :from="from">
      <MessageContent>
        <!--
          `content_type` is `text` here, or something the contract does not name:
          MessageJSON whitelists six types but passes anything else through raw,
          so read `text` defensively rather than dropping the message.
        -->
        <MessageResponse :content="String(message.content.text ?? '')" />
      </MessageContent>
    </Message>

    <div v-if="item.queued || stopReason" class="flex items-center gap-2 px-1">
      <!-- CS-4: the message is stored but the AI has not taken it up yet. -->
      <Badge v-if="item.queued" variant="secondary" class="text-[10px]">Queued</Badge>
      <span v-if="stopReason" class="text-xs text-muted-foreground">
        {{ STOP_TEXT[stopReason] ?? 'Cut off.' }}
      </span>
    </div>
  </div>
</template>
