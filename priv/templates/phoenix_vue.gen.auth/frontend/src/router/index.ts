import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'

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
      { path: 'register', name: 'register', component: () => import('@/views/auth/RegisterView.vue') },
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
    name: 'home',
    component: () => import('@/views/HomeView.vue'),
    meta: { requiresAuth: true },
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
