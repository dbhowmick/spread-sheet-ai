/**
 * Minimal `fetch` wrapper for the JSON API.
 *
 *   const res = await api.post('/api/sessions', { email, password })
 *   if (res.ok) { ... } else { res.error.code }
 *
 * - Always sends `credentials: 'include'` so the HttpOnly auth cookie
 *   travels both directions automatically.
 * - On mutating verbs, attaches `X-CSRF-Token` read from
 *   `<meta name="csrf-token">`. On a 403 with `invalid_csrf_token`,
 *   refreshes the cached token and retries once.
 * - Normalizes every error into `{ code, fieldErrors?, retryAfter? }`
 *   matching the canonical envelope returned by `<%= @web %>.Api.Errors`.
 */
import { getCsrfToken, resetCsrfToken } from './csrf'

type Method = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'

export interface NormalizedError {
  code: string
  message?: string
  field?: string
  fieldErrors?: Record<string, string[]>
  retryAfter?: number
}

export type ApiOk<T> = { ok: true; status: number; data: T }
export type ApiErr = { ok: false; status: number; error: NormalizedError }
export type ApiResult<T> = ApiOk<T> | ApiErr

interface RequestOptions {
  headers?: Record<string, string>
  signal?: AbortSignal
}

interface RawErrorEntry {
  code?: string
  message?: string
  field?: string | null
  meta?: Record<string, unknown>
}

interface RawErrorEnvelope {
  errors?: RawErrorEntry[]
}

async function readJson(res: Response): Promise<unknown> {
  const text = await res.text()
  if (!text) return null
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

function isInvalidCsrf(body: unknown): boolean {
  const envelope = body as RawErrorEnvelope | null
  return !!envelope?.errors?.some((e) => e?.code === 'invalid_csrf_token')
}

function normalizeFromEnvelope(envelope: RawErrorEnvelope, status: number): NormalizedError {
  const entries = envelope.errors ?? []
  const fieldErrors: Record<string, string[]> = {}
  let topCode: string | undefined
  let topMessage: string | undefined
  let retryAfter: number | undefined

  for (const e of entries) {
    if (e.field) {
      const key = e.field
      fieldErrors[key] = fieldErrors[key] ?? []
      fieldErrors[key].push(e.message ?? e.code ?? 'invalid')
    } else if (!topCode) {
      topCode = e.code
      topMessage = e.message
      const ra = (e.meta as { retry_after_seconds?: number } | undefined)?.retry_after_seconds
      if (typeof ra === 'number') retryAfter = ra
    }
  }

  if (!topCode) {
    if (Object.keys(fieldErrors).length > 0) {
      topCode = 'validation_failed'
    } else {
      topCode = defaultCodeForStatus(status)
    }
  }

  const out: NormalizedError = { code: topCode }
  if (topMessage) out.message = topMessage
  if (Object.keys(fieldErrors).length > 0) out.fieldErrors = fieldErrors
  if (retryAfter !== undefined) out.retryAfter = retryAfter
  return out
}

function defaultCodeForStatus(status: number): string {
  if (status === 401) return 'unauthenticated'
  if (status === 403) return 'forbidden'
  if (status === 404) return 'not_found'
  if (status === 423) return 'account_locked'
  if (status === 429) return 'rate_limited'
  if (status >= 500) return 'server_error'
  return 'unknown'
}

async function doFetch(
  method: Method,
  path: string,
  body: unknown,
  options: RequestOptions,
): Promise<Response> {
  const headers: Record<string, string> = {
    Accept: 'application/json',
    ...(options.headers ?? {}),
  }

  if (method !== 'GET') {
    const csrf = getCsrfToken()
    if (csrf) headers['X-CSRF-Token'] = csrf
  }

  const init: RequestInit = {
    method,
    credentials: 'include',
    headers,
    signal: options.signal,
  }

  if (body !== undefined && method !== 'GET') {
    headers['Content-Type'] = 'application/json'
    init.body = JSON.stringify(body)
  }

  return fetch(path, init)
}

async function request<T>(
  method: Method,
  path: string,
  body?: unknown,
  options: RequestOptions = {},
): Promise<ApiResult<T>> {
  let res: Response
  try {
    res = await doFetch(method, path, body, options)
  } catch {
    return { ok: false, status: 0, error: { code: 'network_error' } }
  }

  // CSRF stale → reset cached token, retry once.
  if (res.status === 403 && method !== 'GET') {
    const peek = await readJson(res.clone())
    if (isInvalidCsrf(peek)) {
      resetCsrfToken()
      try {
        res = await doFetch(method, path, body, options)
      } catch {
        return { ok: false, status: 0, error: { code: 'network_error' } }
      }
      if (res.status === 403) {
        return { ok: false, status: 403, error: { code: 'csrf_stale' } }
      }
    }
  }

  if (res.status === 204) {
    return { ok: true, status: 204, data: undefined as T }
  }

  const json = await readJson(res)

  if (res.ok) {
    return { ok: true, status: res.status, data: json as T }
  }

  const envelope = (json ?? { errors: [] }) as RawErrorEnvelope
  return {
    ok: false,
    status: res.status,
    error: normalizeFromEnvelope(envelope, res.status),
  }
}

export const api = {
  get: <T>(path: string, options?: RequestOptions) => request<T>('GET', path, undefined, options),
  post: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>('POST', path, body, options),
  put: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>('PUT', path, body, options),
  patch: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>('PATCH', path, body, options),
  delete: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>('DELETE', path, body, options),
}
