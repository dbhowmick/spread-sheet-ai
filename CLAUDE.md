# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

`SpreadSheetAi` is a Phoenix application. Stack: **Phoenix 1.8 + Vue 3 + Postgres + Oban**.

- OTP app: `:spread_sheet_ai`
- Module namespaces: `SpreadSheetAi.*` (business logic — Repo, Mailer, Application) and `SpreadSheetAiWeb.*` (web layer — Endpoint, Router, etc.)
- Dev DB: `spread_sheet_ai_dev` (Postgres, default `postgres`/`postgres` from `config/dev.exs`)

## Essential commands

All from `mix.exs` aliases:

```
mix setup                              # deps.get + ecto.setup + assets.setup + assets.build
mix phx.server                         # dev server on :4000 with live reload + watchers
iex -S mix phx.server                  # same, with IEx shell attached
mix test                               # auto-creates test DB, runs ExUnit
mix test test/path/to/file_test.exs:42 # single test by file + line
mix test --failed                      # rerun last failures
mix ecto.reset                         # drop + create + migrate + seed
mix assets.build                       # pnpm vite build
mix assets.deploy                      # vite build --mode production + phx.digest
mix credo --strict                     # static analysis (.credo.exs)
mix dialyzer                           # type analysis (PLT cached in priv/plts/)
mix precommit                          # compile --warnings-as-errors + deps.unlock --unused + format + credo --strict + dialyzer + test
```

Run `mix precommit` before every commit.

## Authentication

✓ in place (mode: `single`) — landed by `mix phoenix_vue.gen.auth`.

**Three-module split** (do not collapse):
- `SpreadSheetAi.Accounts` — identity (User, PasswordCredential, Session, sibling `_queries` modules; register / authenticate / verify_email / start_password_reset / complete_password_reset / change_password / session lifecycle).
- `SpreadSheetAi.Organizations` — tenancy (Organization, Member, queries; create_organization_for_user / verify_member_for_user / list_memberships_for_user).
- `SpreadSheetAi.Auth` — primitives (Token, PasswordHasher, PasswordPolicy, Config, SessionSweeper Oban worker, Mailer.AuthMailer + Mailer.DeliverWorker).

Schemas never call `Repo` — every `<thing>.ex` has a sibling `<thing>_queries.ex` that returns `Ecto.Query` only. Contexts execute.

**Two cookies**:
- `_spread_sheet_ai_auth` — opaque 32-byte random token, SHA-256 hashed at rest. HttpOnly, `Secure` in prod (via `AUTH_COOKIE_DOMAIN` / runtime config). The actual session.
- `_spread_sheet_ai_key` — `Plug.Session`. Used **only** as the CSRF token carrier. The SPA reads it from `<meta name="csrf-token">` and sends `X-CSRF-Token` on every mutating XHR.

**JSON API** under `/api/`:
- Public: `POST /api/auth/register`, `POST /api/sessions`, `POST /api/me/{password-reset,password-reset/confirm,email-verification/confirm,email-verification/resend}`
- Authenticated: `GET /api/sheets`, `GET /api/sheets/:id`, `POST /api/sheets` (`SheetController`, contract §3), `GET /api/conversations`, `GET /api/conversations/:id`, `POST /api/conversations` (`ConversationController`), `GET /api/me`, `GET /api/socket_token`, `DELETE /api/sessions/current`, `POST /api/sessions/revoke-all`, `POST /api/me/{switch-organization,change-password}`, `POST /api/organizations`
- WebSocket `/socket` (`SpreadSheetAiWeb.UserSocket`): the SPA fetches `GET /api/socket_token` (a 24 h `Phoenix.Token` over `{user_id, session_id}`, see `SpreadSheetAiWeb.SocketToken`) and connects with it as the Phoenix `auth_token`. `connect/3` re-checks the session via `Accounts.fetch_active_session/1`; `id/1` is `"user_socket:<session_id>"`. Channel tests use `SpreadSheetAiWeb.ChannelCase.connect_user/1`.
- Channel `sheet:<id>` (`SpreadSheetAiWeb.SheetChannel`, contract §5): join snapshot, `op` / `snapshot` events, `op_applied` and `participants` pushes. Contract serializers live in `SpreadSheetAiWeb.SheetJSON` (`lib/spread_sheet_ai_web/json/`), shared with REST. The sheets context's `{:error, code, message, meta}` becomes the error envelope via `Api.Errors.from_business/1`.
- Channel `conversation:<id>` (`SpreadSheetAiWeb.ConversationChannel`, contract §7): the join reply (conversation, messages, linked sheets, agent status), `send_message` / `cancel` / `open_sheet`, and the chat pushes. The channel process is a Sagents subscriber; `SpreadSheetAiWeb.ConversationEvents` (pure) turns agent events into pushes, and `ConversationJSON` / `MessageJSON` serialize. Both channels list viewers with `SpreadSheetAiWeb.Presence.user_refs/1`.
- All `{:error, _}` from contexts flow through `SpreadSheetAiWeb.Api.FallbackController` → canonical envelope via `SpreadSheetAiWeb.Api.Errors`.

**SPA**:
- Views: `frontend/src/views/auth/{Login,Register,RegisterSent,ForgotPassword,ForgotPasswordSent,ResetPassword,VerifyEmail}View.vue` and `frontend/src/views/onboarding/CreateOrganizationView.vue`.
- Layouts: `frontend/src/layouts/{AuthLayout,OnboardingLayout}.vue`.
- Pinia store: `frontend/src/stores/auth.ts` — `hydrate()` runs once on app boot in `main.ts` before mount, so router guards see the resolved identity on first render.
- Fetch wrapper: `frontend/src/lib/api.ts` — `credentials: 'include'`, attaches `X-CSRF-Token` on mutations, retries once on stale-CSRF 403.

**Mode**: `single`. The data model is identical between modes — `MODE` in `frontend/src/lib/auth-mode.ts` is the only behavioral switch (single mode hides org-switcher UI; multi routes first-signup to onboarding). Flipping single → multi later: change the constant + drop `members_single_tenant_user_id_index` in a new migration.

**Built but unmounted** (drop into your chrome when ready): `frontend/src/components/org/OrganizationSwitcher.vue`. The switch endpoint (`POST /api/me/switch-organization`) is wired and tested.

**Deliberately not generated** (add as separate features):
- OAuth (Identity schema, future `mix phoenix_vue.gen.oauth`)
- Invite UI (the `invite_token_hash` columns + `Member.invitation_changeset/2` / `claim_changeset/2` ship; wire a controller + view when you need them)
- Rate limiting (auth endpoints lean on Argon2 lockout for the most-abused path)
- App chrome (NavRail, UserProfileMenu, SecurityView, Members list)
- 2FA, WebAuthn, magic links, audit log


## Architecture

- `lib/spread_sheet_ai/` — business logic root: `application.ex`, `repo.ex`, `mailer.ex`. New contexts go here.
- `lib/spread_sheet_ai_web/` — web layer: `endpoint.ex`, `router.ex`, `telemetry.ex`, `components/`, `controllers/`, `gettext.ex`, `plugs/`. `PageController.home` renders the SPA shell; a catch-all `GET /*path` at the bottom of `router.ex` sends every browser path through it so vue-router survives deep-link refreshes.
- `frontend/` — Vue 3 SPA bundled by Vite 8 (Tailwind v4 + shadcn-vue + Pinia + Vue Router 5, OXC toolchain). Full layout + conventions in the [**Frontend (Vue 3 SPA)**](#frontend-vue-3-spa) section below. `phoenix` npm + `@types/phoenix` are pre-installed so Channels are one UserSocket + endpoint route away when needed.
- `priv/static/assets/` — Vite build output (gitignored). Populated by `mix assets.build` / `mix assets.deploy`. **No `assets/` directory** on the Phoenix side — Vite owns all CSS/JS.
- `priv/repo/migrations/` — Ecto migrations (Oban schema landed in the initial `add_oban` migration).
- HTTP server: Bandit (`Bandit.PhoenixAdapter` in `config/config.exs`).

## Frontend (Vue 3 SPA)

### Layout

```
frontend/
├── index.html               SPA shell — <title> + <div id="app">
├── package.json             pnpm; engines node ^20.19 || >=22.12
├── pnpm-lock.yaml
├── env.d.ts                 /// <reference types="vite/client" />
├── vite.config.ts           dev :4001, HMR :4002, outDir → ../priv/static
├── vite-dev.mjs             dev wrapper that exits when Phoenix closes stdin
├── tsconfig.json            workspace references → app + node
├── tsconfig.app.json        DOM + Vue, paths { "@/*": ["./src/*"] }
├── tsconfig.node.json       vite.config / eslint.config type-checking
├── eslint.config.ts         flat config; vue-essential + oxlint
├── .oxlintrc.json / .oxfmtrc.json
├── .editorconfig / .gitattributes / .gitignore
└── src/
    ├── main.ts              createApp + pinia + router; mounts #app
    ├── App.vue              <RouterView /> + <Toaster /> (shadcn-vue sonner)
    ├── assets/
    │   └── main.css         tailwindcss + tw-animate-css + shadcn-vue theme
    │                        + Geist/Bricolage fonts + Tailwind @source paths
    ├── router/
    │   └── index.ts         createWebHistory; home + 404 catch-all
    ├── views/               page components mapped from the router
    │   ├── HomeView.vue
    │   └── NotFoundView.vue
    └── lib/                 framework-agnostic helpers
        └── csrf.ts          read <meta name="csrf-token">
```

### Where new code goes

- `src/views/` — top-level page components mapped from `src/router/index.ts`. One file per route, PascalCase, suffix `View.vue`.
- `src/components/` — reusable UI not bound to a route. Create when the same fragment renders in ≥ 2 views.
- `src/composables/` — Vue composition functions (`useFoo`); one concern per file, export a single `use*`.
- `src/stores/` — Pinia stores (`defineStore`). State that outlives a single view (auth, current org, etc.).
- `src/lib/` — framework-agnostic TS helpers (CSRF, API client, formatters, time, hash).
- `src/types/` — shared TS types / Zod schemas.
- `src/assets/` — global CSS only. Per-component CSS belongs in the `.vue` `<style>` block.
- Use the `@` alias for cross-directory imports: `import { getCsrfToken } from '@/lib/csrf'`.

### Commands (from `frontend/`)

```
pnpm dev          # standalone vite — rarely needed; mix phx.server runs it
pnpm build        # type-check + production bundle into ../priv/static
pnpm preview      # serve the production bundle locally
pnpm type-check   # vue-tsc --build (incremental; cached in node_modules/.tmp)
pnpm lint         # oxlint --fix → eslint --fix --cache
pnpm format       # oxfmt src/
```

### HMR flow

`mix phx.server` spawns `node vite-dev.mjs` via the Phoenix watcher in `config/dev.exs`. Vite serves modules from `:4001`; `root.html.heex` injects `<script src="//{request_host}:4001/src/main.ts">` so the browser pulls everything live. Edits to `.vue`, `.ts`, or `.css` files HMR without a full reload. `.heex` / router changes still trigger a Phoenix `live_reload`.

## Sheets runtime

`SpreadSheetAi.Sheets` is the one API for sheets. The channels, REST and
the AI tools all call it. Details are in `docs/backend-plan.md` §4–§5.

- **Pure core:** `Sheets.Op.parse/1` checks an op's shape, and
  `Sheets.Engine` applies it to an in-memory `Sheets.State`, returning the
  `AppliedOp` plus DB effects. `Sheets.Reads` holds the pure reads.
- **One process per open sheet:** `Sheets.Server`, registered in
  `Sheets.Registry` and supervised by `Sheets.ServerSupervisor`,
  `restart: :temporary`. It is started lazily by `Sheets.Runtime` and
  stops after `idle_timeout`.
- **Every op:** engine → `Sheets.Persister` (one transaction: version bump,
  effects, change-log row) → replace state → broadcast
  `{:op_applied, %{sheet_id, version, applied_op, actor, client_op_id}}`
  on `Sheets.topic(id)` (`"sheet_events:<id>"`, see `Sheets.subscribe/1`).
- **Name-based ops (AI tools):** `Sheets.apply_named/4` takes an op that
  names rows by label and columns by name. `Sheets.Named.resolve/2` turns
  it into an id-based op inside the sheet server, so names are resolved
  against the state the op is applied to.
- **Errors** everywhere are `{:error, code_atom, message, meta}`, using
  contract §8 codes.
- **Tests that start sheet servers must be `async: false`.** The servers
  share the sandbox connection, and `DataCase` stops them all when a sync
  test exits. Use `SheetsFixtures.created_sheet_fixture/1` for sheets
  made the way the app makes them.

## Agents (Sagents)

The AI copilot runs one Sagents `AgentServer` per conversation. Details are
in `docs/backend-plan.md` §7.

- **Generated code:** `SpreadSheetAi.Conversations` (+ `conversations/`) and
  `SpreadSheetAi.Agents.*` (`agents/`) came from `mix sagents.setup` and
  were adapted:
  - conversations are shared (the scope helpers don't filter);
  - the sender is kept in display-message metadata;
  - `AgentPersistence` is the one title writer;
  - the factory has no filesystem or HITL;
  - `Coordinator.stop_conversation_session/1` stops the whole agent
    supervisor (Sagents' own stop leaves it behind).

  These namespaces may call `Repo` directly; the schema/queries split
  applies to our own code.
- **Models:** `SpreadSheetAi.Agents.ChatModels` builds them from
  `config :spread_sheet_ai, :ai` (OpenRouter via `ChatReqLLM`). ReqLLM
  reads `OPENROUTER_API_KEY` from the env or from `.env` (gitignored).
- **Chat:** `SpreadSheetAi.Agents.Chat` sends a user's message (as
  `"[Name]: text"` to the model, with the sender in the metadata), cancels
  a turn and reads the agent's status. App events for a conversation
  (`{:sheets_changed}`, `{:focus_sheet, id, reason}`) go through
  `Conversations.broadcast_event/2` on `"conversation_events:<id>"`.
- **Sheet links:** `Sheets.link/3` and `Sheets.list_links/1` record which
  sheets a conversation used (`conversation_sheets`).
- **Tools:** `Agents.Middleware.SheetTools` (last in the factory's
  middleware) supplies the 16 sheet tools and, in `before_model/2`, puts a
  `<linked_sheets>` block at the start of the latest user message. Sagents
  allows only one system message, and it is fixed when the agent is built.
  - The tools live in `Agents.Tools.{Read, Structure, Rows, Cells}`. Each
    has `functions/0` plus one public `name(args, context)` per tool, and
    tests call those directly (`ConversationsFixtures.tool_context/2`).
  - `Agents.Tools.Support` holds the shared helpers:
    - argument checks, run before calling `Sheets`;
    - `ERROR <code>: …` text plus a hint, since ChatReqLLM drops the
      error flag;
    - `touch/3`, which links the sheet and broadcasts `focus_sheet` and
      `sheets_changed` before the tool returns;
    - the agent actor, which carries the conversation title.
- **Tests never call a real model.** `SpreadSheetAi.Test.ScriptedChatModel`
  replies from a script:
  - `start_supervised!(ScriptedChatModel)` starts it, and `push/2` adds
    replies;
  - `ConversationsFixtures.start_agent!/2` starts an agent with the test
    subscribed to it, `stop_agent_on_exit/1` cleans up an agent a channel
    started, and `await_run_end/1` waits for the end of a run;
  - agent tests are `async: false`.

## Background jobs (Oban)

Oban runs in a two-release topology — queues split by `RELEASE_NAME` in `config/runtime.exs`:

- `spread_sheet_ai_server` (web) — `default` + `mailer` queues; hosts Pruner + Cron plugins.
- `spread_sheet_ai_processors` — heavy queues you add as features land (e.g. `documents`, `embeddings`); Pruner only.
- Dev / iex / test (no `RELEASE_NAME`) — all queues run on one node.

Workers go under `lib/spread_sheet_ai/.../workers/`. Pattern:

```elixir
defmodule SpreadSheetAi.Some.Workers.MyWorker do
  use Oban.Worker, queue: :default, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: :ok
end
```

Tests use `config :spread_sheet_ai, Oban, testing: :inline` (jobs run synchronously on enqueue).

## Dev flow

`mix phx.server` runs Phoenix on `:4000` and spawns Vite on `:4001`. The root layout (`lib/spread_sheet_ai_web/components/layouts/root.html.heex`) conditionally injects either the dev `<script src="//host:4001/@vite/client">` tags or the prod digested `/assets/main.{js,css}` links, keyed off `Application.get_env(:spread_sheet_ai, :vite_dev_server)`. Prod build: `MIX_ENV=prod mix assets.deploy` → Vite builds + `phx.digest` cache-busts.

## Framework rules — see AGENTS.md

`AGENTS.md` is the source of truth for Phoenix 1.8 / LiveView / Ecto / HEEx / Elixir / forms / streams / test conventions. **Read it before writing code.** High-level reminders that come up constantly:

- **HTTP client is `Req` only** — never HTTPoison / Tesla / httpc.
- **Tailwind v4 lives on the Vue side** — `frontend/src/assets/main.css` is canonical (no `tailwind.config.js`, no Phoenix-side asset pipeline).
- **Use shadcn-vue for SPA UI** — components are vendored under `frontend/src/components/ui/` (add more with `pnpm dlx shadcn-vue@latest add <name>` from `frontend/`); import per component, e.g. `import { Button } from '@/components/ui/button'`. Icons come from `@lucide/vue` (`*Icon` names, e.g. `Loader2Icon`); toasts via `import { toast } from 'vue-sonner'`. Don't reintroduce Meldui or daisyUI.
- **Forms always via `Phoenix.Component.to_form/2`**; never pass a changeset directly to `<.form for=...>`.
- **No `live_redirect` / `live_patch`** — use `<.link navigate>` / `push_navigate`.
- **No `String.to_atom/1` on user input** (memory leak).
- **No `Phoenix.View`** (removed).

## Commit message conventions

- **Never add `Co-Authored-By: Claude ...` trailers** to commit messages. Author the commit normally; no AI attribution.
