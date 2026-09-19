<script setup lang="ts">
import { onMounted, ref } from 'vue'
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
import { IconCheck, IconLoader2, IconX } from '@meldui/tabler-vue'
import { api } from '@/lib/api'
import { useErrorMessage } from '@/composables/useErrorMessage'

const route = useRoute()
const errorMessage = useErrorMessage()

const status = ref<'pending' | 'success' | 'error'>('pending')
const errorText = ref('')

onMounted(async () => {
  const token = String(route.params.token ?? '')
  if (!token) {
    status.value = 'error'
    errorText.value = errorMessage('invalid_token')
    return
  }

  const res = await api.post<void>('/api/me/email-verification/confirm', { token })
  if (res.ok) {
    status.value = 'success'
  } else {
    status.value = 'error'
    errorText.value = errorMessage(res.error.code)
  }
})
</script>

<template>
  <Card>
    <CardHeader class="text-center space-y-2">
      <div
        class="mx-auto inline-flex items-center justify-center size-12 rounded-full"
        :class="{
          'bg-muted': status === 'pending',
          'bg-green-100 text-green-700': status === 'success',
          'bg-destructive/15 text-destructive': status === 'error',
        }"
      >
        <IconLoader2 v-if="status === 'pending'" class="size-6 animate-spin" />
        <IconCheck v-else-if="status === 'success'" class="size-6" />
        <IconX v-else class="size-6" />
      </div>
      <CardTitle class="text-2xl font-display">
        <template v-if="status === 'pending'">Verifying…</template>
        <template v-else-if="status === 'success'">Email verified</template>
        <template v-else>Verification failed</template>
      </CardTitle>
      <CardDescription v-if="status === 'success'">
        Your email address has been confirmed. You can now sign in.
      </CardDescription>
      <CardDescription v-else-if="status === 'error'">
        {{ errorText }}
      </CardDescription>
    </CardHeader>

    <CardContent v-if="status === 'success'" class="flex justify-center">
      <Button as="div" class="w-full" variant="default">
        <RouterLink :to="{ name: 'login' }" class="w-full text-center">Continue to sign in</RouterLink>
      </Button>
    </CardContent>

    <CardFooter v-if="status === 'error'" class="flex flex-col gap-2">
      <Button as="div" class="w-full" variant="outline">
        <RouterLink :to="{ name: 'login' }" class="w-full text-center">Back to sign in</RouterLink>
      </Button>
    </CardFooter>
  </Card>
</template>
