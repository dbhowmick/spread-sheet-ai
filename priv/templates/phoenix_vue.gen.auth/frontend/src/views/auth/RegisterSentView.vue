<script setup lang="ts">
import { ref } from 'vue'
import { RouterLink, useRoute } from 'vue-router'
import {
  Button,
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from '@meldui/vue'
import { IconLoader2, IconMail } from '@meldui/tabler-vue'
import { api } from '@/lib/api'

const route = useRoute()
const email = typeof route.query.email === 'string' ? route.query.email : ''

const resending = ref(false)
const resent = ref(false)

async function handleResend() {
  if (!email) return
  resending.value = true
  await api.post<void>('/api/me/email-verification/resend', { email })
  resending.value = false
  resent.value = true
}
</script>

<template>
  <Card>
    <CardHeader class="text-center space-y-2">
      <div class="mx-auto inline-flex items-center justify-center size-12 rounded-full bg-muted">
        <IconMail class="size-6 text-muted-foreground" />
      </div>
      <CardTitle class="text-2xl font-display">Check your inbox</CardTitle>
      <CardDescription>
        We sent a verification link
        <template v-if="email">
          to <span class="font-medium text-foreground">{{ email }}</span>
        </template>
        <template v-else>to your email</template>.
      </CardDescription>
    </CardHeader>

    <CardContent class="space-y-3 text-sm text-muted-foreground text-center">
      <p>Click the link in the email to verify your address, then sign in.</p>
      <p class="text-xs">Don't see it? Check your spam folder.</p>
    </CardContent>

    <CardFooter class="flex flex-col gap-2">
      <Button
        v-if="!resent"
        variant="outline"
        class="w-full"
        :disabled="resending || !email"
        @click="handleResend"
      >
        <IconLoader2 v-if="resending" class="size-4 animate-spin" />
        {{ resending ? 'Sending…' : 'Resend verification email' }}
      </Button>
      <p v-else class="text-xs text-muted-foreground text-center">
        If that email is on file, we've sent it again.
      </p>
      <p class="text-xs text-muted-foreground text-center">
        <RouterLink :to="{ name: 'login' }" class="text-foreground hover:underline">
          Back to sign in
        </RouterLink>
      </p>
    </CardFooter>
  </Card>
</template>
