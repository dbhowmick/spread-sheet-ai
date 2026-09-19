let cached: string | null | undefined

export function getCsrfToken(): string | null {
  if (cached !== undefined) return cached
  const tag = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')
  cached = tag?.content ?? null
  if (cached === null) {
    console.warn('[csrf] <meta name="csrf-token"> not found — mutating requests will fail')
  }
  return cached
}

export function resetCsrfToken(): void {
  cached = undefined
}
