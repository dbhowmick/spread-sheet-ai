<script setup lang="ts">
import { reactive, ref } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
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
import { IconEye, IconEyeOff, IconLoader2, IconUserPlus } from '@meldui/tabler-vue'
import { useAuthStore } from '@/stores/auth'
import { useErrorMessage } from '@/composables/useErrorMessage'

const router = useRouter()
const authStore = useAuthStore()
const errorMessage = useErrorMessage()

const displayName = ref('')
const email = ref('')
const password = ref('')
const showPassword = ref(false)
const submitting = ref(false)

const errors = reactive<{
  display_name?: string
  email?: string
  password?: string
  form?: string
}>({})

async function handleSubmit() {
  errors.display_name = undefined
  errors.email = undefined
  errors.password = undefined
  errors.form = undefined
  submitting.value = true

  const res = await authStore.signUp(email.value.trim(), password.value, displayName.value.trim() || undefined)
  submitting.value = false

  if (res.ok) {
    router.push({ name: 'register-sent', query: { email: email.value.trim() } })
    return
  }

  if (res.error.fieldErrors) {
    errors.display_name = res.error.fieldErrors.display_name?.[0]
    errors.email =
      res.error.fieldErrors.primary_email?.[0] ?? res.error.fieldErrors.email?.[0]
    errors.password = res.error.fieldErrors.password?.[0]
  }

  if (!errors.email && !errors.password && !errors.display_name) {
    errors.form = errorMessage(res.error.code)
  }
}
</script>

<template>
  <Card>
    <CardHeader class="space-y-1">
      <CardTitle class="text-2xl font-display">Create an account</CardTitle>
      <CardDescription>Get started in a couple of clicks.</CardDescription>
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
          <Label for="display_name">Name</Label>
          <Input
            id="display_name"
            v-model="displayName"
            type="text"
            autocomplete="name"
            autofocus
            :disabled="submitting"
          />
          <p v-if="errors.display_name" class="text-xs text-destructive">{{ errors.display_name }}</p>
        </div>

        <div class="space-y-1.5">
          <Label for="email">Email</Label>
          <Input
            id="email"
            v-model="email"
            type="email"
            autocomplete="email"
            required
            :disabled="submitting"
          />
          <p v-if="errors.email" class="text-xs text-destructive">{{ errors.email }}</p>
        </div>

        <div class="space-y-1.5">
          <Label for="password">Password</Label>
          <div class="relative">
            <Input
              id="password"
              v-model="password"
              :type="showPassword ? 'text' : 'password'"
              autocomplete="new-password"
              required
              minlength="8"
              :disabled="submitting"
              class="pr-10"
            />
            <button
              type="button"
              class="absolute right-2 top-1/2 -translate-y-1/2 p-1 text-muted-foreground hover:text-foreground"
              :aria-label="showPassword ? 'Hide password' : 'Show password'"
              @click="showPassword = !showPassword"
            >
              <IconEyeOff v-if="showPassword" class="size-4" />
              <IconEye v-else class="size-4" />
            </button>
          </div>
          <p
            v-if="errors.password"
            class="text-xs text-destructive"
          >
            {{ errors.password }}
          </p>
          <p v-else class="text-xs text-muted-foreground">At least 8 characters.</p>
        </div>
      </CardContent>

      <CardFooter class="flex flex-col gap-3 pt-4">
        <Button type="submit" class="w-full" :disabled="submitting">
          <IconLoader2 v-if="submitting" class="size-4 animate-spin" />
          <IconUserPlus v-else class="size-4" />
          {{ submitting ? 'Creating account…' : 'Create account' }}
        </Button>
        <p class="text-xs text-muted-foreground text-center">
          Already have an account?
          <RouterLink :to="{ name: 'login' }" class="text-foreground hover:underline">
            Sign in
          </RouterLink>
        </p>
      </CardFooter>
    </form>
  </Card>
</template>
