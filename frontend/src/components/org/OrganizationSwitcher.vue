<script setup lang="ts">
/**
 * Drop-in organization switcher. Generated but NOT mounted by
 * `mix phoenix_vue.gen.auth` — wire it into your app chrome when you
 * have a sidebar / topbar to host it.
 *
 *   <OrganizationSwitcher />
 *
 * Only renders in multi mode (`MODE === 'multi'`).
 */
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import {
  Button,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  toast,
} from '@meldui/vue'
import { IconBuilding, IconCheck, IconChevronDown, IconPlus } from '@meldui/tabler-vue'
import { MODE } from '@/lib/auth-mode'
import { useAuthStore } from '@/stores/auth'
import { useErrorMessage } from '@/composables/useErrorMessage'

const router = useRouter()
const authStore = useAuthStore()
const errorMessage = useErrorMessage()

const currentOrgName = computed(() => authStore.organization?.name ?? 'Choose organization')

async function switchTo(organizationId: string) {
  if (organizationId === authStore.organization?.id) return
  const res = await authStore.switchOrganization(organizationId)
  if (res.ok) {
    toast.success('Switched organization')
    router.push('/')
  } else {
    toast.error(errorMessage(res.error.code))
  }
}

function createNew() {
  router.push({ name: 'onboarding-create-organization' })
}
</script>

<template>
  <DropdownMenu v-if="MODE === 'multi'">
    <DropdownMenuTrigger as-child>
      <Button variant="ghost" class="gap-2">
        <IconBuilding class="size-4" />
        <span class="truncate max-w-[10rem]">{{ currentOrgName }}</span>
        <IconChevronDown class="size-3 text-muted-foreground" />
      </Button>
    </DropdownMenuTrigger>
    <DropdownMenuContent class="min-w-[14rem]">
      <DropdownMenuLabel>Organizations</DropdownMenuLabel>
      <DropdownMenuItem
        v-for="m in authStore.memberships"
        :key="m.id"
        @select="switchTo(m.organization_id)"
      >
        <span class="flex-1 truncate">{{ m.organization?.name }}</span>
        <IconCheck v-if="m.organization?.id === authStore.organization?.id" class="size-4" />
      </DropdownMenuItem>
      <DropdownMenuSeparator />
      <DropdownMenuItem @select="createNew">
        <IconPlus class="size-4 mr-2" />
        Create new organization
      </DropdownMenuItem>
    </DropdownMenuContent>
  </DropdownMenu>
</template>
