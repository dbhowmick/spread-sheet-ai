<script setup lang="ts">
import { computed } from 'vue'

import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip'
import { initials } from '@/lib/people'
import type { UserRef } from '@/types/contract'

/**
 * Who else is looking at this sheet or conversation (RT-7). Shared by the
 * sheet toolbar and, from F5, the chat header.
 */
const props = withDefaults(defineProps<{ users: UserRef[]; max?: number }>(), { max: 4 })

const shown = computed(() => props.users.slice(0, props.max))
const hidden = computed(() => props.users.slice(props.max))
</script>

<template>
  <TooltipProvider :delay-duration="200">
    <div
      v-if="users.length > 0"
      class="flex items-center -space-x-1.5"
      :aria-label="`${users.length} viewing`"
      role="group"
    >
      <Tooltip v-for="user in shown" :key="user.id">
        <TooltipTrigger as-child>
          <Avatar class="size-7 border-2 border-background">
            <AvatarFallback class="bg-muted text-[10px] font-medium">
              {{ initials(user.display_name) }}
            </AvatarFallback>
          </Avatar>
        </TooltipTrigger>
        <TooltipContent>{{ user.display_name }}</TooltipContent>
      </Tooltip>

      <Tooltip v-if="hidden.length > 0">
        <TooltipTrigger as-child>
          <Avatar class="size-7 border-2 border-background">
            <AvatarFallback class="bg-muted text-[10px] font-medium">
              +{{ hidden.length }}
            </AvatarFallback>
          </Avatar>
        </TooltipTrigger>
        <TooltipContent>{{ hidden.map((u) => u.display_name).join(', ') }}</TooltipContent>
      </Tooltip>
    </div>
  </TooltipProvider>
</template>
