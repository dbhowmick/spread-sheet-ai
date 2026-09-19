import { defineStore } from 'pinia'
import { computed, ref } from 'vue'

import { api, type NormalizedError } from '@/lib/api'
import { MODE } from '@/lib/auth-mode'
import type { AuthMember, AuthOrganization, AuthUser, MePayload } from '@/types/auth'

interface MeResponse {
  me: MePayload
}

interface OrganizationResponse {
  organization: AuthOrganization
  member: AuthMember
}

type Result<T = void> =
  | { ok: true; data?: T }
  | { ok: false; status: number; error: NormalizedError }

/**
 * Single source of truth for the signed-in identity, current
 * organization, and full membership list. Hydrated from `/api/me` on
 * app boot (see `main.ts`).
 */
export const useAuthStore = defineStore('auth', () => {
  const currentUser = ref<AuthUser | null>(null)
  const currentMember = ref<AuthMember | null>(null)
  const organization = ref<AuthOrganization | null>(null)
  const memberships = ref<AuthMember[]>([])
  const hydrated = ref(false)

  const isAuthenticated = computed(() => currentUser.value !== null)

  // In `--mode multi`, a freshly-registered user has no memberships; the
  // router guard sends them to onboarding.
  // In `--mode single`, the backend auto-creates the first org at signup,
  // so this should never be true under normal flow.
  const needsOnboarding = computed(
    () => currentUser.value !== null && memberships.value.length === 0,
  )

  const displayName = computed(() => {
    if (!currentUser.value) return ''
    return currentUser.value.display_name || currentUser.value.primary_email.split('@')[0] || ''
  })

  function applyMe(payload: MePayload): void {
    currentUser.value = payload.user
    currentMember.value = payload.current_member
    organization.value = payload.organization
    memberships.value = payload.memberships
  }

  function clearState(): void {
    currentUser.value = null
    currentMember.value = null
    organization.value = null
    memberships.value = []
  }

  async function loadMe(): Promise<void> {
    const res = await api.get<MeResponse>('/api/me')
    if (res.ok) {
      applyMe(res.data.me)
      return
    }
    if (res.status === 401) {
      clearState()
      return
    }
    console.warn('[auth] /api/me failed', res.status, res.error?.code)
  }

  async function hydrate(): Promise<void> {
    try {
      await loadMe()
    } finally {
      hydrated.value = true
    }
  }

  async function signInWithPassword(email: string, password: string): Promise<Result> {
    const res = await api.post<MeResponse>('/api/sessions', { email, password })
    if (res.ok) {
      applyMe(res.data.me)
      return { ok: true }
    }
    return { ok: false, status: res.status, error: res.error }
  }

  async function signUp(
    email: string,
    password: string,
    displayName?: string,
  ): Promise<Result> {
    const res = await api.post<void>('/api/auth/register', {
      email,
      password,
      display_name: displayName,
    })
    if (res.ok) return { ok: true }
    return { ok: false, status: res.status, error: res.error }
  }

  async function signOut(): Promise<void> {
    await api.delete<void>('/api/sessions/current')
    clearState()
  }

  async function signOutEverywhere(): Promise<void> {
    await api.post<void>('/api/sessions/revoke-all')
    clearState()
  }

  async function createOrganization(name: string): Promise<Result<OrganizationResponse>> {
    const res = await api.post<OrganizationResponse>('/api/organizations', { name })
    if (res.ok) {
      // Refresh the full me payload so memberships/current_member update.
      await loadMe()
      return { ok: true, data: res.data }
    }
    return { ok: false, status: res.status, error: res.error }
  }

  async function switchOrganization(organizationId: string): Promise<Result> {
    const res = await api.post<MeResponse>('/api/me/switch-organization', {
      organization_id: organizationId,
    })
    if (res.ok) {
      applyMe(res.data.me)
      return { ok: true }
    }
    return { ok: false, status: res.status, error: res.error }
  }

  async function refresh(): Promise<void> {
    await loadMe()
  }

  return {
    // state
    currentUser,
    currentMember,
    organization,
    memberships,
    hydrated,
    // computed
    isAuthenticated,
    needsOnboarding,
    displayName,
    // actions
    loadMe,
    hydrate,
    signInWithPassword,
    signUp,
    signOut,
    signOutEverywhere,
    createOrganization,
    switchOrganization,
    refresh,
    clearState,
    // re-export for convenience
    MODE,
  }
})
