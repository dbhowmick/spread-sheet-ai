/**
 * Translates the stable error `code` from the API envelope to a
 * human-readable message. Mirror of the server-side message map in
 * `<%= @web %>.Api.Errors` so the client has sensible fallbacks even
 * when the server omits `message` (it sometimes does for codes whose
 * default is generic).
 */
const MESSAGES: Record<string, string> = {
  invalid_credentials: 'Email or password is incorrect.',
  email_not_verified: 'Please verify your email address first.',
  invalid_token: 'This link is invalid or has already been used.',
  expired_token: 'This link has expired. Please request a new one.',
  account_locked: 'This account is temporarily locked. Try again later.',
  rate_limited: 'Too many requests. Please try again in a moment.',
  invalid_email: 'That email address is not valid.',
  invalid_current_password: 'Your current password is incorrect.',
  no_password_credential: 'This account does not have a password set.',
  unauthenticated: 'Please sign in.',
  weak_password: 'That password is too common. Please pick a stronger one.',
  too_short: 'That value is too short.',
  too_long: 'That value is too long.',
  required: 'This field is required.',
  already_taken: 'That value is already taken.',
  slug_taken: 'That organization name is already in use.',
  network_error: "Couldn't reach the server. Check your connection and try again.",
  csrf_stale: 'Your session expired. Please reload the page.',
  server_error: 'Something went wrong on our end. Please try again.',
  validation_failed: 'Please fix the errors below.',
  unknown: 'Something went wrong. Please try again.',
}

const FALLBACK = 'Something went wrong. Please try again.'

export function useErrorMessage() {
  return function errorMessage(code: string | undefined | null): string {
    if (!code) return MESSAGES.unknown ?? FALLBACK
    return MESSAGES[code] ?? MESSAGES.unknown ?? FALLBACK
  }
}
