/**
 * The Phoenix socket singleton (contract §4).
 *
 * WebSockets can't use the HttpOnly auth cookie directly, so the client first
 * calls `GET /api/socket_token` (cookie-authenticated) and connects with that
 * token. It travels in the `Sec-WebSocket-Protocol` header, never the URL.
 *
 * A token is valid for 24 hours and only for *opening* a connection; an open
 * socket stays connected after its token expires. If a (re)connection is
 * refused we fetch a fresh one and let Phoenix's own reconnect timer retry.
 *
 * This module stays framework-agnostic on purpose (see CLAUDE.md on
 * `src/lib/`): it imports no Pinia store and no router. The one thing it needs
 * from the app — "the session is gone, sign out" — is injected via
 * `configureSocket`, which also keeps `stores/auth -> lib/socket` a single
 * one-way edge with no import cycle.
 */
import { Socket, type Channel } from 'phoenix'

import { api } from './api'
import type { SocketTokenResponse } from '@/types/contract'

export type ConnectionState = 'idle' | 'connecting' | 'open' | 'closed'

interface SocketHooks {
  /** `GET /api/socket_token` returned 401 — the cookie session is gone. */
  onUnauthenticated?: () => void
}

const MAX_BACKOFF_MS = 30_000

let socket: Socket | null = null
let currentToken: string | null = null
let inflight: Promise<string | null> | null = null
let attempts = 0
let hooks: SocketHooks = {}

let state: ConnectionState = 'idle'
const listeners = new Set<(s: ConnectionState) => void>()

function emit(next: ConnectionState): void {
  state = next
  for (const fn of listeners) fn(next)
}

export function currentConnectionState(): ConnectionState {
  return state
}

/** Returns an unsubscribe function. */
export function onConnectionChange(fn: (s: ConnectionState) => void): () => void {
  listeners.add(fn)
  return () => {
    listeners.delete(fn)
  }
}

export function configureSocket(next: SocketHooks): void {
  hooks = next
}

function backoffMs(n: number): number {
  return Math.min(1000 * 2 ** n, MAX_BACKOFF_MS) * (0.5 + Math.random() / 2)
}

/** Concurrent callers collapse onto a single in-flight request. */
function refreshToken(): Promise<string | null> {
  inflight ??= (async () => {
    const delay = attempts === 0 ? 0 : backoffMs(attempts)
    attempts += 1
    if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay))

    const res = await api.get<SocketTokenResponse>('/api/socket_token')
    inflight = null

    if (res.ok) {
      currentToken = res.data.token
      attempts = 0
      return currentToken
    }
    if (res.status === 401) hooks.onUnauthenticated?.()
    return null
  })()

  return inflight
}

function getSocket(): Socket {
  if (socket) return socket

  // @types/phoenix@1.6.7 declares `authToken: string`, but the phoenix 1.8.14
  // client pipes the option through `closure()` and calls it inside
  // `transportConnect()` on *every* (re)connect — which is what lets a
  // refreshed token be picked up without rebuilding the Socket. Interface
  // merging can't widen a property's type, so cast here, once.
  const authToken = (() => currentToken ?? '') as unknown as string

  const s = new Socket('/socket', { authToken })

  s.onOpen(() => {
    attempts = 0
    emit('open')
  })
  s.onClose(() => emit('closed'))
  s.onError(() => {
    emit('closed')
    // Phoenix owns the reconnect timer. All we do is make sure the token the
    // thunk hands it on the *next* attempt is fresh. Never call connect()
    // here — that would fight `reconnectAfterMs`.
    void refreshToken()
  })

  socket = s
  return s
}

/** Idempotent: `Socket.connect()` no-ops when a connection already exists. */
export async function ensureConnected(): Promise<boolean> {
  const s = getSocket()
  if (s.isConnected()) return true
  if (currentToken === null && (await refreshToken()) === null) return false
  emit('connecting')
  s.connect()
  return true
}

/** Lazy connect: joining a topic opens the socket if it isn't open yet. */
export async function joinTopic(topic: string, params: object = {}): Promise<Channel> {
  await ensureConnected()
  return getSocket().channel(topic, params)
}

/**
 * Full teardown, so the next sign-in fetches a fresh token. Called by
 * `authStore.signOut` / `signOutEverywhere`.
 */
export function disconnectSocket(): void {
  socket?.disconnect()
  socket = null
  currentToken = null
  inflight = null
  attempts = 0
  emit('idle')
}
