<script setup lang="ts">
import { computed } from 'vue'

import { Tool, ToolContent, ToolHeader, ToolInput, ToolOutput } from '@/components/ai-elements/tool'
import { formatToolOutput, type ChatToolItem } from '@/lib/conversation/render'

/**
 * A `tool_call` and the `tool_result` that answers it, drawn as one collapsible
 * block (frontend-plan §8.2, AI-7).
 */
const props = defineProps<{ item: ChatToolItem }>()

const isError = computed(() => props.item.state === 'output-error')

const output = computed(() => {
  const result = props.item.result
  if (!result || isError.value) return undefined
  return formatToolOutput(result.content.content)
})

/**
 * `ToolOutput` renders nothing unless one of its two props is truthy, so a call
 * still running passes both as undefined and the block shows only its header
 * and parameters.
 */
const errorText = computed(() => {
  if (!isError.value) return undefined
  return props.item.result?.content.content ?? 'The tool call failed.'
})
</script>

<template>
  <!-- A failed call opens itself: the reason is the whole point of showing it. -->
  <Tool :default-open="isError">
    <ToolHeader
      type="dynamic-tool"
      :tool-name="item.call.content.name"
      :title="item.title"
      :state="item.state"
    />
    <ToolContent>
      <ToolInput :input="item.call.content.arguments" />
      <ToolOutput :output="output" :error-text="errorText" />
    </ToolContent>
  </Tool>
</template>
