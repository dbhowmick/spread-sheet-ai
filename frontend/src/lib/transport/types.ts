/**
 * The seam between the stores and whatever is serving them — a real Phoenix
 * channel or the in-memory mock (frontend-plan §5, §9).
 */
import type { NormalizedError } from '@/lib/errors'
import type {
  ConversationFocusSheetEvent,
  ConversationJoinReply,
  ConversationQueuedEvent,
  ConversationStatusEvent,
  ConversationToolStatusEvent,
  LinkedSheet,
  Message,
  Op,
  OpAppliedEvent,
  Sheet,
  SheetId,
  UserRef,
  Uuid,
} from '@/types/contract'

/**
 * A channel reply. Distinct from `ApiResult` in `lib/api.ts`, which carries an
 * HTTP `status` that channel replies don't have.
 */
export type ChannelOk<T> = { ok: true; data: T }
export type ChannelErr = { ok: false; error: NormalizedError }
export type ChannelResult<T> = ChannelOk<T> | ChannelErr

/**
 * Matches the phoenix client's own default push timeout. On expiry a push
 * resolves to `{code: 'timeout'}`, which the store treats as a rejection.
 */
export const PUSH_TIMEOUT_MS = 10_000

/** An `ok {}` reply that carries no data. */
export type Empty = Record<string, never>

// Handler *methods* are camelCase; the payload objects they receive keep the
// server's snake_case verbatim. That rule holds across the transport layer.

export interface SheetTransportHandlers {
  opApplied(event: OpAppliedEvent): void
  participants(users: UserRef[]): void
  /**
   * Phoenix rejoined after a reconnect. `sheet` is a fresh snapshot, and every
   * in-flight push is lost, because replies for ops sent before the
   * disconnect never arrive (contract §4).
   */
  rejoined(sheet: Sheet): void
  /** The channel errored or closed. Drives F7's reconnect indicator. */
  disconnected?(): void
}

export interface SheetTransport {
  join(): Promise<ChannelResult<{ sheet: Sheet }>>
  pushOp(clientOpId: Uuid, op: Op): Promise<ChannelResult<{ version: number }>>
  snapshot(): Promise<ChannelResult<{ sheet: Sheet }>>
  leave(): void
}

/**
 * `sheetId` and `handlers` are constructor arguments rather than arguments to
 * `join()` / a separate `on()` — a deliberate deviation from the
 * frontend-plan §5 sketch. `rejoined` can fire *during* the first join
 * round-trip if the socket flaps, so registering handlers after `await join()`
 * would race. One transport instance is one topic, matching one store entry.
 */
export type SheetTransportFactory = (
  sheetId: SheetId,
  handlers: SheetTransportHandlers,
) => SheetTransport

export interface ConversationTransportHandlers {
  message(message: Message): void
  messageUpdated(message: Message): void
  streamDelta(text: string): void
  streamReset(): void
  toolStatus(event: ConversationToolStatusEvent): void
  status(event: ConversationStatusEvent): void
  messageQueued(event: ConversationQueuedEvent): void
  title(title: string): void
  sheets(sheets: LinkedSheet[]): void
  focusSheet(event: ConversationFocusSheetEvent): void
  participants(users: UserRef[]): void
  rejoined(reply: ConversationJoinReply): void
  disconnected?(): void
}

export interface ConversationTransport {
  join(): Promise<ChannelResult<ConversationJoinReply>>
  sendMessage(text: string): Promise<ChannelResult<Empty>>
  cancel(): Promise<ChannelResult<Empty>>
  openSheet(sheetId: SheetId): Promise<ChannelResult<{ sheet: LinkedSheet }>>
  leave(): void
}

export type ConversationTransportFactory = (
  conversationId: Uuid,
  handlers: ConversationTransportHandlers,
) => ConversationTransport
