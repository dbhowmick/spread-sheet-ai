/**
 * Naming helpers for people and actors, shared by the nav rail, participant
 * avatars and the sheet's "changed by" cues.
 */
import type { Actor } from '@/types/contract'

/** Up to two initials from a display name: first and last word. */
export function initials(name: string): string {
  const trimmed = name.trim()
  if (!trimmed) return '?'
  const parts = trimmed.split(/\s+/)
  const first = parts[0]?.[0] ?? ''
  const last = parts.length > 1 ? (parts[parts.length - 1]?.[0] ?? '') : ''
  return (first + last).toUpperCase() || '?'
}

/**
 * Who made a change, for "Changed by …" and "Updated by …". An agent is
 * named after its conversation, since that is how users find it (AI-6).
 */
export function actorName(actor: Actor): string {
  if (actor.type === 'user') return actor.user.display_name
  return actor.conversation_title ? `AI · ${actor.conversation_title}` : 'AI'
}
