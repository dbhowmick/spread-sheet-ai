<script setup lang="ts">
import { reactive, ref } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import {
  Button,
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
  Input,
  Label,
} from '@meldui/vue'
import { IconLoader2, IconLock } from '@meldui/tabler-vue'
import { api } from '@/lib/api'
import { useErrorMessage } from '@/composables/useErrorMessage'

const route = useRoute()
const router = useRouter()
const errorMessage = useErrorMessage()

const token = String(route.params.token ?? '')
const password = ref('')
const confirm = ref('')
const submitting = ref(false)
const errors = reactive<{ password?: string; confirm?: string; form?: string }>({})

async function handleSubmit() {
  errors.password = undefined
  errors.confirm = undefined
  errors.form = undefined

  if (password.value !== confirm.value) {
    errors.confirm = "Passwords don't match."
    return
  }

  submitting.value = true
  const res = await api.post<void>('/api/me/password-reset/confirm', {
    token,
    password: password.value,
  })
  submitting.value = false

  if (res.ok) {
    router.push({ name: 'login', query: { reset: '1' } })
    return
  }

  if (res.error.fieldErrors?.password) {
    errors.password = res.error.fieldErrors.password[0]
    return
  }

  errors.form = errorMessage(res.error.code)
}
</script>

<template>
  <Card>
    <CardHeader class="space-y-1">
      <CardTitle class="text-2xl font-display">Set a new password</CardTitle>
      <CardDescription>Pick a strong password you don't use anywhere else.</CardDescription>
    </CardHeader>

    <form @submit.prevent="handleSubmit">
      <CardContent class="space-y-4">
        <div
          v-if="errors.form"
          role="alert"
          class="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
        >
          {{ errors.form }}
        </div>

        <div class="space-y-1.5">
          <Label for="password">New password</Label>
          <Input
            id="password"
            v-model="password"
            type="password"
            autocomplete="new-password"
            autofocus
            required
            minlength="8"
            :disabled="submitting"
          />
          <p v-if="errors.password" class="text-xs text-destructive">{{ errors.password }}</p>
          <p v-else class="text-xs text-muted-foreground">At least 8 characters.</p>
        </div>

        <div class="space-y-1.5">
          <Label for="confirm">Confirm password</Label>
          <Input
            id="confirm"
            v-model="confirm"
            type="password"
            autocomplete="new-password"
            required
            :disabled="submitting"
          />
          <p v-if="errors.confirm" class="text-xs text-destructive">{{ errors.confirm }}</p>
        </div>
      </CardContent>

      <CardFooter class="flex flex-col gap-3 pt-4">
        <Button type="submit" class="w-full" :disabled="submitting">
          <IconLoader2 v-if="submitting" class="size-4 animate-spin" />
          <IconLock v-else class="size-4" />
          {{ submitting ? 'Updating…' : 'Update password' }}
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
