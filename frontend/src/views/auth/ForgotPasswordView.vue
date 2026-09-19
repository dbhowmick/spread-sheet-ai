<script setup lang="ts">
import { ref } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { Loader2Icon, MailIcon } from '@lucide/vue'
import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { api } from '@/lib/api'

const router = useRouter()
const email = ref('')
const submitting = ref(false)

async function handleSubmit() {
  submitting.value = true
  await api.post<void>('/api/me/password-reset', { email: email.value.trim() })
  submitting.value = false
  router.push({ name: 'forgot-password-sent' })
}
</script>

<template>
  <Card>
    <CardHeader class="space-y-1">
      <CardTitle class="text-2xl font-display">Reset your password</CardTitle>
      <CardDescription>
        Enter the email associated with your account and we'll send a reset link.
      </CardDescription>
    </CardHeader>

    <form @submit.prevent="handleSubmit">
      <CardContent class="space-y-4">
        <div class="space-y-1.5">
          <Label for="email">Email</Label>
          <Input
            id="email"
            v-model="email"
            type="email"
            autocomplete="email"
            autofocus
            required
            :disabled="submitting"
          />
        </div>
      </CardContent>

      <CardFooter class="flex flex-col gap-3 pt-4">
        <Button type="submit" class="w-full" :disabled="submitting">
          <Loader2Icon v-if="submitting" class="size-4 animate-spin" />
          <MailIcon v-else class="size-4" />
          {{ submitting ? 'Sending…' : 'Send reset link' }}
        </Button>
        <p class="text-xs text-muted-foreground text-center">
          <RouterLink :to="{ name: 'login' }" class="text-foreground hover:underline">
            Back to sign in
          </RouterLink>
        </p>
      </CardFooter>
    </form>
  </Card>
</template>
