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
import { IconEye, IconEyeOff, IconLoader2, IconLogin } from '@meldui/tabler-vue'
import { useAuthStore } from '@/stores/auth'
import { useErrorMessage } from '@/composables/useErrorMessage'

const router = useRouter()
const route = useRoute()
const authStore = useAuthStore()
const errorMessage = useErrorMessage()

const email = ref('')
const password = ref('')
const showPassword = ref(false)
const submitting = ref(false)

const errors = reactive<{ email?: string; password?: string; form?: string }>({})

async function handleSubmit() {
  errors.email = undefined
  errors.password = undefined
  errors.form = undefined
  submitting.value = true

  const res = await authStore.signInWithPassword(email.value.trim(), password.value)
  submitting.value = false

  if (res.ok) {
    const redirect = typeof route.query.redirect === 'string' ? route.query.redirect : '/'
    router.push(redirect)
    return
  }

  if (res.error.fieldErrors) {
    errors.email = res.error.fieldErrors.email?.[0]
    errors.password = res.error.fieldErrors.password?.[0]
  }

  if (!errors.email && !errors.password) {
    errors.form = errorMessage(res.error.code)
  }
}
</script>

<template>
  <Card>
    <CardHeader class="space-y-1">
      <CardTitle class="text-2xl font-display">Sign in</CardTitle>
      <CardDescription>Welcome back. Enter your credentials to continue.</CardDescription>
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
          <p v-if="errors.email" class="text-xs text-destructive">{{ errors.email }}</p>
        </div>

        <div class="space-y-1.5">
          <div class="flex items-center justify-between">
            <Label for="password">Password</Label>
            <RouterLink
              :to="{ name: 'forgot-password' }"
              class="text-xs text-muted-foreground hover:text-foreground"
            >
              Forgot password?
            </RouterLink>
          </div>
          <div class="relative">
            <Input
              id="password"
              v-model="password"
              :type="showPassword ? 'text' : 'password'"
              autocomplete="current-password"
              required
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
          <p v-if="errors.password" class="text-xs text-destructive">{{ errors.password }}</p>
        </div>
      </CardContent>

      <CardFooter class="flex flex-col gap-3 pt-4">
        <Button type="submit" class="w-full" :disabled="submitting">
          <IconLoader2 v-if="submitting" class="size-4 animate-spin" />
          <IconLogin v-else class="size-4" />
          {{ submitting ? 'Signing in…' : 'Sign in' }}
        </Button>
        <p class="text-xs text-muted-foreground text-center">
          Don't have an account?
          <RouterLink :to="{ name: 'register' }" class="text-foreground hover:underline">
            Create one
          </RouterLink>
        </p>
      </CardFooter>
    </form>
  </Card>
</template>
