<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { MessageSquareIcon } from '@lucide/vue'

import ChatPanel from '@/components/chat/ChatPanel.vue'
import SheetTabs from '@/components/workspace/SheetTabs.vue'
import { Button } from '@/components/ui/button'
import {
  Empty,
  EmptyContent,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from '@/components/ui/empty'
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from '@/components/ui/resizable'
import { Skeleton } from '@/components/ui/skeleton'
import { useConversation } from '@/composables/useConversation'
import { useErrorMessage } from '@/composables/useErrorMessage'
import { useOpenSheetTabs } from '@/composables/useOpenSheetTabs'
import type { SheetId } from '@/types/contract'

/** Chat on the left, tabbed sheets on the right (UI-3). */
const props = defineProps<{ conversationId: string }>()

const route = useRoute()
const router = useRouter()
const errorMessage = useErrorMessage()

const {
  conversation,
  items,
  isEmpty,
  agentStatus,
  participants,
  linkedSheets,
  focusRequest,
  status,
  error,
  send,
  cancel,
  openSheet,
} = useConversation(() => props.conversationId)

const { openIds, open, close } = useOpenSheetTabs(() => props.conversationId)

/** The active tab lives in the URL, so a reload or a shared link keeps it. */
const activeId = computed<SheetId | null>(() => {
  const value = route.query.sheet
  const sheetId = Array.isArray(value) ? value[0] : value
  return typeof sheetId === 'string' && openIds.value.includes(sheetId) ? sheetId : null
})

/**
 * `replace`, not `push`: switching tabs should not fill the history stack, so
 * Back walks between conversations rather than between tabs.
 */
function activate(sheetId: SheetId | null) {
  const query = { ...route.query }
  if (sheetId) query.sheet = sheetId
  else delete query.sheet
  void router.replace({ query })
}

function openTab(sheetId: SheetId) {
  open(sheetId)
  activate(sheetId)
}

function closeTab(sheetId: SheetId) {
  const at = openIds.value.indexOf(sheetId)
  close(sheetId)
  if (sheetId !== activeId.value) return
  // Fall back to the left neighbour, or clear the query when none is left.
  activate(openIds.value[Math.max(0, at - 1)] ?? null)
}

/** Opening a sheet by hand links it (ST-2); the server moves nobody's tab. */
async function pickSheet(sheetId: SheetId) {
  openTab(sheetId)
  await openSheet(sheetId)
}

// The AI touched a sheet: open its tab if needed and make it active (UI-4).
// `seq` is what makes two requests for the same sheet fire this twice.
watch(
  () => focusRequest.value?.seq,
  () => {
    const sheetId = focusRequest.value?.sheetId
    if (sheetId) openTab(sheetId)
  },
)

/**
 * Opening a conversation that already has sheets should show one, not an empty
 * panel: `focus_sheet` is live-only, so reopening a session whose sheets the AI
 * built in an earlier visit would otherwise look like it had none. The server
 * orders the links most-recent-first, so the first is the one last worked on.
 *
 * Only when nothing is stored — once the user has tabs of their own, or has
 * closed them all, that is their choice and is left alone.
 */
const bootstrapped = ref(false)
watch(
  linkedSheets,
  (sheets) => {
    if (bootstrapped.value) return
    if (openIds.value.length > 0) {
      bootstrapped.value = true
      return
    }
    const first = sheets[0]?.sheet.id
    if (!first) return
    bootstrapped.value = true
    openTab(first)
  },
  { immediate: true },
)

// A tab whose sheet was open before a reload still needs one in the URL.
watch(
  [openIds, activeId],
  ([ids, active]) => {
    if (!active && ids.length > 0) activate(ids[0] ?? null)
  },
  { immediate: true },
)

const errorText = computed(() =>
  error.value?.code === 'not_found'
    ? "It doesn't exist, or it was deleted."
    : (error.value?.message ?? errorMessage(error.value?.code)),
)
</script>

<template>
  <Empty v-if="status === 'error'" class="h-full">
    <EmptyHeader>
      <EmptyMedia variant="icon"><MessageSquareIcon /></EmptyMedia>
      <EmptyTitle>
        {{ error?.code === 'not_found' ? 'Chat not found' : "Couldn't open this chat" }}
      </EmptyTitle>
      <EmptyDescription>{{ errorText }}</EmptyDescription>
    </EmptyHeader>
    <EmptyContent>
      <Button variant="outline" as-child>
        <RouterLink :to="{ name: 'conversations' }">Back to chats</RouterLink>
      </Button>
    </EmptyContent>
  </Empty>

  <div
    v-else-if="status === 'joining'"
    class="flex h-full flex-col gap-4 p-4"
    aria-busy="true"
    aria-label="Loading chat"
  >
    <Skeleton class="h-8 w-56" />
    <Skeleton class="h-20 w-full max-w-lg" />
    <Skeleton class="ms-auto h-14 w-full max-w-sm" />
    <Skeleton class="h-28 w-full max-w-lg" />
  </div>

  <ResizablePanelGroup v-else direction="horizontal" class="h-full">
    <ResizablePanel :default-size="38" :min-size="24">
      <ChatPanel
        :conversation="conversation"
        :items="items"
        :agent-status="agentStatus"
        :participants="participants"
        :is-empty="isEmpty"
        @send="send"
        @cancel="cancel"
      />
    </ResizablePanel>

    <ResizableHandle with-handle />

    <ResizablePanel :default-size="62" :min-size="24">
      <SheetTabs
        :open-ids="openIds"
        :active-id="activeId"
        :linked-sheets="linkedSheets"
        @activate="activate"
        @close="closeTab"
        @pick="pickSheet"
      />
    </ResizablePanel>
  </ResizablePanelGroup>
</template>
