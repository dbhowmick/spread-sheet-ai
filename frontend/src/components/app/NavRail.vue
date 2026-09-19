<script setup lang="ts">
import { computed } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { MessageSquareIcon, TableIcon } from '@lucide/vue'

import { Avatar, AvatarFallback, AvatarImage } from '@/components/ui/avatar'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip'
import { cn } from '@/lib/utils'
import { useAuthStore } from '@/stores/auth'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const nav = [
  { name: 'conversations', label: 'Chat', icon: MessageSquareIcon },
  { name: 'sheets', label: 'Sheets', icon: TableIcon },
] as const

/** `/c/:id` keeps Chat lit; `/sheets/:id` keeps Sheets lit. */
const activeSection = computed(() => {
  if (route.name === 'workspace') return 'conversations'
  if (route.name === 'sheet') return 'sheets'
  return route.name
})

const initials = computed(() => {
  const name = auth.displayName.trim()
  if (!name) return '?'
  const parts = name.split(/\s+/)
  const first = parts[0]?.[0] ?? ''
  const last = parts.length > 1 ? (parts[parts.length - 1]?.[0] ?? '') : ''
  return (first + last).toUpperCase() || '?'
})

async function handleSignOut() {
  await auth.signOut()
  router.push({ name: 'login' })
}
</script>

<template>
  <TooltipProvider :delay-duration="200">
    <nav
      aria-label="Primary"
      class="flex w-16 shrink-0 flex-col items-center border-r bg-sidebar py-4"
    >
      <div class="flex flex-1 flex-col items-center gap-2">
        <Tooltip v-for="item in nav" :key="item.name">
          <TooltipTrigger as-child>
            <RouterLink
              :to="{ name: item.name }"
              :aria-label="item.label"
              :aria-current="activeSection === item.name ? 'page' : undefined"
              :class="
                cn(
                  'flex size-10 items-center justify-center rounded-full border transition-colors',
                  'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring',
                  activeSection === item.name
                    ? 'border-transparent bg-primary text-primary-foreground'
                    : 'border-border text-muted-foreground hover:bg-accent hover:text-accent-foreground',
                )
              "
            >
              <component :is="item.icon" class="size-[18px]" />
            </RouterLink>
          </TooltipTrigger>
          <TooltipContent side="right">{{ item.label }}</TooltipContent>
        </Tooltip>
      </div>

      <div class="flex flex-col items-center">
        <DropdownMenu>
          <DropdownMenuTrigger as-child>
            <button
              type="button"
              aria-label="Account"
              class="rounded-full focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            >
              <Avatar class="size-10 border">
                <AvatarImage
                  v-if="auth.currentUser?.avatar_url"
                  :src="auth.currentUser.avatar_url"
                />
                <AvatarFallback class="bg-transparent text-xs font-medium">
                  {{ initials }}
                </AvatarFallback>
              </Avatar>
            </button>
          </DropdownMenuTrigger>
          <DropdownMenuContent side="right" align="end" class="w-56">
            <DropdownMenuLabel class="font-normal">
              <div class="truncate text-sm font-medium">{{ auth.displayName }}</div>
              <div class="truncate text-xs text-muted-foreground">
                {{ auth.currentUser?.primary_email }}
              </div>
            </DropdownMenuLabel>
            <DropdownMenuSeparator />
            <DropdownMenuItem @select="handleSignOut">Sign out</DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </nav>
  </TooltipProvider>
</template>
