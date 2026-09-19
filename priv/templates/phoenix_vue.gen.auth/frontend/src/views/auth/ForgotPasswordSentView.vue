<script setup lang="ts">
import { RouterLink } from 'vue-router'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@meldui/vue'
import { IconMail } from '@meldui/tabler-vue'
</script>

<template>
  <Card>
    <CardHeader class="text-center space-y-2">
      <div class="mx-auto inline-flex items-center justify-center size-12 rounded-full bg-muted">
        <IconMail class="size-6 text-muted-foreground" />
      </div>
      <CardTitle class="text-2xl font-display">Check your inbox</CardTitle>
      <CardDescription>
        If that email is on file, we've sent a password-reset link. The link
        expires in one hour.
      </CardDescription>
    </CardHeader>

    <CardContent class="space-y-3 text-sm text-muted-foreground text-center">
      <p>Don't see it? Check your spam folder.</p>
      <p class="text-xs">
        <RouterLink :to="{ name: 'login' }" class="text-foreground hover:underline">
          Back to sign in
        </RouterLink>
      </p>
    </CardContent>
  </Card>
</template>
