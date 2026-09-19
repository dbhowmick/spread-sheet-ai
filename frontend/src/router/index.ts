import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'

import AppLayout from '@/layouts/AppLayout.vue'
import AuthLayout from '@/layouts/AuthLayout.vue'
import OnboardingLayout from '@/layouts/OnboardingLayout.vue'
import { useAuthStore } from '@/stores/auth'

const routes: RouteRecordRaw[] = [
  {
    path: '/auth',
    component: AuthLayout,
    meta: { guestOnly: true },
    children: [
      { path: 'login', name: 'login', component: () => import('@/views/auth/LoginView.vue') },
      {
        path: 'register',
        name: 'register',
        component: () => import('@/views/auth/RegisterView.vue'),
      },
      {
        path: 'register-sent',
        name: 'register-sent',
        component: () => import('@/views/auth/RegisterSentView.vue'),
      },
      {
        path: 'forgot-password',
        name: 'forgot-password',
        component: () => import('@/views/auth/ForgotPasswordView.vue'),
      },
      {
        path: 'forgot-password-sent',
        name: 'forgot-password-sent',
        component: () => import('@/views/auth/ForgotPasswordSentView.vue'),
      },
      {
        path: 'reset-password/:token',
        name: 'reset-password',
        component: () => import('@/views/auth/ResetPasswordView.vue'),
      },
      {
        path: 'verify-email/:token',
        name: 'verify-email',
        component: () => import('@/views/auth/VerifyEmailView.vue'),
      },
    ],
  },
  {
    path: '/onboarding',
    component: OnboardingLayout,
    meta: { requiresAuth: true },
    children: [
      {
        path: 'create-organization',
        name: 'onboarding-create-organization',
        component: () => import('@/views/onboarding/CreateOrganizationView.vue'),
      },
    ],
  },
  {
    path: '/',
    component: AppLayout,
    // Merged into `to.meta` for every child, the same mechanism the
    // /onboarding record already relies on.
    meta: { requiresAuth: true },
    children: [
      // Keeping the `home` name on an index redirect means the `guestOnly`
      // branch of the guard below still resolves, so that audited code needs
      // no edit. A redirect record's own meta is never consulted — vue-router
      // resolves the redirect before running guards — so an unauthenticated
      // hit on `/` reaches login with `?redirect=/conversations` rather than
      // `?redirect=/`. Same destination.
      { path: '', name: 'home', redirect: { name: 'conversations' } },
      {
        path: 'conversations',
        name: 'conversations',
        component: () => import('@/views/ConversationsView.vue'),
      },
      {
        path: 'c/:conversationId',
        name: 'workspace',
        component: () => import('@/views/WorkspaceView.vue'),
        props: true,
      },
      {
        path: 'sheets',
        name: 'sheets',
        component: () => import('@/views/SheetsView.vue'),
      },
      {
        path: 'sheets/:sheetId',
        name: 'sheet',
        component: () => import('@/views/SheetView.vue'),
        props: true,
      },
    ],
  },
  {
    path: '/:pathMatch(.*)*',
    name: 'not-found',
    component: () => import('@/views/NotFoundView.vue'),
  },
]

const router = createRouter({
  history: createWebHistory(),
  routes,
})

router.beforeEach((to) => {
  const auth = useAuthStore()
  const isOnboarding = String(to.name ?? '').startsWith('onboarding-')
  const isVerifyEmail = to.name === 'verify-email' || to.name === 'reset-password'

  // Auth required but no session → bounce to login, preserving the
  // intended destination so post-login can resume the navigation.
  if (to.meta.requiresAuth && !auth.isAuthenticated) {
    return { name: 'login', query: { redirect: to.fullPath } }
  }

  // Authenticated user with no memberships gets force-routed to onboarding
  // (unless they're consuming a verification/reset link — those are
  // intentional one-off pages).
  if (auth.isAuthenticated && auth.needsOnboarding && !isOnboarding && !isVerifyEmail) {
    return { name: 'onboarding-create-organization' }
  }

  // Signed-in user wandering into an /auth/* page → home.
  if (to.meta.guestOnly && auth.isAuthenticated && !isVerifyEmail) {
    return { name: 'home' }
  }

  return true
})

export default router
