/**
 * TypeScript mirror of `docs/contract.md` — the single source of wire shapes
 * for the SPA.
 *
 * Every name here corresponds to something that crosses the socket or the
 * JSON API, and every property keeps the server's `snake_case`. Sections are
 * ordered and headed to match the contract document so the two can be diffed.
 *
 * Types only — no runtime exports, so this module erases completely and stays
 * `import type`-able everywhere.
 *
 * Client-derived state (SheetState, pending-op bookkeeping, conversation
 * store entries) is deliberately NOT here: it belongs in `lib/sheet/` and
 * `stores/`. Keeping that boundary is what makes this file a faithful mirror.
 */

// ---------------------------------------------------------------------------
// §1 Conventions
// ---------------------------------------------------------------------------

/**
 * A UUID string. An alias, not a brand: these cross the JSON boundary as
 * plain strings and there is no validation layer to launder casts through.
 * The grid always passes `{rowId, columnId}` pairs, so mix-ups are unlikely.
 */
export type Uuid = string
export type SheetId = Uuid
export type ColumnId = Uuid
export type RowId = Uuid
export type ConversationId = Uuid
export type MessageId = Uuid

/** ISO 8601 UTC, e.g. `"2026-09-19T10:05:00Z"`. */
export type Iso8601 = string

// ---------------------------------------------------------------------------
// §2 Shared shapes
// ---------------------------------------------------------------------------

/** §2.1. `display_name` falls back to the user's email when unset. */
export interface UserRef {
  id: Uuid
  display_name: string
}

/** §2.2. */
export type ColumnType = 'text' | 'number' | 'boolean' | 'date'

/**
 * §2.2. A `date` is a `"YYYY-MM-DD"` string. `null` is an empty cell in every
 * column type; the label column is always `text` and never `null`.
 */
export type CellValue = string | number | boolean | null

/**
 * §2.4. A missing key and `null` mean the same thing — which is exactly what
 * `noUncheckedIndexedAccess` models, so reads are `CellValue | undefined` by
 * design. F2's `values.ts` provides the normalizer.
 */
export type CellMap = Record<ColumnId, CellValue>

/** §2.3. Listed in display order; position is the index in the array. */
export interface Column {
  id: ColumnId
  name: string
  column_type: ColumnType
  is_label: boolean
}

/** §2.4. `cells` includes the label column's value. */
export interface Row {
  id: RowId
  cells: CellMap
}

/** §2.5. */
export interface SheetSummary {
  id: SheetId
  name: string
  owner: UserRef
  row_count: number
  column_count: number
  version: number
  inserted_at: Iso8601
  updated_at: Iso8601
}

/** §2.6. The full snapshot delivered on channel join. */
export interface Sheet {
  id: SheetId
  name: string
  owner: UserRef
  version: number
  columns: Column[]
  rows: Row[]
  inserted_at: Iso8601
  updated_at: Iso8601
}

/** §2.7. Who made a change. Discriminated on `type`. */
export interface UserActor {
  type: 'user'
  user: UserRef
}
export interface AgentActor {
  type: 'agent'
  conversation_id: ConversationId
  conversation_title: string
}
export type Actor = UserActor | AgentActor

/** §2.8. `title` is `null` until it is generated. */
export interface ConversationSummary {
  id: ConversationId
  title: string | null
  created_by: UserRef
  inserted_at: Iso8601
  updated_at: Iso8601
}

/** §2.9. Shared with `focus_sheet`'s `reason` (§7.3). */
export type SheetAccess = 'created' | 'opened' | 'read' | 'written'

export interface LinkedSheet {
  sheet: SheetSummary
  created_here: boolean
  last_access: SheetAccess
  first_accessed_at: Iso8601
  last_accessed_at: Iso8601
}

// §2.10 Message.
//
// The union is discriminated at the *Message* level, not inside `content`:
// `content` has no discriminant of its own, `content_type` is the tag.

export type MessageRole = 'user' | 'assistant' | 'tool'

export type MessageStatus = 'completed' | 'pending' | 'executing' | 'failed' | 'cancelled'

/** §2.10. Present on the last item of a message that did not finish. */
export type StopReason = 'length' | 'cancelled' | 'content_filtered' | 'stream_error'

interface MessageContentBase {
  stop_reason?: StopReason
}

export interface TextContent extends MessageContentBase {
  text: string
}
export interface ThinkingContent extends MessageContentBase {
  text: string
}
export interface ToolCallContent extends MessageContentBase {
  call_id: string
  name: string
  display_text: string
  arguments: Record<string, unknown>
}
export interface ToolResultContent extends MessageContentBase {
  tool_call_id: string
  name: string
  content: string
  is_error: boolean
}
export interface NotificationContent extends MessageContentBase {
  text: string
  /** Narrowed from the optional base — §2.10 fixes this to `cancelled`. */
  stop_reason: 'cancelled'
}
export interface ErrorContent extends MessageContentBase {
  text: string
  error_type: string | null
}

interface MessageBase {
  id: MessageId
  role: MessageRole
  /** Set for `user` messages, `null` otherwise. */
  sender: UserRef | null
  status: MessageStatus
  inserted_at: Iso8601
}

export interface TextMessage extends MessageBase {
  content_type: 'text'
  content: TextContent
}
export interface ThinkingMessage extends MessageBase {
  content_type: 'thinking'
  content: ThinkingContent
}
export interface ToolCallMessage extends MessageBase {
  content_type: 'tool_call'
  content: ToolCallContent
}
export interface ToolResultMessage extends MessageBase {
  content_type: 'tool_result'
  content: ToolResultContent
}
export interface NotificationMessage extends MessageBase {
  content_type: 'notification'
  content: NotificationContent
}
export interface ErrorMessage extends MessageBase {
  content_type: 'error'
  content: ErrorContent
}

export type Message =
  | TextMessage
  | ThinkingMessage
  | ToolCallMessage
  | ToolResultMessage
  | NotificationMessage
  | ErrorMessage

export type MessageContentType = Message['content_type']

// ---------------------------------------------------------------------------
// §6 Operations
// ---------------------------------------------------------------------------
//
// `Op` is what the client sends. `AppliedOp` is the server's normalized
// broadcast: the same op with every id filled in and values in their stored
// types.
//
// Where the two differ, the Applied variant `extends` the Op variant and
// narrows its optional fields to required. That makes `AppliedOp` assignable
// to `Op`, so F2's single `applyOp` can take `Op | AppliedOp`.
//
// Inside `switch (op.type)` over `Op | AppliedOp`, each branch narrows to the
// union of both variants — i.e. the looser one. That is correct for
// `applyOp`, which per frontend-plan §6.3 assumes validity and fills in
// defaults. For the fields only `AppliedOp` carries, use an `in` check:
//
//     case 'change_column_type': {
//       const converted = 'cells' in op ? op.cells : null
//     }

export interface RenameSheetOp {
  type: 'rename_sheet'
  name: string
}

export interface AddColumnOp {
  type: 'add_column'
  /**
   * Client-generated UUID v4. Always sent by this client so the local preview
   * and the confirmed result share ids (frontend-plan §6.2). An id already in
   * use is rejected with `invalid_op`.
   */
  id?: ColumnId
  name: string
  column_type: ColumnType
  /** Index in `0..length`; defaults to the end. */
  position?: number
}
export interface AppliedAddColumnOp extends AddColumnOp {
  id: ColumnId
  position: number
}

export interface RenameColumnOp {
  type: 'rename_column'
  column_id: ColumnId
  name: string
}

export interface ChangeColumnTypeOp {
  type: 'change_column_type'
  column_id: ColumnId
  column_type: ColumnType
}
export interface ConvertedCell {
  row_id: RowId
  value: CellValue
}
export interface AppliedChangeColumnTypeOp extends ChangeColumnTypeOp {
  /**
   * Every row that had a value, with its server-converted value. A value that
   * converts to empty (blank text) is `null`.
   */
  cells: ConvertedCell[]
}

export interface MoveColumnOp {
  type: 'move_column'
  column_id: ColumnId
  /** The column's final index after the move, in `0..length-1`. */
  position: number
}

export interface DeleteColumnOp {
  type: 'delete_column'
  column_id: ColumnId
}

export interface NewRow {
  id?: RowId
  cells: CellMap
}
export interface AppliedNewRow extends NewRow {
  id: RowId
}

export interface AddRowsOp {
  type: 'add_rows'
  rows: NewRow[]
  /** Where the first new row lands, in `0..length`; defaults to the end. */
  position?: number
}
export interface AppliedAddRowsOp extends AddRowsOp {
  rows: AppliedNewRow[]
  /** The index of the *first* new row. */
  position: number
}

export interface DeleteRowsOp {
  type: 'delete_rows'
  row_ids: RowId[]
}

export interface MoveRowOp {
  type: 'move_row'
  row_id: RowId
  /** The row's final index after the move, in `0..length-1`. */
  position: number
}

export interface CellEdit {
  row_id: RowId
  column_id: ColumnId
  value: CellValue
}
export interface SetCellsOp {
  type: 'set_cells'
  cells: CellEdit[]
}

/**
 * Emitted by the backend engine when a sheet is created. Never sent by the
 * client — `AppliedOp` only — but F2's `applyOp` must still handle it.
 */
export interface CreateSheetAppliedOp {
  type: 'create_sheet'
  name: string
  columns: Column[]
  rows: Row[]
}

export type Op =
  | RenameSheetOp
  | AddColumnOp
  | RenameColumnOp
  | ChangeColumnTypeOp
  | MoveColumnOp
  | DeleteColumnOp
  | AddRowsOp
  | DeleteRowsOp
  | MoveRowOp
  | SetCellsOp

export type OpType = Op['type']

export type AppliedOp =
  | RenameSheetOp
  | AppliedAddColumnOp
  | RenameColumnOp
  | AppliedChangeColumnTypeOp
  | MoveColumnOp
  | DeleteColumnOp
  | AppliedAddRowsOp
  | DeleteRowsOp
  | MoveRowOp
  | SetCellsOp
  | CreateSheetAppliedOp

export type AppliedOpType = AppliedOp['type']

/** Narrow an `AppliedOp` by its tag, e.g. `AppliedOpOf<'add_rows'>`. */
export type AppliedOpOf<T extends AppliedOpType> = Extract<AppliedOp, { type: T }>

// ---------------------------------------------------------------------------
// §5 Channel `sheet:<sheet_id>`
// ---------------------------------------------------------------------------

/** §5.1 join reply. */
export interface SheetJoinReply {
  sheet: Sheet
}

/** §5.2 client -> server. */
export interface OpPush {
  client_op_id: Uuid
  op: Op
}
export interface OpPushReply {
  version: number
}
export interface SnapshotReply {
  sheet: Sheet
}

/** §5.3 server -> client. */
export interface OpAppliedEvent {
  version: number
  op: AppliedOp
  actor: Actor
  /** `null` when the op did not originate from this client. */
  client_op_id: Uuid | null
}

/** The full list of current viewers; sent after join and on every change. */
export interface ParticipantsEvent {
  users: UserRef[]
}

// ---------------------------------------------------------------------------
// §7 Channel `conversation:<conversation_id>`
// ---------------------------------------------------------------------------
//
// Every event type here is prefixed `Conversation*`. A bare `MessageEvent`
// would shadow the DOM global of the same name, which `lib/socket.ts` uses.

export type AgentStatus = 'idle' | 'running' | 'cancelled' | 'error'

/** §7.1 adds `not_started`: no agent process is running; one starts on the
 *  first message. The `status` push (§7.3) never carries it. */
export type ConversationJoinStatus = AgentStatus | 'not_started'

export interface ConversationJoinReply {
  conversation: ConversationSummary
  /** Oldest first. */
  messages: Message[]
  sheets: LinkedSheet[]
  status: ConversationJoinStatus
}

/** §7.2 client -> server. */
export interface SendMessagePush {
  text: string
}
export interface OpenSheetPush {
  sheet_id: SheetId
}
export interface OpenSheetReply {
  sheet: LinkedSheet
}

/** §7.3 server -> client. */
export interface ConversationMessageEvent {
  message: Message
}
export interface ConversationStreamDeltaEvent {
  text: string
}

export type ToolCallStatus = 'identified' | 'executing' | 'completed' | 'failed'

export interface ConversationToolStatusEvent {
  call_id: string
  name: string
  display_text: string
  status: ToolCallStatus
}
export interface ConversationStatusEvent {
  status: AgentStatus
  error: string | null
}
export interface ConversationQueuedEvent {
  sender: UserRef
  text: string
}
export interface ConversationTitleEvent {
  title: string
}
export interface ConversationSheetsEvent {
  sheets: LinkedSheet[]
}
export interface ConversationFocusSheetEvent {
  sheet_id: SheetId
  reason: SheetAccess
}

// ---------------------------------------------------------------------------
// §3 REST endpoints
// ---------------------------------------------------------------------------
//
// Success bodies use a resource-named top-level key, never a `data` wrapper.

export interface SocketTokenResponse {
  token: string
}

/** Newest `updated_at` first. */
export interface SheetsIndexResponse {
  sheets: SheetSummary[]
}
export interface SheetShowResponse {
  sheet: Sheet
}
export interface CreateSheetRequest {
  name: string
  /** Defaults to `"Line item"`. */
  label_column_name?: string
  columns?: { name: string; column_type: ColumnType }[]
}

/** Newest first. */
export interface ConversationsIndexResponse {
  conversations: ConversationSummary[]
}
export interface ConversationShowResponse {
  conversation: ConversationSummary
}

// ---------------------------------------------------------------------------
// §8 Error codes
// ---------------------------------------------------------------------------

export type ContractErrorCode =
  | 'unauthenticated'
  | 'not_found'
  | 'validation_failed'
  | 'invalid_op'
  | 'unknown_column'
  | 'unknown_row'
  | 'duplicate_column_name'
  | 'duplicate_label'
  | 'label_required'
  | 'label_column_protected'
  | 'invalid_value'
  | 'type_conversion_failed'
  | 'invalid_position'
  | 'too_many_cells'
  | 'not_running'
  | 'internal_error'

/**
 * §6 attaches these to specific codes: `invalid_value` carries row + column,
 * `type_conversion_failed` carries the first failing row, `too_many_cells`
 * carries the cap.
 */
export interface ContractErrorMeta {
  row_id?: RowId
  column_id?: ColumnId
  max?: number
}

export interface ContractError {
  /**
   * Kept as `string`, not `ContractErrorCode`: `lib/api.ts` already emits
   * codes outside the contract (`network_error`, `csrf_stale`, `forbidden`,
   * `rate_limited`) and the transport adds `timeout`. Narrow at the
   * comparison site instead.
   */
  code: string
  message: string
  field: string | null
  meta: ContractErrorMeta & Record<string, unknown>
}

/** §1. The standard envelope, used by REST and channel replies alike. */
export interface ContractErrorEnvelope {
  errors: ContractError[]
}
