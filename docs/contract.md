# SpreadSheetAi POC — Frontend/Backend Contract

Status: draft for review · Date: 2026-09-19 · Implements: [requirements.md](requirements.md)

This is the only interface between the Vue SPA and the Phoenix backend.
The two sides are built in parallel against this document. Any change to
it must be agreed and made here first.

> **Naming:** the requirements say *table*. The API and code say **sheet**,
> so it isn't confused with Postgres tables or `<table>` elements. A
> *conversation* is a requirements *chat session*.

## 1. Conventions

- **JSON keys** are `snake_case`.
- **IDs** are UUID strings. Timestamps are ISO 8601 UTC strings.
- **REST** is served under `/api`. Every endpoint below requires the
  existing auth cookie; without it the server returns `401 unauthenticated`.
  Mutating requests send `X-CSRF-Token` (see `frontend/src/lib/api.ts`).
- **REST success bodies** use a resource-named top-level key
  (`{"sheet": ...}`, `{"sheets": [...]}`). They are not wrapped in `data`.
- **Errors**, both REST and channel replies, use the app's standard
  envelope:

  ```json
  { "errors": [ { "code": "unknown_column", "message": "Column 'Q3' does not exist", "field": null, "meta": {} } ] }
  ```

  `code` is stable and used in code. `message` is for people. §8 lists the
  codes.

## 2. Shared shapes

### 2.1 `UserRef`

```json
{ "id": "uuid", "display_name": "Alice" }
```

`display_name` falls back to the user's email when it is not set.

### 2.2 Cell values and column types

| `column_type` | JSON value | Notes |
|---|---|---|
| `text` | string | |
| `number` | number | A JSON number (double precision). |
| `boolean` | `true` / `false` | |
| `date` | string `"YYYY-MM-DD"` | |

`null` means an empty cell in any column type. The label column is always
`text` and never `null`.

### 2.3 `Column`

```json
{ "id": "uuid", "name": "Q1", "column_type": "number", "is_label": false }
```

Columns are listed in display order. Position is the index in the array.

### 2.4 `Row`

```json
{ "id": "uuid", "cells": { "<column_id>": "Revenue", "<column_id>": 1200 } }
```

- `cells` includes the label column's value.
- Keys for empty cells may be missing. A missing key and `null` mean the
  same thing.
- Rows are listed in display order. Position is the index in the array.

### 2.5 `SheetSummary`

```json
{
  "id": "uuid",
  "name": "P&L 2026",
  "owner": { "id": "uuid", "display_name": "Alice" },
  "row_count": 12,
  "column_count": 5,
  "version": 37,
  "inserted_at": "2026-09-19T10:00:00Z",
  "updated_at": "2026-09-19T10:05:00Z"
}
```

### 2.6 `Sheet` (full snapshot)

```json
{
  "id": "uuid",
  "name": "P&L 2026",
  "owner": { "id": "uuid", "display_name": "Alice" },
  "version": 37,
  "columns": [ Column ],
  "rows": [ Row ],
  "inserted_at": "…",
  "updated_at": "…"
}
```

### 2.7 `Actor`: who made a change

```json
{ "type": "user", "user": UserRef }
{ "type": "agent", "conversation_id": "uuid", "conversation_title": "Budget planning" }
```

### 2.8 `ConversationSummary`

```json
{
  "id": "uuid",
  "title": "Budget planning",
  "created_by": UserRef,
  "inserted_at": "…",
  "updated_at": "…"
}
```

`title` is `null` until it is generated.

### 2.9 `LinkedSheet`: a sheet used in a conversation

```json
{
  "sheet": SheetSummary,
  "created_here": true,
  "last_access": "written",
  "first_accessed_at": "…",
  "last_accessed_at": "…"
}
```

`last_access` is one of `created`, `opened`, `read` or `written`.

### 2.10 `Message`: one displayable chat item

```json
{
  "id": "uuid",
  "role": "user",
  "content_type": "text",
  "content": { "text": "Add a Q3 column" },
  "sender": UserRef,
  "status": "completed",
  "inserted_at": "…"
}
```

- `role` is `user`, `assistant` or `tool`.
- `sender` is set for `user` messages and `null` otherwise.
- `status` is `completed`, `pending`, `executing`, `failed` or
  `cancelled`.
- `content_type` decides the shape of `content`:

| `content_type` | `content` |
|---|---|
| `text` | `{ "text": string }` |
| `thinking` | `{ "text": string }` |
| `tool_call` | `{ "call_id": string, "name": string, "display_text": string, "arguments": object }` |
| `tool_result` | `{ "tool_call_id": string, "name": string, "content": string, "is_error": boolean }` |
| `notification` | `{ "text": string, "stop_reason": "cancelled" }` |
| `error` | `{ "text": string, "error_type": string \| null }` |

`content` may also include `stop_reason` (`length`, `cancelled`,
`content_filtered` or `stream_error`) on the last item of a message that did
not finish. Render a marker when it is present.

## 3. REST endpoints

| Method & path | Body | Success |
|---|---|---|
| `GET /api/socket_token` | — | `200 {"token": string}` (see §4) |
| `GET /api/sheets` | — | `200 {"sheets": [SheetSummary]}`, newest `updated_at` first |
| `GET /api/sheets/:id` | — | `200 {"sheet": Sheet}` · `404 not_found` |
| `POST /api/sheets` | `{"name": string, "label_column_name": string?, "columns": [{"name", "column_type"}]?}` | `201 {"sheet": Sheet}` · `422` |
| `GET /api/conversations` | — | `200 {"conversations": [ConversationSummary]}`, newest first |
| `POST /api/conversations` | `{}` | `201 {"conversation": ConversationSummary}` |
| `GET /api/conversations/:id` | — | `200 {"conversation": ConversationSummary}` · `404` |

- `label_column_name` defaults to `"Line item"`.
- Every signed-in user can see and use every sheet and every conversation.
- A sheet's contents, a conversation's messages and all changes arrive over
  the channels in §4–§6. REST is for lists, creating things, and the first
  load of a page.

## 4. Socket

- **Endpoint:** `/socket`, via the `phoenix` JS client.
- **Authentication:** WebSockets can't use the HttpOnly auth cookie
  directly. The client first calls `GET /api/socket_token` (§3), which is
  authenticated by the cookie as usual. It then connects with that token:

  ```ts
  new Socket('/socket', { authToken: () => currentToken })
  ```

  The token travels in the `Sec-WebSocket-Protocol` header (Phoenix
  `auth_token`), not in the URL.
- **Token expiry:** a token is valid for 24 hours, and only for opening a
  connection. An open socket stays connected after its token expires. If a
  connection or reconnection is refused, fetch a fresh token, update
  `currentToken`, and let the client reconnect. If `/api/socket_token`
  itself returns `401`, the user is signed out.
- **Reconnects:** the client rejoins its channels on reconnect. After a
  rejoin, sheet state is replaced by the new snapshot (§5.1).

## 5. Channel `sheet:<sheet_id>`

### 5.1 Join

- **Join reply:** `{"sheet": Sheet}`. Error: `{"errors": [...]}`, where
  `not_found` means the sheet doesn't exist.
- **After joining:** the client holds the sheet at `sheet.version` and
  applies `op_applied` events in order (§5.3).

### 5.2 Client → server

| Event | Payload | Reply |
|---|---|---|
| `op` | `{"client_op_id": "uuid", "op": Op}` | ok `{"version": int}` · error `{"errors": [...]}` |
| `snapshot` | `{}` | ok `{"sheet": Sheet}` |

### 5.3 Server → client

| Event | Payload |
|---|---|
| `op_applied` | `{"version": int, "op": AppliedOp, "actor": Actor, "client_op_id": "uuid" \| null}` |
| `participants` | `{"users": [UserRef]}` is the full list of current viewers. It is sent after join and whenever the list changes. |

### 5.4 Client consistency rules (requirements RT-4 to RT-6)

1. **Apply in order.** Apply `op_applied` only when
   `version == local_version + 1`. Ignore events with
   `version <= local_version`.
2. **Gap.** If `version > local_version + 1`, discard local state, request
   `snapshot`, and replace everything with the reply.
3. **Local preview.** For a local edit, generate `client_op_id`, apply the
   op to a preview layer at once, and push `op`. When the `op_applied`
   arrives with the same `client_op_id`, drop the preview and apply the
   server's `AppliedOp` to confirmed state. If the reply is an error, drop
   the preview and show `errors[0].message`.
4. **Server wins.** What is shown is confirmed state with pending previews
   on top. Pending previews that touch cells changed by someone else's
   `op_applied` are kept until their own confirmation or error arrives.
   After that, the server's value stands.

## 6. Operations

`Op` is what the client sends. `AppliedOp` is what the server broadcasts:
the same op, normalized with every id filled in and values in their stored
types. All references use ids. The AI's tools use names, and the server
converts them to ids before applying and broadcasting.

New rows and columns may carry a client-generated `id` (UUID v4). The
client can then match its local preview to the confirmed result. If `id` is
missing, the server generates one. An id that is already in use is
rejected with `invalid_op`.

| `type` | `Op` fields | `AppliedOp` adds or changes |
|---|---|---|
| `rename_sheet` | `name` | — |
| `add_column` | `id?`, `name`, `column_type`, `position?` (the default is the end) | `id` and `position` are always present |
| `rename_column` | `column_id`, `name` | — |
| `change_column_type` | `column_id`, `column_type` | `cells: [{row_id, value}]`, the converted values |
| `move_column` | `column_id`, `position` | — |
| `delete_column` | `column_id` | — |
| `add_rows` | `rows: [{id?, cells: {column_id: value}}]`, `position?` (the default is the end) | every row has an `id`, and `position` is the index of the first new row |
| `delete_rows` | `row_ids: [uuid]` | — |
| `move_row` | `row_id`, `position` | — |
| `set_cells` | `cells: [{row_id, column_id, value}]` | values in their stored types |

Rules the server enforces. Each violation rejects the whole op, with the
code shown:

- **Unknown ids:** a `column_id` or `row_id` that doesn't exist →
  `unknown_column` or `unknown_row`.
- **Column names:** unique within a sheet, ignoring case and trimmed →
  `duplicate_column_name`.
- **Row labels:** each row must have a non-empty label in the label column
  → `label_required`. Labels are unique within a sheet, ignoring case and
  trimmed → `duplicate_label`. Setting a label cell renames the row.
- **Label column:** it cannot be deleted or have its type changed →
  `label_column_protected`.
- **Values:** each value must match its column type → `invalid_value`, with
  `meta: {row_id, column_id}`.
- **Type changes:** `change_column_type` fails if any existing value can't be
  converted → `type_conversion_failed`, with `meta: {row_id}` for the first
  failure.
- **Size caps:** `add_rows` and `set_cells` over the configured cap →
  `too_many_cells`, with `meta: {max}`.
- **Positions:** a position outside `0..length` → `invalid_position`.

Clarifications (how the server applies the rules above):

- **Trimming.** Sheet names, column names and labels are stored trimmed.
  A blank name is `invalid_op`; a blank label is `label_required`.
- **Positions.** For `add_column` and `add_rows` the position is where the
  first new item lands, in `0..length`. For `move_column` and `move_row` it
  is the item's final index after the move, in `0..length-1`. The label
  column can be moved like any other column.
- **Stored values.** A `""` text value is stored as `null` (an empty cell).
  Whole-number floats are stored as integers (`12.0` → `12`). Dates are
  `"YYYY-MM-DD"` strings. `AppliedOp` carries these stored forms.
- **Duplicates inside one op** are `invalid_op`: the same row twice in
  `delete_rows`, or the same cell twice in `set_cells`. Two rows with the
  same label in one `add_rows` is `duplicate_label`.
- **No-op ops** are accepted and still bump the version, for example moving
  to the current position or changing a column to its current type.
- **Label swaps.** In `set_cells`, labels are checked on their final values,
  so two rows can swap labels in one op.
- **`change_column_type` cells** list every row that had a value, with its
  converted value. A value that converts to empty (blank text) is `null`.

## 7. Channel `conversation:<conversation_id>`

### 7.1 Join

Join reply:

```json
{
  "conversation": ConversationSummary,
  "messages": [Message],
  "sheets": [LinkedSheet],
  "status": "idle"
}
```

- `messages` is oldest first.
- `status` is one of `idle`, `running`, `cancelled`, `error` or
  `not_started`. `not_started` means no agent process is running; one
  starts on the first message.

### 7.2 Client → server

| Event | Payload | Reply |
|---|---|---|
| `send_message` | `{"text": string}` | ok `{}`. The message itself comes back as a `message` event. |
| `cancel` | `{}` | ok `{}` · error `not_running` |
| `open_sheet` | `{"sheet_id": uuid}` | ok `{"sheet": LinkedSheet}`. This links a sheet a user opened (ST-2). It does not send `focus_sheet`. |

### 7.3 Server → client

| Event | Payload | Meaning |
|---|---|---|
| `message` | `{"message": Message}` | A stored message, from a user or the AI, or a tool call or result. Add it, or replace an existing one with the same `id`. |
| `message_updated` | `{"message": Message}` | An existing message changed, for example a tool call finished. Replace it by `id`. |
| `stream_delta` | `{"text": string}` | Text the AI is generating right now. Append it to a temporary "streaming" bubble. |
| `stream_reset` | `{}` | The streamed text is now stored and will arrive as `message` events. Clear the streaming bubble. |
| `tool_status` | `{"call_id", "name", "display_text", "status": "identified" \| "executing" \| "completed" \| "failed"}` | Live progress of a tool call. |
| `status` | `{"status": "idle" \| "running" \| "cancelled" \| "error", "error": string \| null}` | Agent status. |
| `message_queued` | `{"sender": UserRef, "text": string}` | A message arrived while the AI was busy. It is handled when the current turn finishes. |
| `title` | `{"title": string}` | The conversation title was generated or changed. |
| `sheets` | `{"sheets": [LinkedSheet]}` | The full list of linked sheets, sent whenever it changes. |
| `focus_sheet` | `{"sheet_id": uuid, "reason": "created" \| "opened" \| "read" \| "written"}` | The AI touched this sheet. Open its tab if needed and make it active (UI-4). |
| `participants` | `{"users": [UserRef]}` | The full list of current viewers. It is sent after join and on every change. |

Ordering: `focus_sheet` for a write is sent before the tool's result
message. The resulting `op_applied` arrives on the `sheet:<id>` channel.
Neither channel guarantees ordering relative to the other.

## 8. Error codes

| Code | Where |
|---|---|
| `unauthenticated` | REST 401 or socket refused |
| `not_found` | REST 404, or a join to a missing sheet or conversation |
| `validation_failed` | REST 422, field errors on create |
| `invalid_op` | An op payload is malformed or has an unknown `type` |
| `unknown_column`, `unknown_row` | An op references a missing id |
| `duplicate_column_name`, `duplicate_label`, `label_required` | Naming rules |
| `label_column_protected` | Deleting or retyping the label column |
| `invalid_value`, `type_conversion_failed` | Value rules |
| `invalid_position` | A position is out of range |
| `too_many_cells` | Over the size cap for one request |
| `not_running` | `cancel` while the agent is idle |
| `internal_error` | Anything unexpected. The client should resync (`snapshot`). |
