/**
 * In-memory mock backend (frontend-plan §9) — **skeleton only**.
 *
 * F1 establishes the shape and the selection wiring. The working sheet server
 * is an F2 deliverable, because it reuses `lib/sheet/apply-op.ts`, which does
 * not exist yet; hand-rolling op application here would guarantee throwaway
 * code and mock/server drift (the plan's own §12 risk).
 *
 * Dev-only: `lib/transport/index.ts` gates the dynamic import on
 * `import.meta.env.DEV`, so nothing in this directory reaches a production
 * bundle.
 */
import type {
  ChannelResult,
  ConversationTransport,
  ConversationTransportFactory,
  SheetTransport,
  SheetTransportFactory,
} from '../types'

const notImplemented = (): ChannelResult<never> => ({
  ok: false,
  error: {
    code: 'not_found',
    message: 'The mock backend has no sheets yet — implemented in F2.',
  },
})

export const createMockSheetTransport: SheetTransportFactory = (): SheetTransport => ({
  join: () => Promise.resolve(notImplemented()),
  pushOp: () => Promise.resolve(notImplemented()),
  snapshot: () => Promise.resolve(notImplemented()),
  leave: () => {},
})

export const createMockConversationTransport: ConversationTransportFactory =
  (): ConversationTransport => ({
    join: () => Promise.resolve(notImplemented()),
    sendMessage: () => Promise.resolve(notImplemented()),
    cancel: () => Promise.resolve(notImplemented()),
    openSheet: () => Promise.resolve(notImplemented()),
    leave: () => {},
  })
