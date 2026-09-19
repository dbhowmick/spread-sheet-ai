/**
 * Normalization of the app's standard error envelope (contract §1):
 *
 *   { "errors": [ { "code", "message", "field", "meta" } ] }
 *
 * REST replies and channel replies use the same envelope, so this lives apart
 * from `api.ts` and is shared by both. `api.ts` re-exports `NormalizedError`
 * so its own public surface is unchanged.
 */

export interface NormalizedError {
  code: string
  message?: string
  field?: string
  fieldErrors?: Record<string, string[]>
  retryAfter?: number
}

export interface RawErrorEntry {
  code?: string
  message?: string
  field?: string | null
  meta?: Record<string, unknown>
}

export interface RawErrorEnvelope {
  errors?: RawErrorEntry[]
}

export function defaultCodeForStatus(status: number): string {
  if (status === 401) return 'unauthenticated'
  if (status === 403) return 'forbidden'
  if (status === 404) return 'not_found'
  if (status === 423) return 'account_locked'
  if (status === 429) return 'rate_limited'
  if (status >= 500) return 'server_error'
  return 'unknown'
}

export function normalizeFromEnvelope(envelope: RawErrorEnvelope, status: number): NormalizedError {
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

/**
 * Channel replies carry the same envelope as REST, but with no HTTP status
 * the status-derived fallback is unavailable — `internal_error` is the
 * contract's catch-all (§8).
 *
 * This also handles Phoenix's *own* join failures, which are not enveloped at
 * all: a topic with no matching `channel` route replies
 * `{reason: "unmatched topic"}`, and a crashed join replies
 * `{reason: "join crashed"}`. Until the backend's Phase 5 lands, "unmatched
 * topic" is the only reply a sheet join can get.
 */
export function normalizeChannelError(payload: unknown): NormalizedError {
  const p = payload as (RawErrorEnvelope & { reason?: string }) | null | undefined
  if (p?.errors?.length) return normalizeFromEnvelope(p, 0)
  if (typeof p?.reason === 'string') return { code: 'internal_error', message: p.reason }
  return { code: 'internal_error' }
}
