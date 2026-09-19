/**
 * Chooses between the real Phoenix transport and the in-memory mock.
 */
import { createPhoenixConversationTransport, createPhoenixSheetTransport } from './phoenix'
import type { ConversationTransportFactory, SheetTransportFactory } from './types'

let sheetFactory: SheetTransportFactory = createPhoenixSheetTransport
let conversationFactory: ConversationTransportFactory = createPhoenixConversationTransport

/**
 * Awaited once in `main.ts` before mount, so every consumer stays synchronous.
 *
 * The `import.meta.env.DEV` early return is what actually keeps the mock out
 * of production bundles: Vite replaces `DEV` with a literal during transform,
 * *before* Rollup tree-shakes, so the dynamic import below becomes provably
 * dead and its chunk is never emitted. Gating on `VITE_MOCK_BACKEND` alone
 * would not be enough — Vite only inlines `VITE_*` keys that are defined at
 * build time, so an unset one survives as a runtime property read.
 */
export async function installBackend(): Promise<void> {
  if (!import.meta.env.DEV) return
  if (import.meta.env.VITE_MOCK_BACKEND !== '1') return

  const mock = await import('./mock')
  sheetFactory = mock.createMockSheetTransport
  conversationFactory = mock.createMockConversationTransport
  console.info('[transport] mock backend enabled (VITE_MOCK_BACKEND=1)')
}

export const createSheetTransport: SheetTransportFactory = (sheetId, handlers) =>
  sheetFactory(sheetId, handlers)

export const createConversationTransport: ConversationTransportFactory = (id, handlers) =>
  conversationFactory(id, handlers)

export * from './types'
