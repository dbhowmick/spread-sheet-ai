# SpreadSheetAi POC — Frontend Implementation Plan

Status: draft for review · Date: 2026-09-20
Implements: [requirements.md](requirements.md) · Interface: [contract.md](contract.md)
Built in parallel with [backend-plan.md](backend-plan.md).

This plan was checked against `@tanstack/vue-table` 9.2.4 and
`@tanstack/vue-virtual` 3.13.39. It also uses the existing shadcn-vue
components (`src/components/ui`) and AI Elements (`src/components/ai-elements`).

## 1. Principles

1. **The grid never mutates data.** Every user edit becomes a contract
   `Op`. The sheet store applies it as a local preview and sends it. When
   the server confirms it with `op_applied`, the preview is replaced. What
   the grid shows is confirmed state with pending previews on top.
2. **One pure `applyOp`.** The same TypeScript function applies local
   previews (`Op`) and confirmed server ops (`AppliedOp`). It's a pure
   function, which keeps it testable.
3. **TanStack is only the view layer.** It renders the store's current
   view. Row and column order always comes from the server's state, never
   from TanStack state.
4. **Display and editor are separate per cell type.** Every cell renders a
   light display component. An editor is mounted in the one cell being
   edited, never in every cell.
5. **Parallel development through a transport interface.** Stores talk to
   a `Transport`, which has a Phoenix implementation and an in-memory mock
   (§9). The UI is built and tested against the mock until the backend
   reaches milestones M1–M3.

## 2. Dependencies to add

| Package | Why |
|---|---|
| `@tanstack/vue-table` ^9.2.4 | Headless grid |
| `@tanstack/vue-virtual` ^3.13.39 | Row virtualization |
| `vitest`, `@vue/test-utils`, `happy-dom` (dev) | The frontend has no test runner yet. Add a `pnpm test` script |

Everything else is already installed: `phoenix`, shadcn-vue, AI Elements,
`@internationalized/date`, `@vueuse/core`, `nanoid`, `vue-sonner`.

## 3. Module map

These follow the conventions in CLAUDE.md.

```
src/types/contract.ts            TS types mirroring contract.md §2, §5, §6, §7 (single source for the SPA)
src/lib/socket.ts                Phoenix Socket singleton + token fetch/refresh (contract §4)
src/lib/transport/
  types.ts                       SheetTransport / ConversationTransport interfaces
  phoenix.ts                     channel-backed implementation
  mock/                          in-memory mock backend (§9)
src/lib/sheet/
  grid.ts                        pure grid layout: default widths, pinned order, --grid-cols, cue freshness
  navigation.ts                  pure: moves, key → intent, active cell across remote deletes
  apply-op.ts                    pure applyOp(state, op) for Op and AppliedOp
  values.ts                      per-type parse / format / validate (mirrors server casting)
  consistency.ts                 pure reducer: confirmed + pending + incoming events (contract §5.4)
  paste.ts                       TSV clipboard → set_cells op
src/stores/
  sheets.ts                      one entry per open sheet: channel, state, pending, participants, cues
  conversations.ts               one entry per open conversation: messages, stream, tools, status…
src/composables/
  useSheet.ts                    ref-counted join/leave of a sheet in the store
  useConversation.ts             same for conversations
  useGridNavigation.ts           active cell + keyboard model
  useSheetTable.ts               TanStack useTable setup (features, columns, pinning, sizing)
src/components/sheet/
  SheetGrid.vue                  scroll container, virtualized rows, sticky header and label column
  SheetHeaderCell.vue            header + column DropdownMenu + resize handle
  SheetRow.vue, SheetCell.vue    SheetCell chooses display/editor from the registry
  SheetRowGutter.vue             row number, swapped for the selection checkbox on hover
  context.ts                     provide/inject of cues, pending cells and the cue clock
  cells/registry.ts              column_type → {display, editor, align}
  cells/{Text,Number,Boolean,Date,Label}Display.vue
  cells/CellEditor.vue           the shared typed-text editor (text, number, label)
  cells/DateEditor.vue           the same input plus a Calendar popover
  ColumnMenu.vue, RowMenu.vue    the structure menus (§7.5)
  ConfirmDialog.vue, NewRowDialog.vue
  AddColumnDialog.vue, NewRowInput.vue, SheetToolbar.vue, CreateSheetDialog.vue
src/components/app/
  ParticipantAvatars.vue         shared by the sheet toolbar and (F5) the chat header
src/components/chat/
  ChatPanel.vue                  AI Elements Conversation + PromptInput
  ChatMessage.vue                maps a contract Message to AI Elements parts
  ToolCallItem.vue               tool_call + tool_result pair → Tool / ToolHeader / ToolInput / ToolOutput
src/components/workspace/
  SheetTabs.vue                  tabbed sheets inside a conversation
  OpenSheetDialog.vue            Command palette over GET /api/sheets
src/layouts/AppLayout.vue        shadcn Sidebar shell: Conversations, Sheets, user menu
src/views/
  ConversationsView.vue          /conversations
  WorkspaceView.vue              /c/:conversationId       (chat + tabbed sheets)
  SheetsView.vue                 /sheets
  SheetView.vue                  /sheets/:sheetId         (standalone sheet, UI-5)
```

## 4. Routing and shell

- **Routes:** `/` redirects to `/conversations`. The new routes use
  `AppLayout` and `meta.requiresAuth`. The existing auth and onboarding
  guards stay as they are.
- **`AppLayout`:** a shadcn `SidebarProvider` + `Sidebar` with the links
  Conversations and Sheets, and a user menu with the display name and
  "Sign out". The main content goes in `SidebarInset`.
- **`WorkspaceView`:** a `ResizablePanelGroup` split into the chat panel
  (left, about 35%) and `SheetTabs` (right).
- **Sheet tabs:** in-app tabs inside the workspace, built on shadcn
  `Tabs`. These are not browser tabs. Several sheets can be open in one
  chat session, and each tab shows one sheet.
  - The tab strip shows each sheet's name with a close button, plus a `+`
    button that opens `OpenSheetDialog` to add a sheet.
  - The list of open tabs is local to each user. It is saved in
    `localStorage`, keyed by conversation id; a read failure is ignored.
  - The active tab is saved in the URL (`?sheet=<id>`), so a reload or a
    shared link keeps it.
  - `focus_sheet` opens that sheet's tab if needed and makes it the
    active tab (UI-4). Opening a sheet manually through `OpenSheetDialog`
    sends `open_sheet` and then opens its tab.
  - Inactive tabs stay mounted, with the grid hidden, so switching tabs
    keeps scroll position and the active cell, and doesn't rejoin the
    channel.

## 5. Transport

**`lib/socket.ts`:**
1. `GET /api/socket_token` using the existing `api.get`.
2. Create the socket: `new Socket('/socket', { authToken: () => token })`.
3. On a socket error, refetch the token with backoff. If the token fetch
   returns `401`, call `authStore.clearState()` and redirect to login.
4. `connect()` is lazy: the first channel join triggers it.
5. `authStore.signOut` disconnects the socket.

**`transport/phoenix.ts`** wraps channels into typed interfaces:

```ts
interface SheetTransport {
  join(sheetId): Promise<Result<{ sheet: Sheet }>>
  pushOp(clientOpId, op: Op): Promise<Result<{ version: number }>>
  snapshot(): Promise<Result<{ sheet: Sheet }>>
  on(handlers: { opApplied, participants, rejoined })
  leave(): void
}
interface ConversationTransport { join, sendMessage, cancel, openSheet, on(...), leave }
```

- **Replies:** each push resolves to the existing `Result` shape
  (`{ok, data} | {ok: false, error}`), like `lib/api.ts`. A push
  **timeout** of 10 s resolves to `{ok: false, error: {code: 'timeout'}}`.
- **Rejoin:** when Phoenix rejoins after a reconnect, the join reply is
  delivered as a `rejoined` event carrying the fresh snapshot (contract
  §4).

## 6. Sheet state

### 6.1 Data held per open sheet (`stores/sheets.ts`)

```ts
interface SheetEntry {
  confirmed: SheetState        // last server-confirmed state + version
  pending: PendingOp[]         // { clientOpId, op, sentAt }, in send order
  view: SheetState             // computed: pending ops replayed over confirmed
  participants: UserRef[]
  cues: Map<cellKey, { actor: Actor; at: number }>   // flash + "changed by" markers
  lastChange: { actor: Actor; at: number } | null
  status: 'joining' | 'ready' | 'resyncing' | 'error'
}
```

- **`SheetState` shape:**
  - `columns` is an ordered array plus a `columnsById` map.
  - `rows` is an ordered array of `{id, cells}` objects plus a `rowIndexById`
    map.
  - `version`.
- **Row identity:**
  - A changed row gets a **new object**, and every unchanged row keeps its
    old object.
  - The `rows` array itself is replaced on every change, so TanStack's
    shallow `data` watch fires.
  - Unchanged row objects keep Vue's per-row render work low.

### 6.2 Consistency rules (contract §5.4)

These live in `lib/sheet/consistency.ts` as a pure reducer with one case
per event. Each case updates the confirmed state, the pending list, or
both, and flags when a snapshot is needed:
- **`op_applied` with `version === confirmed.version + 1`:** apply it to
  `confirmed`. If it has a `client_op_id` matching an entry in `pending`,
  remove that entry. Record a cue for the touched cells unless the actor is
  the local user.
- **`version <= confirmed.version`:** ignore it.
- **`version > confirmed.version + 1`:** set `status: 'resyncing'` and
  request `snapshot`. The snapshot reply replaces `confirmed`. Pending ops
  are kept, because their replies or broadcasts are still coming.
- **An op rejected with an error:** remove it from `pending` and show a
  toast with `errors[0].message`. The preview disappears on the next
  `view` recompute.
- **A push `timeout`:** handled as a rejection, with the toast "Change may
  not have been saved".
- **`rejoined`:** replace `confirmed` and clear `pending`, because replies
  for ops sent before a disconnect never arrive. Show a toast if anything
  was pending.

**Client-generated ids.** `add_rows` and `add_column` always get a
`crypto.randomUUID()` id on the client. The preview and the confirmed
result therefore have identical ids, so the active cell and open tabs stay
put across confirmation.

### 6.3 `applyOp` and `values`

**`apply-op.ts`** implements all 10 op types from contract §6, and
returns a new `SheetState`. It's used for local previews and for confirmed
`AppliedOp`s.
- It assumes validity. Invalid local ops are caught earlier by `values.ts`
  and pre-send checks, and the server is authoritative anyway.
- For `change_column_type`, the preview converts values client-side. The
  confirmed `AppliedOp` then carries the server's converted `cells`.

**`values.ts`** handles each type:
- `parse(type, input: string)` returns `{ok, value} | {ok: false, message}`.
- `format(type, value, locale)` produces the display string.
- `validateLabel(label, rows)` checks that a label is non-empty and
  unique, ignoring case and trimmed.

Its rules mirror the server's `Values`: numbers accept the locale's
decimal separator, dates are ISO, and booleans accept true/false/yes/no/1/0.

### 6.4 Ref-counted channels

`useSheet(sheetId)` joins on first use and leaves when the last user
unmounts. So anything showing the same sheet in the SPA shares one
channel and one entry. `useConversation(id)` works the same way.

## 7. Grid

### 7.1 TanStack setup (`useSheetTable.ts`, v9 API)

```ts
const features = tableFeatures({                       // module scope: must be stable
  columnSizingFeature, columnResizingFeature, columnPinningFeature, rowSelectionFeature,
  columnMeta: metaHelper<{ column: Column }>(),
})
const table = useTable({
  features,
  data: rowsRef,                          // shallowRef<Row[]>: the ref itself, never .value
  columns: columnsRef,                    // computed from view.columns; rebuilt only when columns change
  getRowId: (r) => r.id,
  columnResizeMode: 'onChange',
  state: computed(() => ({ columnSizing, columnPinning, rowSelection })),
  onColumnSizingChange, onColumnPinningChange, onRowSelectionChange,
  autoResetAll: false,
})
```

- **Columns:**
  - A display column `__select` holds the row checkbox.
  - Then one accessor column per sheet column: `id` = column id,
    `accessorFn: r => r.cells[id]`, `meta.column`.
  - Cells render through `cell: ctx => h(SheetCell, {...})`.
  - `__select` and the label column are pinned with
    `columnPinning: { start: ['__select', labelColumnId], end: [] }`.
  - The column defs are rebuilt only when the columns array changes, which
    is a structure op, not a value edit.
- **Sizing:**
  - Widths are local to each user, saved in `localStorage` per sheet, and
    not synced.
  - Resize handles bind `header.getResizeHandler()` to `@mousedown` and
    `@touchstart`.
  - Widths are applied through CSS variables computed once per render, not
    by calling `getSize()` in every cell.
- **Row selection:** a `Record<rowId, true>`, used for "Delete selected
  rows".
- **Known cost:** replacing `data` rebuilds TanStack's Row objects, which
  is O(rows) per change. That's acceptable at POC sizes. Only the
  virtualized rows on screen re-render.

### 7.2 Layout and virtualization

- **Layout:** a div-based CSS grid, not `<table>`.
  - One scroll container. The header row is `position: sticky; top: 0`.
  - The pinned columns use `position: sticky` with
    `inset-inline-start: column.getStart('start')` and opaque backgrounds.
- **Rows:** `useVirtualizer` with `count = rows.length`, a fixed row height
  of 32 px, `overscan: 10`, and `getItemKey` = row id.
- **Keyboard:** navigation calls `scrollToIndex(i, { align: 'auto' })` so
  the active cell stays visible.
- **Columns:** not virtualized in the POC. The design leaves room to add a
  horizontal virtualizer for the centre columns later.
- **Bottom of the grid:** a `NewRowInput`. Typing a label and pressing
  Enter sends `add_rows`.

### 7.3 Cell registry and components

```ts
export const cellTypes: Record<ColumnType, CellTypeDef> = {
  text:    { display: TextDisplay,    editor: TextEditor,    align: 'start' },
  number:  { display: NumberDisplay,  editor: NumberEditor,  align: 'end'   },
  boolean: { display: BooleanDisplay, editor: null,          align: 'center' }, // toggles in place
  date:    { display: DateDisplay,    editor: DateEditor,    align: 'start' },
}
// the label column always uses LabelDisplay / LabelEditor
```

- **Display components** get `{ value, column, pending, cue }`. They
  render the formatted value, a pending style, a brief flash when changed
  remotely, and a "changed by X" marker (a `Tooltip`).
- **Editor components** get `{ initialValue, initialInput?, column }`
  (`initialInput` is set when editing started by typing a character). They
  emit `commit(value)` and `cancel()`. On an invalid value, the editor
  shows the `values.parse` message inline and stays open.
  - `TextEditor` and `LabelEditor`: `Input`. The label editor also runs
    `validateLabel`.
  - `NumberEditor`: `Input` with `values.parse('number')`.
  - `DateEditor`: `Popover` + `Calendar` using `@internationalized/date`.
  - `BooleanDisplay`: a `Checkbox`. A click, or Space on the active cell,
    sends `set_cells` directly.
- **`SheetCell`** chooses between the display and the editor. Only the
  active cell in edit mode mounts its editor.
- **Adding a new type** (currency, select…) means one registry entry and
  two components.

### 7.4 Navigation and editing (`useGridNavigation`)

**Active cell:** its own `ref<{ rowId, columnId } | null>`, keyed by
stable ids, so it survives remote inserts and moves.

**Navigating:**
| Key | Action |
|---|---|
| Arrow keys | Move the active cell |
| Tab / Shift+Tab | Move right or left |
| Home / End | First or last column |
| Ctrl+Home / Ctrl+End | First or last cell |

**Starting an edit:** Enter, F2, double-click, or typing a printable
character (which becomes the editor's `initialInput`).

**Inside an editor:**
| Key | Action |
|---|---|
| Enter | Commit and move down |
| Tab | Commit and move right |
| Escape | Cancel |

**Outside an editor:** Delete and Backspace clear the cell by sending
`set_cells` with a `null` value. The label column refuses this, because a
label is required.

**If the active row or column is deleted remotely:** the active cell moves
to the nearest remaining neighbour.

**Remote change to the cell being edited:** the editor stays open with
the user's input, and a "changed by X" marker appears. Committing is
last-write-wins. Escape shows the new server value.

**Copy and paste:**
- **Copy:** Ctrl+C copies the active cell's formatted value.
- **Paste:** Ctrl+V with no editor open parses clipboard `text/plain` as
  TSV. That's what Excel and Google Sheets put on the clipboard.
  - The block is laid out from the active cell. Each value goes through
    `values.parse` for its target column.
  - Cells beyond the last row or column, invalid values, and
    empty-to-label pastes are skipped, with a toast saying how many were
    skipped.
  - The valid cells are sent as **one** `set_cells` op, split into several
    if it exceeds `too_many_cells`.
- **Not in the POC:** range selection, fill and undo. v9's
  `cellSelectionFeature` (anchor/focus ranges) is the planned route for
  range selection later.

### 7.5 Structure operations (UI-6)

**Column header `DropdownMenu`:**
- Rename: inline input.
- Change type: a submenu of the four types. It is disabled for the label
  column.
- Insert column left or right: opens `AddColumnDialog`.
- Move left or right.
- Delete: needs confirmation, and is disabled for the label column.

**Row `ContextMenu`** (right-click on the row header or a cell):
- Insert row above or below: opens an inline label input.
- Move up or down.
- Delete row.
- Delete selected rows: available when a selection exists.

**`SheetToolbar`:**
- The sheet name, renamed inline with `rename_sheet`.
- An "Add column" button.
- `ParticipantAvatars`.
- The last change: "Updated by Alice · 2s ago".

**Moving by drag and drop** is a stretch goal. The menu actions cover the
requirement.

## 8. Chat

### 8.1 Data held per open conversation (`stores/conversations.ts`)

```ts
interface ConversationEntry {
  conversation: ConversationSummary
  messages: Message[]                       // upserted by id, in inserted_at order
  streamingText: string                     // from stream_delta; cleared on stream_reset
  toolStatus: Map<callId, ToolStatusEvent>  // live progress from tool_status
  status: 'not_started' | 'idle' | 'running' | 'cancelled' | 'error'
  error: string | null
  queued: { sender: UserRef; text: string }[]   // cleared when the next run starts
  linkedSheets: LinkedSheet[]
  participants: UserRef[]
}
```

It handles every server event in contract §7.3. `focus_sheet` is also
passed to `WorkspaceView` through a callback registered with
`useConversation`.

### 8.2 Rendering with AI Elements

AI Elements imports only types from the `ai` SDK, so we drive it with
plain props.

| Contract `Message` | Rendered as |
|---|---|
| `user` + `text` | `Message from="user"`, with the sender's name above it. The current user's messages align to the end; everyone else's align to the start with their name |
| `assistant` + `text` | `Message from="assistant"` → `MessageResponse :content` (markdown) |
| `assistant` + `thinking` | `Reasoning` / `ReasoningContent` |
| `tool_call` + matching `tool_result` | `ToolCallItem`: `Tool` + `ToolHeader :title="display_text" type="dynamic-tool" :tool-name="name" :state` + `ToolInput :input="arguments"` + `ToolOutput :output / :error-text` |
| `notification` / `error` | A small system line, styled as muted or destructive |
| `streamingText` | A temporary assistant `MessageResponse` at the end |

Contract tool status maps to the AI Elements `ToolUIPart['state']`:

| Contract | AI Elements state |
|---|---|
| `identified` | `input-streaming` |
| `executing` | `input-available` |
| `completed` | `output-available` |
| `failed`, or a result with `is_error` | `output-error` |

**Input:** `PromptInput` + `PromptInputTextarea` + `PromptInputSubmit`.
- **Submitting:** `@submit` sends `send_message`.
- **Submit-button status:** `running` maps to `'streaming'`, and clicking
  it sends `cancel`. Idle maps to `'ready'`.
- **Queued messages:** shown as pending bubbles with a "Queued" badge.
- **Header:** the conversation title and `ParticipantAvatars`.
- **Empty conversation:** `ConversationEmptyState` with a few `Suggestion`
  chips ("Create a monthly budget sheet"…).

### 8.3 What F5 settled

F6 was folded in: the backend reached M3 before F5 started, so the AI emits tool
calls and `focus_sheet` the moment chat works at all.

- **A queued message arrives twice, so "pending bubbles" would double it.** The
  server stores the display message *and* broadcasts `message_queued`
  (`conversation_events.ex`, `{:message_queued, _}`), so §8.1's
  `queued: {sender, text}[]` rendered as its own bubble would show every queued
  message a second time. Queued-ness is therefore a **badge on the stored
  message**, matched on `sender.id` plus the trimmed text — the notice carries no
  id, and the server strips the `"[Name]: "` prefix. The two race, so the reducer
  matches in both directions and parks an unmatched notice in `pendingQueued`.
  Verified live: one bubble, one badge.
- **Marks clear on the next `status` event of any kind.** The server pushes
  `status` only when it changes, so any status means the run boundary moved and
  nothing marked before it is still waiting. That holds whether Sagents goes
  `running → idle` first or steps straight into the queued turn — which
  "clear when the next run starts" would have missed.
- **The push is `status`, not `agent_status`**, it carries `error: string | null`,
  and `not_started` appears only in the join reply.
- **`inserted_at` is not a sort key.** Parts of one assistant turn share a
  timestamp and the `sequence` that orders them is not serialized, so messages
  are kept in **arrival order** and upserted by `id` in place. Upserting is
  required, not an optimization: the channel re-pushes every stored message from
  `last_message_at` on when a pending agent subscription is revived.
- **No optimistic echo is possible.** `send_message` replies `{}` and the message
  returns with a server id; contract §7.2 has no `client_op_id` analogue, so a
  preview could never be reconciled. The input clears on send and the bubble
  appears on the round trip.
- **The stop control is its own button, not `PromptInputSubmit status`.** Enter
  in the textarea always submits the form, so a stop-on-submit would make Enter
  *cancel* the turn instead of queueing the message — the opposite of CS-4.
- **`focus_sheet` is a field on the entry, not a callback.** §8.1 sketched a
  callback registered with `useConversation`; a `focusRequest {sheetId, reason,
  seq}` keeps the reducer the only place state changes, is testable without a
  component, and avoids deciding whose callback wins when a ref-counted entry has
  several holders. `seq` is what makes two requests for the same sheet fire the
  watcher twice.
- **Reopening a conversation opens its most recent linked sheet.** `focus_sheet`
  is live-only, so a session whose sheets the AI built in an earlier visit would
  otherwise show an empty panel. The bootstrap runs only when nothing is stored:
  once the user has tabs of their own, or has closed them all, that is their
  choice.
- **`open_sheet` moves only your own tab.** The server links the sheet and
  broadcasts `sheets` to everyone but deliberately sends no `focus_sheet`.
- **Unknown `content_type`s survive.** `MessageJSON` whitelists six types and
  passes anything else through raw, so `ChatMessage` reads `content.text`
  defensively rather than dropping the message.
- **`SheetPane` exists because `useSheet()` cannot be called in a `v-for`.** Each
  tab needs its own ref-counted hold, so each is its own component; `SheetView`
  now renders the same component, and panes are hidden with `v-show` so a tab
  switch keeps scroll position and the active cell.
- **The conversation mock was never written**, exactly as §9's note predicted:
  the backend passed M2 and M3 first, so `transport/mock/index.ts` stays a
  skeleton that satisfies the interface.

## 9. Mock backend (parallel development)

`transport/mock/` is enabled with `VITE_MOCK_BACKEND=1`. It's an
in-memory "server" that satisfies the same interfaces:

- **Sheets:**
  - It reuses `apply-op.ts` plus a small validation layer that produces
    the contract error codes.
  - It assigns versions and broadcasts `op_applied` to every mock
    subscriber in the same browser window. The mock lives in memory, so it
    can't sync separate browser windows; that's what the real backend is
    for.
  - A "simulate remote user" dev control applies random edits, to test
    cues and conflicts.
- **Conversations:** a scripted agent.
  - It echoes the user message and streams a canned reply in
    `stream_delta` chunks.
  - For prompts starting with `/demo`, it runs a scripted tool sequence
    (create a sheet, add rows, set cells). That sequence sends
    `tool_status`, `focus_sheet` and `sheets` events, and changes mock
    sheets.
- **REST:** the mock also provides the list, show and create endpoints.

The mock is dev-only and tree-shaken out of production builds. It's
retired feature by feature at M1, M2 and M3.

> **Superseded for sheets (2026-09-20).** The backend reached M1 and M2 before
> F2 started, so by the rule above the sheet mock was already retired before it
> was ever written. F2 therefore ships **no working mock sheet server**: the
> store talks to the real `sheet:<id>` channel, and the pure core is tested on
> plain data, which needs no transport at all. Building it would have meant
> porting the server's ~500 lines of op validation to TypeScript as throwaway
> code and re-opening the §12 drift risk. The skeleton in
> `transport/mock/index.ts` still satisfies both interfaces, so the seam
> survives if an offline mode is ever wanted. The conversation mock is in the
> same position for F5.

## 10. Testing

Vitest with happy-dom. The tests focus on the pure core:
- `apply-op.test.ts`: every op type, including positions, label renames and
  type changes.
- `values.test.ts`: parse, format and validate for every type and edge
  case.
- `consistency.test.ts`:
  - applying in order
  - ignoring stale events
  - gap → resync
  - preview reconciled by `client_op_id`
  - rejection and timeout rollback
  - `rejoined`
- `paste.test.ts`: TSV parsing, bounds, invalid-value skipping, chunking.
- Conversation reducer: stream, reset, message upsert, tool status,
  queued messages, focus.
- Component tests (`@vue/test-utils`):
  - each editor's commit and cancel;
  - `SheetCell` switching between display and editor;
  - `useGridNavigation` key handling.
- End-to-end is manual in the POC: two browsers against the real backend
  in phase F7. Playwright can come later.

## 11. Phases

Each phase ends with `pnpm type-check`, `pnpm lint` and `pnpm test`
green.

| Done | Phase | Deliverables | Done when | Backend dependency |
|---|---|---|---|---|
| [x] | **F1. Foundations** | Dependencies, Vitest, `types/contract.ts`, `AppLayout` + routes, socket and transport interfaces, mock skeleton | The shell navigates between the empty views. The socket connects against the backend's Phase 1, or the mock | none (mock) |
| [x] | **F2. Sheet state core** | `apply-op`, `values`, `consistency`, `stores/sheets`, `useSheet` (mock sheet server dropped — see §9) | Unit tests cover contract §5.4 and §6 | none |
| [x] | **F3. Read-only grid** | `useSheetTable`, `SheetGrid` (virtualized, sticky header and label), display cells, `SheetsView` + create dialog, `SheetView` | A 1,000 × 30 sheet from `dev/sheets.exs` scrolls smoothly. Participants and cues render from real `op_applied` events | none (uses the live backend) |
| [x] | **F4. Editing** | Navigation, editors, local preview, rollback, structure menus, new row, delete, move, copy/paste, toolbar | Every op in §4.2 can be done from the UI. Two browser windows stay in sync, and an open editor survives a remote change to its own cell | none (uses the live backend) |
| [x] | **F5. Chat** | `stores/conversations`, `ChatPanel`, message rendering, `ConversationsView`, `WorkspaceView` with the split pane and sheet tabs | Chat works against the real backend: send, stream, cancel, queued messages | **M2** |
| [x] | **F6. AI integration** | `focus_sheet` → sheet tabs, linked sheets list, `OpenSheetDialog`, tool call rendering | **Folded into F5** (see §8.3): the backend was already at M3, so shipping chat without tool rendering or `focus_sheet` would have meant a placeholder thrown away days later | **M3** |
| [ ] | **F7. Polish** | Empty and error states, reconnect indicator, a two-browser manual run, docs | The requirements §1 questions are demonstrable end to end | M3 |

### 7.6 What F3 settled

- **The v9 names in §7.1 are right**, checked against the installed 9.2.4:
  `tableFeatures`, `useTable`, `metaHelper`, `columnSizingFeature` +
  `columnResizingFeature` (both needed for interactive resizing),
  `columnPinningFeature`, `rowSelectionFeature`,
  `column.getStart('start')` and `header.getResizeHandler()`. Two things the
  plan didn't say: `useTable` needs its generics given explicitly
  (`useTable<SheetFeatures, Row>`), because `TData` doesn't infer through a
  computed `columns`; and the package ships its own docs in
  `node_modules/@tanstack/vue-table/skills/*/SKILL.md`, which are the
  reference to use.
- **Cues and pending state reach cells through `provide`/`inject`**
  (`components/sheet/context.ts`), not through the TanStack cell context.
  A cell looks up only its own `cellKey`, so one remote change re-renders
  one cell instead of every visible row.
- **One clock per grid.** Cue markers expire 30 s after the change, driven
  by a single 5 s interval in `SheetGrid`. The 1.5 s flash reads
  `Date.now()` once per cue, so a row scrolled back into view doesn't
  replay an old flash.
- **`--grid-cols` on the scroll container.** Every row is a CSS grid using
  that one variable, so a resize restyles one property rather than each
  cell. Header and body render pinned columns first
  (`getStartLeafHeaders` / `row.getStartVisibleCells()`), which keeps cell
  order and the template in step.
- **A failed join is a state, not a toast.** `stores/sheets.ts` keeps the
  entry with `status: 'error'` and the error, so `SheetView` can show
  "Sheet not found" instead of spinning forever.
- **`dev/sheets.exs`** replaces the two mock affordances F3 needed: a big
  sheet (`Dev.Sheets.big_sheet/3`) and a simulated remote user
  (`Dev.Sheets.simulate_edits/4`). Load it with `c "dev/sheets.exs"` from
  `iex -S mix phx.server`, so the ops run in the server's own VM and
  broadcast to connected browsers.

### 7.7 What F4 settled

- **Focus lives on the scroll container, never on a cell.** A roving
  `tabindex` cannot survive virtualization: when the focused cell scrolls out
  of the overscan band its element is removed, focus silently falls to
  `<body>`, and the grid goes dead with nothing on screen to explain it. The
  container is never unmounted, so `document.activeElement` is invariant —
  which also makes it the reliable target for `copy` and `paste`. The active
  cell is named by `aria-activedescendant` instead, pointing at a **static**
  id on the `role="gridcell"` div, so rows gain no reactive dependency on it.
- **The active row is pinned into the virtual range** through the
  virtualizer's `rangeExtractor`. Without it, scrolling away from an open
  editor would unmount it and throw away the user's draft. Verified: with the
  editor open, `scrollTop = 20000` on the 1,000-row sheet kept the editor and
  its text, and the DOM still held only 56 rows.
- **Editors emit their raw string, not a parsed value** — a correction to
  §7.3. `LabelEditor` was specified to run `validateLabel`, which needs the
  whole `SheetState` that an editor's props don't carry. Parsing and the label
  check therefore happen in one place, `useGridNavigation.commit`, and paste
  goes through the identical path.
- **A bare `<input>`, not the shadcn `Input`** — also a §7.3 correction. Its
  height exceeds `ROW_HEIGHT` (32) and would break row alignment, the same
  reason `BooleanDisplay` is not the shadcn `Checkbox`.
- **The editor is inline in `SheetCell`**, swapping only the inner component.
  A grid-level overlay would have to re-derive `--grid-cols` widths on every
  resize, could not be `position: sticky` for the pinned label column (the
  most common edit), would have to mirror the row's `translateY`, and would
  cover the cue marker that §7.4 requires to appear *over* an open editor.
- **`Ctrl/Cmd+C/V/X` are never `preventDefault`ed.** Swallowing them
  suppresses the browser's own `copy`/`paste` events, which is how the
  clipboard is read — `gridIntent` returns an explicit `native` for them so it
  stays deliberate. `ClipboardEvent.clipboardData` is used rather than
  `navigator.clipboard`, whose `readText()` is unavailable to page script in
  Firefox and permission-gated in Chrome.
- **Paste decides label uniqueness over the whole block.** The server checks
  labels on their *final* values, so rows may swap them in one op; a one-pass
  planner would reject a legal swap. Invalid values, out-of-bounds cells and
  unusable labels are skipped rather than failing the op, because the server
  applies an op all-or-nothing and one bad cell would discard the rest.
- **Navigation follows visual order, not `view.columns`.** The label column is
  pinned and renders first whatever its position, so Tab and Home use
  `navColumnIds` derived from the table's headers.
- **`dev/sheets.exs` again stood in for the mock.** F4's "done when"
  originally named the mock's simulated remote user; two browser tabs against
  the real backend cover it, and confirmed the §7.4 rule directly: an edit
  from the second tab landed while the first tab's open editor kept its own
  draft, and committing it was last-write-wins.

## 12. Risks

| Risk | Mitigation |
|---|---|
| TanStack v9 is new, and most online examples are v8 | This plan uses only APIs verified in the 9.2.4 package. Stick to the shipped `skills/*/SKILL.md` docs |
| Rebuilding TanStack rows on every op is O(rows) | Fine at POC sizes. If profiling shows a problem, give the grid a custom row model or skip TanStack's row model for the body |
| Reading `table.getRowModel()` right after replacing `data` is stale until the next tick | Read through `computed`s and templates, not synchronously after a write. Use `await nextTick()` where an imperative read is needed |
| The mock and the backend drift apart | Both follow `contract.md`. The shared `types/contract.ts` and the reuse of `apply-op` keep the mock honest. Retire it at each milestone |
| Keyboard, virtualization and sticky layout interact in subtle ways | Build the grid on its own in F3 and F4, with `SheetView` as a harness, before adding chat. F3 verified virtualization (65 of 1,000 rows in the DOM), sticky header and pinned columns against the real backend |
