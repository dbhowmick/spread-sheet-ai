<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { useIntervalFn } from '@vueuse/core'
import { Loader2Icon, MessageSquareIcon, PlusIcon } from '@lucide/vue'
import { toast } from 'vue-sonner'

import { Button } from '@/components/ui/button'
import {
  Empty,
  EmptyContent,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from '@/components/ui/empty'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { useErrorMessage } from '@/composables/useErrorMessage'
import { api } from '@/lib/api'
import { timeAgo } from '@/lib/time'
import type {
  ConversationShowResponse,
  ConversationSummary,
  ConversationsIndexResponse,
} from '@/types/contract'

/** Every chat session, most recent activity first (UI-2). They are shared (CS-1). */
const router = useRouter()
const errorMessage = useErrorMessage()

const conversations = ref<ConversationSummary[]>([])
const loading = ref(true)
const loadError = ref<string | null>(null)
const creating = ref(false)

const now = ref(Date.now())
useIntervalFn(() => {
  now.value = Date.now()
}, 30_000)

async function load() {
  loading.value = true
  loadError.value = null
  const res = await api.get<ConversationsIndexResponse>('/api/conversations')
  loading.value = false
  if (res.ok) conversations.value = res.data.conversations
  else loadError.value = res.error.message ?? errorMessage(res.error.code)
}

/** The title is generated from the conversation, so a new one has none yet. */
function titleOf(conversation: ConversationSummary): string {
  return conversation.title ?? 'New chat'
}

async function startChat() {
  if (creating.value) return
  creating.value = true
  const res = await api.post<ConversationShowResponse>('/api/conversations', {})
  creating.value = false

  if (!res.ok) {
    toast.error(res.error.message ?? errorMessage(res.error.code))
    return
  }
  void router.push({ name: 'workspace', params: { conversationId: res.data.conversation.id } })
}

onMounted(load)
</script>

<template>
  <div class="flex h-full min-h-0 flex-col">
    <header class="flex h-14 shrink-0 items-center gap-3 border-b px-4">
      <h1 class="text-sm font-semibold">Chats</h1>
      <Button
        v-if="conversations.length > 0"
        size="sm"
        class="ms-auto"
        :disabled="creating"
        @click="startChat"
      >
        <Loader2Icon v-if="creating" class="animate-spin" />
        <PlusIcon v-else />
        New chat
      </Button>
    </header>

    <div class="min-h-0 flex-1 overflow-auto">
      <div v-if="loading" class="space-y-3 p-4" aria-busy="true" aria-label="Loading chats">
        <Skeleton v-for="i in 6" :key="i" class="h-9 w-full" />
      </div>

      <Empty v-else-if="loadError" class="h-full">
        <EmptyHeader>
          <EmptyTitle>Couldn't load chats</EmptyTitle>
          <EmptyDescription>{{ loadError }}</EmptyDescription>
        </EmptyHeader>
        <EmptyContent>
          <Button variant="outline" @click="load">Retry</Button>
        </EmptyContent>
      </Empty>

      <Empty v-else-if="conversations.length === 0" class="h-full">
        <EmptyHeader>
          <EmptyMedia variant="icon"><MessageSquareIcon /></EmptyMedia>
          <EmptyTitle>No chats yet</EmptyTitle>
          <EmptyDescription>
            Start one and ask the assistant to build you a sheet.
          </EmptyDescription>
        </EmptyHeader>
        <EmptyContent>
          <Button :disabled="creating" @click="startChat">
            <Loader2Icon v-if="creating" class="animate-spin" />
            <PlusIcon v-else />
            New chat
          </Button>
        </EmptyContent>
      </Empty>

      <Table v-else>
        <TableHeader>
          <TableRow>
            <TableHead class="ps-4">Title</TableHead>
            <TableHead>Started by</TableHead>
            <TableHead class="pe-4 text-end">Last activity</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          <TableRow
            v-for="conversation in conversations"
            :key="conversation.id"
            class="cursor-pointer"
            @click="
              router.push({
                name: 'workspace',
                params: { conversationId: conversation.id },
              })
            "
          >
            <TableCell class="ps-4 font-medium">
              <RouterLink
                :to="{ name: 'workspace', params: { conversationId: conversation.id } }"
                class="hover:underline focus-visible:underline focus-visible:outline-none"
                :class="!conversation.title && 'text-muted-foreground'"
                @click.stop
              >
                {{ titleOf(conversation) }}
              </RouterLink>
            </TableCell>
            <TableCell class="text-muted-foreground">
              {{ conversation.created_by.display_name }}
            </TableCell>
            <TableCell class="pe-4 text-end text-muted-foreground">
              <time
                :datetime="conversation.updated_at"
                :title="new Date(conversation.updated_at).toLocaleString()"
              >
                {{ timeAgo(Date.parse(conversation.updated_at), now) }}
              </time>
            </TableCell>
          </TableRow>
        </TableBody>
      </Table>
    </div>
  </div>
</template>
