<script setup lang="ts">
import { reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
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
import { IconBuilding, IconLoader2 } from '@meldui/tabler-vue'
import { useAuthStore } from '@/stores/auth'
import { useErrorMessage } from '@/composables/useErrorMessage'

const router = useRouter()
const authStore = useAuthStore()
const errorMessage = useErrorMessage()

const name = ref('')
const submitting = ref(false)
const errors = reactive<{ name?: string; form?: string }>({})

async function handleSubmit() {
  errors.name = undefined
  errors.form = undefined
  submitting.value = true

  const res = await authStore.createOrganization(name.value.trim())
  submitting.value = false

  if (res.ok) {
    router.push('/')
    return
  }

  if (res.error.fieldErrors?.name) {
    errors.name = res.error.fieldErrors.name[0]
    return
  }

  errors.form = errorMessage(res.error.code)
}
</script>

<template>
  <Card>
    <CardHeader class="space-y-1">
      <CardTitle class="text-2xl font-display">Create your organization</CardTitle>
      <CardDescription>
        Give your workspace a name. You can rename it later.
      </CardDescription>
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
          <Label for="name">Organization name</Label>
          <Input
            id="name"
            v-model="name"
            type="text"
            autofocus
            required
            placeholder="Acme Inc."
            :disabled="submitting"
          />
          <p v-if="errors.name" class="text-xs text-destructive">{{ errors.name }}</p>
          <p v-else class="text-xs text-muted-foreground">
            We'll generate a URL slug for you from this name.
          </p>
        </div>
      </CardContent>

      <CardFooter class="pt-4">
        <Button type="submit" class="w-full" :disabled="submitting || !name.trim()">
          <IconLoader2 v-if="submitting" class="size-4 animate-spin" />
          <IconBuilding v-else class="size-4" />
          {{ submitting ? 'Creating…' : 'Create organization' }}
        </Button>
      </CardFooter>
    </form>
  </Card>
</template>
