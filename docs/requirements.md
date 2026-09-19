# SpreadSheetAi POC — Requirements

Status: draft for review · Date: 2026-09-19

## 1. Purpose

Prove that an AI copilot can create and work with tabular spreadsheets, that
those tables can live in Elixir processes, and that every change made by the
AI or a human reaches every connected user in real time.

The POC answers four questions:

1. Can an AI agent reliably create tables and change their structure and
   values through tools?
2. Can tables be held in memory, with Postgres as the durable copy, and be
   rebuilt from Postgres after a crash or restart?
3. Can every change reach every connected UI over WebSockets, in order and
   consistently?
4. Can several users work on the same tables, and in the same chat
   sessions, at the same time?

## 2. Scope

### In scope

- Tables with typed columns, holding literal values only
- An AI copilot, driven by chat, that can list, open, create, read and change
  tables
- Humans can do everything the AI can do, directly from the UI
- Real-time, multi-user collaboration on tables and on chat sessions
- Postgres persistence for table structure, table data, chat history, and
  the links between chat sessions and tables
- Recovery from process and node restarts using Postgres

### Out of scope (future work)

- Formulas and computed values
- Importing or exporting XLS/CSV; Google Sheets and other external sources
- SQL or any other query interface
- Authorization: every signed-in user can see and change everything
- Deleting tables
- Undo/redo
- Running on more than one node, or sharing tables across nodes

## 3. Glossary

| Term | Meaning |
|---|---|
| Table | A named grid of columns and rows (line items). It has an owner and a version. |
| Line item | A row. It is identified by its label: its value in the table's line-item column. |
| Line-item column | The one required column on every table whose value names each row, such as "Revenue" or "COGS". |
| Operation | A single atomic change to a table, such as "add column" or "set cells". |
| Version | An integer on each table that goes up by one for every applied operation. |
| Chat session | A conversation with one AI agent, shared by any number of users. |
| Session table | A table linked to a chat session because it was created, opened, read or written in that session. |
| Actor | Who made a change: a user directly, or the AI on behalf of a chat session. |

## 4. Functional requirements

### 4.1 Tables

- **T-1** A table has a name, an owner (the user who created it, or the user
  whose chat session created it), a version, and timestamps. Names do not
  have to be unique.
- **T-2** A table has an ordered list of columns. Each column has a stable
  internal id, a name that is unique within the table, a type, and a
  position.
- **T-3** Column types are `text`, `number`, `boolean` and `date`. Cells hold
  literal values of their column's type, or are empty (null).
- **T-4** Every table has exactly one line-item column, of type `text`. It is
  created with the table and cannot be deleted or have its type changed.
- **T-5** Line-item labels are required (not empty) and unique within a
  table. Leading and trailing whitespace is trimmed, and uniqueness ignores
  case.
- **T-6** Rows have a stable internal id and a position. Humans and the AI
  refer to rows by their line-item label and to columns by name. Internal
  ids keep references working when rows or columns are renamed or
  reordered.
- **T-7** Tables have no fixed size limit. Instead, each request is capped:
  a single read returns at most a configurable page of rows, and a single
  `set_cells` / `add_rows` operation accepts at most a configurable number
  of cells or rows. Operations over the cap are rejected with an error, and
  the AI is expected to split the work across several calls.

### 4.2 Operations

Every change to a table, from the AI or a human, is one of these operations.
The same set is used for AI tools, UI actions and the real-time protocol.

| Operation | Effect |
|---|---|
| `create_table` | Create a table with a name, a line-item column name, optional extra columns, and optional initial rows. |
| `rename_table` | Change the table name. |
| `add_column` | Add a column with a name, a type, and an optional position (the default is last). |
| `rename_column` | Rename a column. |
| `change_column_type` | Change a column's type. The operation is rejected if any existing value cannot be converted. |
| `move_column` | Move a column to a new position. |
| `delete_column` | Remove a column and its values. The line-item column cannot be deleted. |
| `add_rows` | Add one or more rows with labels and optional values, at an optional position (the default is the end). |
| `delete_rows` | Remove one or more rows, identified by label. |
| `move_row` | Move a row to a new position. |
| `set_cells` | Set one or more cells in one operation, each identified by row label and column name. Setting a line-item cell renames that row. An empty value clears the cell. |

- **OP-1** Each operation is atomic: it is applied in full or rejected in
  full.
- **OP-2** A rejected operation returns a clear, specific error, for example
  "column 'Q3' does not exist" or "label 'Revenue' already used". The table
  and its version are unchanged.
- **OP-3** Each applied operation increases the table version by exactly one.
- **OP-4** Operations on one table are applied one at a time, in the order
  the table's process receives them. When two changes hit the same cell, the
  last one wins.

### 4.3 Real-time collaboration

- **RT-1** Any number of users can view and change the same table at the
  same time.
- **RT-2** Every applied operation is broadcast over WebSockets to every
  client viewing that table. The broadcast includes the new version, the
  actor, and the originating client operation id, if there is one.
- **RT-3** A client that joins a table receives a full snapshot of the table
  and its current version.
- **RT-4** Clients apply broadcasts in version order. A client that detects
  a gap in versions discards its local state and reloads a full snapshot. It
  does not replay the missed operations.
- **RT-5** Human edits appear in the UI immediately (a local preview) and are
  sent with a client-generated operation id. When the broadcast carrying that
  id arrives, the server's result replaces the local preview. If the
  operation is rejected, the preview is rolled back and the user sees the
  error.
- **RT-6** The server's state always wins: after all operations are
  confirmed, every client shows the same data.
- **RT-7** Clients show who is currently viewing each table (presence).
- **RT-8** Changes show who made them. At minimum, the most recent change is
  attributed ("AI in session X" or "Alice"), and changed cells are briefly
  highlighted.

### 4.4 Chat sessions

- **CS-1** Chat sessions are shared. Any signed-in user can list, open and
  take part in any chat session. A session records the user who created it.
- **CS-2** Several users can chat with the same AI agent in one session at
  the same time. Every participant sees every message and every streamed AI
  response in real time.
- **CS-3** Each user message records its sender. The sender's display name
  is included in what the model sees, so the AI knows who is speaking.
- **CS-4** If a user sends a message while the AI is still responding, the
  message is queued and handled when the current AI turn finishes. The UI
  shows that the message is queued.
- **CS-5** Any participant can stop the AI's current turn.
- **CS-6** Chat history is stored in Postgres and fully restored when a
  session is reopened.
- **CS-7** Sessions show who is currently viewing them (presence).
- **CS-8** Sessions get a readable title, generated automatically from the
  conversation.

### 4.5 Links between sessions and tables

- **ST-1** The system records which tables were used in each chat session,
  and how: created, opened, read or written, with first and last access
  times.
- **ST-2** A table is linked to a session when the AI creates, opens, reads
  or writes it in that session, or when a user opens it from that session.
- **ST-3** A table can be linked to any number of sessions, and a session to
  any number of tables.

### 4.6 AI copilot

- **AI-1** The AI knows only about its session's linked tables, by name, id,
  column list and row count. Table values are never pushed into its context
  in bulk.
- **AI-2** The AI reads values through tools and only as it needs them:
  - `list_tables`: every table in the system, by name and id, with sizes
  - `open_table`: link a table to the session and return its structure
    (columns, types, row count, version)
  - `read_rows`: read a page of rows, optionally limited to certain columns,
    with a capped page size
  - `read_cells`: read specific cells by row label and column name
  - `find_rows`: find rows whose line-item label matches a text search
- **AI-3** The AI changes tables through tools that map one-to-one to the
  operations in §4.2. `set_cells` and `add_rows` accept many values in one
  call, so bulk edits need one tool call rather than one per cell.
- **AI-4** Tool arguments follow strict definitions. Invalid arguments, and
  rejected operations, come back to the model as tool errors it can read and
  retry from. They must never crash the agent.
- **AI-5** The AI can list tables and open existing ones when a user asks,
  or when the task needs it.
- **AI-6** The AI's changes go through the same table processes and the
  same broadcasts as human changes. Their actor is the chat session.
- **AI-7** Model responses stream to every session participant as they are
  generated. Tool calls and their results are visible in the chat.

### 4.7 UI

- **UI-1** A table list page shows every table with its name, owner, size,
  and last updated time. Any table can be opened from it.
- **UI-2** A chat session list page shows every session with its title,
  creator and last activity. Users can open an existing session or start a
  new one.
- **UI-3** The chat session view has a chat panel and a tabbed table area.
  Several tables can be open at once, one per tab.
- **UI-4** When the AI in a session creates, opens, reads or writes a table,
  that table's tab is opened if needed and made active. This happens only in
  the UIs of that session's participants. Other users viewing the table see
  the change but their active tab does not move.
- **UI-5** A table can also be opened on its own, outside any chat session,
  from the table list page.
- **UI-6** In the grid, users can edit cells, rename line items, and add,
  remove, reorder, rename and retype columns and rows. That is every
  operation in §4.2.
- **UI-7** The chat panel shows each message's sender, streamed AI
  responses, tool calls and their results, queued messages, and a control to
  stop the AI's current turn.

## 5. Persistence and recovery

- **P-1** Table structure, data, versions, sessions, session–table links and
  chat history are stored in Postgres.
- **P-2** An operation is written to Postgres, together with its version
  increase, in one transaction before it is broadcast. If the write fails,
  the operation is rejected and nothing is broadcast.
- **P-3** Every applied operation is added to a change-log table recording
  the table, version, operation, actor and chat session (if any), and
  timestamp.
- **P-4** Each open table runs in its own process under a `DynamicSupervisor`
  and is looked up through a `Registry` by table id. A table's process
  starts when the table is first used and stops after a configurable idle
  period (15 minutes by default).
- **P-5** If a table process crashes or restarts, it rebuilds its state from
  Postgres. Clients reconnect and reload a full snapshot (RT-4).
- **P-6** After a node restart, all state is rebuilt from Postgres when it
  is first used. Clients reconnect and reload.
- **P-7** Chat history is stored using Sagents' generated persistence layer
  (`mix sagents.setup`). It is not a custom-built implementation.

## 6. Non-functional requirements

- **NF-1** On a single local node, a change should reach every connected
  client in under 250 ms. This excludes model time for AI-made changes.
- **NF-2** Everything runs on a single node. Distribution is not required.
- **NF-3** Only signed-in users can open the WebSocket. The socket
  authenticates with the existing auth session cookie. There is no
  authorization beyond that.
- **NF-4** The table engine, operations and AI tools can be tested without
  calling any model. The agent can be tested against a fake model. Real
  model calls happen only in manual runs.
- **NF-5** The model is chosen by configuration, not code, so cheaper models
  can be tried without code changes.

## 7. Technical constraints

- **Backend:** Phoenix 1.8, Elixir, Postgres, Phoenix PubSub, Channels and
  Presence. The HTTP client is `Req`.
- **AI:** [Sagents](https://hex.pm/packages/sagents) (built on LangChain)
  with [ReqLLM](https://hex.pm/packages/req_llm) through its OpenRouter
  provider. The API key comes from `OPENROUTER_API_KEY`.
- **Sagents integration:**
  - Sagents' LiveView helpers don't apply to this Vue SPA, so a Phoenix
    Channel bridge relays agent events (streaming, tool calls, status,
    queued messages, presence).
  - `mix sagents.setup` needs a scope module, which the app must add.
- **Frontend:** Vue 3 SPA, shadcn-vue, and AI Elements for the chat UI. It
  uses the `phoenix` npm client for sockets.

## 8. Assumptions to confirm

These defaults were chosen during scoping and have not been explicitly
confirmed:

1. Column types are limited to `text`, `number`, `boolean` and `date`.
2. Line-item uniqueness ignores case and surrounding whitespace.
3. `change_column_type` rejects the whole operation if any value cannot be
   converted, rather than clearing those cells.
4. Idle table processes stop after 15 minutes.
5. A change should reach connected clients in under 250 ms (NF-1).
6. AI-1 lists the linked tables' columns and row counts, but no values.

## 9. Known limitations (accepted for the POC)

- **Stale AI writes:** the AI can overwrite a value a human changed after
  the AI read it. Writes are last-write-wins, with no version check on AI
  writes.
- **No undo:** mistakes are fixed by making another change. The change log
  keeps the history.
- **Everything is shared:** any user can change any table or take part in
  any session.
- **Large tables are untested:** the full snapshot sent on join or reload
  (RT-3, RT-4) and the grid rendering grow with table size. Very large
  tables may need incremental loading or a virtualized grid later.
