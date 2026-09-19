defmodule Mix.Tasks.PhoenixVue.Gen.Auth do
  @shortdoc "Generates auth (users, organizations, sessions, JSON API, Vue SPA pages) into the target app"

  @moduledoc """
  Generates a complete authentication stack into the target Phoenix + Vue app.

      mix phoenix_vue.gen.auth --mode multi   # default
      mix phoenix_vue.gen.auth --mode single

  ## Modes

  - `--mode multi` (default) — multi-tenant. Users can belong to multiple
    organizations; a first-time signup is routed to an onboarding screen that
    creates the user's first organization.
  - `--mode single` — every user belongs to exactly one organization, auto-
    created at signup. Org-switcher and create-organization UI are hidden.

  Both modes ship the same database schema. Flipping a project from `single`
  to `multi` later is one constant change in `frontend/src/lib/auth-mode.ts`
  plus an Ecto migration that drops the single-tenant uniqueness constraint.

  ## What gets generated

  - Backend schemas and migrations: User, Identity, PasswordCredential, Session,
    Organization, Member, Invitation
  - Sibling `_queries.ex` modules for every schema (Repo-free)
  - Context facades: `Accounts`, `Organizations`
  - `Auth` utilities: opaque DB-backed tokens, Argon2 password hasher, session
    sweeper Oban worker, mailer + Oban delivery worker
  - Plugs: `FetchUserSession`, `RequireAuthentication`, `RequireMember`,
    `SessionCookie`
  - JSON controllers under `/api/`: registration, sessions, me, password,
    email verification, organizations, invites, members
  - Vue SPA: Pinia auth store, fetch wrapper with CSRF retry, login / register
    / forgot-password / reset-password / verify-email / register-sent /
    onboarding views, `AuthLayout` and `OnboardingLayout`
  - Tests for contexts, plugs, and controllers; auth fixtures support file

  After running, install the new deps and migrate:

      mix deps.get
      mix ecto.migrate
      mix phx.server

  This task is single-shot. Re-running it after auth is in place will refuse
  with a clear error; delete the generated `Accounts` module first if you
  truly want to regenerate from scratch.
  """

  use Mix.Task

  @switches [mode: :string]
  @valid_modes ~w(single multi)

  @impl Mix.Task
  def run(args) do
    if Mix.Project.umbrella?() do
      Mix.raise("mix phoenix_vue.gen.auth is not supported in umbrella applications.")
    end

    {opts, _argv, _invalid} = OptionParser.parse(args, switches: @switches)
    mode = parse_mode(opts[:mode] || "multi")

    Mix.Task.run("app.config")

    assigns = build_assigns(mode)
    preflight!(assigns)
    announce(assigns)

    copy_templates(template_root(), output_root(), assigns)
    patch_in_place_files(assigns)

    print_next_steps(assigns)
  end

  # -- Assigns ---------------------------------------------------------------

  defp parse_mode(value) when value in @valid_modes, do: String.to_existing_atom(value)

  defp parse_mode(other) do
    Mix.raise(
      "Invalid --mode: #{inspect(other)}. Must be one of: #{Enum.join(@valid_modes, ", ")}"
    )
  end

  defp build_assigns(mode) do
    app =
      Mix.Project.config()[:app] ||
        Mix.raise("Could not determine the target app name from mix.exs.")

    base_string = Mix.Phoenix.base()
    base = Module.concat([base_string])
    web = Mix.Phoenix.web_module(base_string)

    repo =
      case Application.get_env(app, :ecto_repos) do
        [repo | _] -> repo
        _ -> Module.concat(base, Repo)
      end

    mailer = Module.concat(base, Mailer)
    now_base = DateTime.utc_now()

    %{
      app: app,
      app_string: Atom.to_string(app),
      base: base,
      base_string: base_string,
      web: web,
      web_string: inspect(web),
      repo: repo,
      repo_string: inspect(repo),
      mailer: mailer,
      mailer_string: inspect(mailer),
      mode: mode,
      mode_string: Atom.to_string(mode),
      now_base: now_base
    }
  end

  defp preflight!(%{base: base}) do
    accounts = Module.concat(base, Accounts)

    if Code.ensure_loaded?(accounts) do
      Mix.raise("""
      #{inspect(accounts)} already exists.

      `mix phoenix_vue.gen.auth` is single-shot and refuses to overwrite an
      existing auth stack. If you want to regenerate from scratch, delete the
      previously-generated files first and re-run.
      """)
    end

    for anchor_file <- anchor_files() do
      contents = File.read!(anchor_file)

      for marker <- expected_markers_for(anchor_file),
          not String.contains?(contents, marker) do
        Mix.raise("""
        Missing anchor in #{anchor_file}:

            #{marker}

        Restore the anchor before re-running. The template ships with all anchors
        in place; if you removed one, copy the original from the upstream template
        repository.
        """)
      end
    end
  end

  defp announce(assigns) do
    Mix.shell().info("""

    ==> Generating auth
        app:   #{inspect(assigns.app)}
        base:  #{assigns.base_string}
        web:   #{assigns.web_string}
        repo:  #{assigns.repo_string}
        mode:  #{assigns.mode}
    """)
  end

  # -- Template walking ------------------------------------------------------

  @doc false
  def template_root do
    Path.join([File.cwd!(), "priv", "templates", "phoenix_vue.gen.auth"])
  end

  @doc false
  def output_root, do: File.cwd!()

  defp copy_templates(root, out, assigns) do
    root
    |> all_files()
    |> Enum.each(fn source ->
      relative = Path.relative_to(source, root)
      target = resolve_target_path(relative, assigns)
      target_abs = Path.join(out, target)
      render_template(source, target_abs, assigns)
    end)
  end

  defp all_files(root) do
    if File.dir?(root) do
      root
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: false)
      |> Enum.filter(&File.regular?/1)
    else
      []
    end
  end

  # Translates `lib/__app__/accounts/user.ex.eex` into `lib/my_app/accounts/user.ex`.
  # Filenames may also use `__nowN__` (N = 0..15) for monotonically-increasing
  # migration timestamps within a single generator run.
  defp resolve_target_path(relative, assigns) do
    relative
    |> String.replace("__app__", assigns.app_string)
    |> apply_now_offsets(assigns.now_base)
    |> strip_eex_suffix()
  end

  defp apply_now_offsets(path, base_dt) do
    Regex.replace(~r/__now(\d*)__/, path, fn _full, n ->
      offset = if n == "", do: 0, else: String.to_integer(n)
      base_dt |> DateTime.add(offset, :second) |> format_compact()
    end)
  end

  defp format_compact(%DateTime{} = dt) do
    Enum.map_join([dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second], "", &pad/1)
  end

  defp strip_eex_suffix(path) do
    if String.ends_with?(path, ".eex") do
      String.replace_suffix(path, ".eex", "")
    else
      path
    end
  end

  defp render_template(source, target, assigns) do
    contents =
      if String.ends_with?(source, ".eex") do
        EEx.eval_file(source, assigns: assigns)
      else
        File.read!(source)
      end

    Mix.Generator.create_file(target, contents, force: force_overwrite?(target))
  end

  # The frontend SPA scaffold (router/index.ts, main.ts, App.vue) ships pristine
  # from the template — overwriting them on a fresh `mix phoenix_vue.gen.auth`
  # is safe because preflight guarantees we're not running on top of an
  # existing auth installation. Backend files always get created (no
  # collision because their parent directories were generated by this task
  # too).
  defp force_overwrite?(target) do
    rel = Path.relative_to(target, File.cwd!())

    rel in [
      "frontend/src/router/index.ts",
      "frontend/src/main.ts"
    ]
  end

  # -- In-place anchor patches ----------------------------------------------

  defp patch_in_place_files(assigns) do
    patch_mix_exs(assigns)
    patch_config_exs(assigns)
    patch_runtime_exs(assigns)
    patch_router_exs(assigns)
    patch_claude_md(assigns)
    run_formatter()
  end

  defp patch_mix_exs(_assigns) do
    patch_file!(
      Path.join(File.cwd!(), "mix.exs"),
      "  # Replaced when `mix phoenix_vue.gen.auth` runs.\n  defp auth_deps, do: []\n",
      ~S"""
        # Generated by `mix phoenix_vue.gen.auth`.
        defp auth_deps do
          [
            {:argon2_elixir, "~> 4.0"},
            {:plug_crypto, "~> 2.1"}
          ]
        end
      """
    )
  end

  defp patch_config_exs(assigns) do
    block = """
    # Auth — generated by `mix phoenix_vue.gen.auth`.
    config :#{assigns.app_string}, :auth,
      session_cookie_name: "_#{assigns.app_string}_auth",
      session_max_age_days: 30,
      password_min_length: 8,
      password_max_length: 128,
      failed_signin_threshold: 5,
      failed_signin_lockout_minutes: 15,
      email_verification_token_ttl_minutes: 60 * 24,
      password_reset_token_ttl_minutes: 60,
      mail_from: {"#{assigns.base_string}", "noreply@example.com"}

    """

    patch_file!(
      Path.join([File.cwd!(), "config", "config.exs"]),
      "# Auth configuration is inserted above the next line by `mix phoenix_vue.gen.auth`.\n# phoenix_vue:gen.auth:config_anchor\n\n",
      block
    )

    # Expand Logger metadata so `auth_*` log lines pass credo's
    # MissedMetadataKeyInLoggerConfig check.
    patch_file!(
      Path.join([File.cwd!(), "config", "config.exs"]),
      "  metadata: [:request_id]",
      "  metadata: [\n    :request_id,\n    :user_id,\n    :session_id,\n    :current_member_id,\n    :organization_id,\n    :reason,\n    :step,\n    :code,\n    :status,\n    :method,\n    :path\n  ]"
    )
  end

  defp patch_runtime_exs(assigns) do
    runtime_path = Path.join([File.cwd!(), "config", "runtime.exs"])

    patch_file!(
      runtime_path,
      """
      # Generator-managed cron entries. `mix phoenix_vue.gen.auth` replaces the next
      # line with its sweeper schedule. Hand-edit the list below to add your own.
      auth_crontab = []
      """,
      """
      # Generated by `mix phoenix_vue.gen.auth`.
      auth_crontab = [
        {"@hourly", #{assigns.base_string}.Auth.SessionSweeper}
      ]
      """
    )

    patch_file!(
      runtime_path,
      """
        # Auth prod overrides (cookie domain, secure flag, etc.) are inserted above
        # the next line by `mix phoenix_vue.gen.auth`.
        # phoenix_vue:gen.auth:prod_anchor
      """,
      """
        # Generated by `mix phoenix_vue.gen.auth`. Override the auth cookie's
        # domain / secure flag for production. `secure: true` requires HTTPS;
        # `domain` only matters if you serve the app on multiple subdomains.
        config :#{assigns.app_string}, :auth,
          session_cookie_secure: true,
          session_cookie_domain: System.get_env("AUTH_COOKIE_DOMAIN"),
          base_url: System.get_env("AUTH_BASE_URL") || "https://" <> host
      """
    )
  end

  defp patch_router_exs(assigns) do
    router_path =
      Path.join([
        File.cwd!(),
        "lib",
        "#{assigns.app_string}_web",
        "router.ex"
      ])

    patch_file!(
      router_path,
      """
        pipeline :api do
          plug :accepts, ["json"]
        end
      """,
      """
        pipeline :api do
          plug :accepts, ["json"]
          plug :fetch_session
          plug :protect_from_forgery
          plug #{assigns.web_string}.Plugs.FetchUserSession
        end
      """
    )

    patch_file!(
      router_path,
      """
        # Auth pipelines are inserted above the next line by `mix phoenix_vue.gen.auth`.
        # phoenix_vue:gen.auth:pipelines_anchor
      """,
      """
        # Generated by `mix phoenix_vue.gen.auth`.
        pipeline :require_auth do
          plug #{assigns.web_string}.Plugs.RequireAuthentication
        end

        pipeline :require_member do
          plug #{assigns.web_string}.Plugs.RequireMember
        end
      """
    )

    patch_file!(
      router_path,
      """
        # API scopes are inserted above the next line by `mix phoenix_vue.gen.auth`.
        # Declare additional scopes ABOVE that anchor so they match before the SPA
        # catch-all at the bottom of this file.
        # phoenix_vue:gen.auth:scopes_anchor
      """,
      """
        # Generated by `mix phoenix_vue.gen.auth`.
        scope "/api", #{assigns.web_string}.Api do
          pipe_through :api

          # Public — no session required.
          post "/auth/register", RegistrationController, :create
          post "/sessions", SessionsController, :create
          post "/me/password-reset", PasswordController, :request_reset
          post "/me/password-reset/confirm", PasswordController, :confirm_reset
          post "/me/email-verification/confirm", EmailVerificationController, :confirm
          post "/me/email-verification/resend", EmailVerificationController, :resend
        end

        scope "/api", #{assigns.web_string}.Api do
          pipe_through [:api, :require_auth]

          get "/me", MeController, :show
          delete "/sessions/current", SessionsController, :delete_current
          post "/sessions/revoke-all", SessionsController, :revoke_all
          post "/me/switch-organization", SessionsController, :switch_organization
          post "/me/change-password", PasswordController, :change
          post "/organizations", OrganizationsController, :create
        end

        # Declare additional /api scopes ABOVE this comment; the SPA catch-all
        # below matches every other path.
      """
    )
  end

  defp patch_claude_md(assigns) do
    path = Path.join(File.cwd!(), "CLAUDE.md")

    if File.exists?(path) do
      do_patch_claude_md(path, assigns)
    else
      Mix.shell().info(
        "* skipping CLAUDE.md patch (file not found — only the template's own CLAUDE.md ships this anchor)"
      )
    end
  end

  defp do_patch_claude_md(path, assigns) do
    contents = File.read!(path)

    pattern =
      ~r/<!-- phoenix_vue:gen\.auth:claude_anchor:begin -->.*?<!-- phoenix_vue:gen\.auth:claude_anchor:end -->/s

    if Regex.match?(pattern, contents) do
      replacement = claude_md_post_install(assigns)
      File.write!(path, Regex.replace(pattern, contents, replacement))
      Mix.shell().info("* patching CLAUDE.md")
    else
      Mix.shell().info(
        "* skipping CLAUDE.md patch (auth anchor not found — leaving CLAUDE.md alone)"
      )
    end
  end

  defp claude_md_post_install(assigns) do
    """
    ## Authentication

    ✓ in place (mode: `#{assigns.mode}`) — landed by `mix phoenix_vue.gen.auth`.

    **Three-module split** (do not collapse):
    - `#{assigns.base_string}.Accounts` — identity (User, PasswordCredential, Session, sibling `_queries` modules; register / authenticate / verify_email / start_password_reset / complete_password_reset / change_password / session lifecycle).
    - `#{assigns.base_string}.Organizations` — tenancy (Organization, Member, queries; create_organization_for_user / verify_member_for_user / list_memberships_for_user).
    - `#{assigns.base_string}.Auth` — primitives (Token, PasswordHasher, PasswordPolicy, Config, SessionSweeper Oban worker, Mailer.AuthMailer + Mailer.DeliverWorker).

    Schemas never call `Repo` — every `<thing>.ex` has a sibling `<thing>_queries.ex` that returns `Ecto.Query` only. Contexts execute.

    **Two cookies**:
    - `_#{assigns.app_string}_auth` — opaque 32-byte random token, SHA-256 hashed at rest. HttpOnly, `Secure` in prod (via `AUTH_COOKIE_DOMAIN` / runtime config). The actual session.
    - `_#{assigns.app_string}_key` — `Plug.Session`. Used **only** as the CSRF token carrier. The SPA reads it from `<meta name="csrf-token">` and sends `X-CSRF-Token` on every mutating XHR.

    **JSON API** under `/api/`:
    - Public: `POST /api/auth/register`, `POST /api/sessions`, `POST /api/me/{password-reset,password-reset/confirm,email-verification/confirm,email-verification/resend}`
    - Authenticated: `GET /api/me`, `DELETE /api/sessions/current`, `POST /api/sessions/revoke-all`, `POST /api/me/{switch-organization,change-password}`, `POST /api/organizations`
    - All `{:error, _}` from contexts flow through `#{assigns.web_string}.Api.FallbackController` → canonical envelope via `#{assigns.web_string}.Api.Errors`.

    **SPA**:
    - Views: `frontend/src/views/auth/{Login,Register,RegisterSent,ForgotPassword,ForgotPasswordSent,ResetPassword,VerifyEmail}View.vue` and `frontend/src/views/onboarding/CreateOrganizationView.vue`.
    - Layouts: `frontend/src/layouts/{AuthLayout,OnboardingLayout}.vue`.
    - Pinia store: `frontend/src/stores/auth.ts` — `hydrate()` runs once on app boot in `main.ts` before mount, so router guards see the resolved identity on first render.
    - Fetch wrapper: `frontend/src/lib/api.ts` — `credentials: 'include'`, attaches `X-CSRF-Token` on mutations, retries once on stale-CSRF 403.

    **Mode**: `#{assigns.mode}`. The data model is identical between modes — `MODE` in `frontend/src/lib/auth-mode.ts` is the only behavioral switch (single mode hides org-switcher UI; multi routes first-signup to onboarding). Flipping single → multi later: change the constant + drop `members_single_tenant_user_id_index` in a new migration.

    **Built but unmounted** (drop into your chrome when ready): `frontend/src/components/org/OrganizationSwitcher.vue`. The switch endpoint (`POST /api/me/switch-organization`) is wired and tested.

    **Deliberately not generated** (add as separate features):
    - OAuth (Identity schema, future `mix phoenix_vue.gen.oauth`)
    - Invite UI (the `invite_token_hash` columns + `Member.invitation_changeset/2` / `claim_changeset/2` ship; wire a controller + view when you need them)
    - Rate limiting (auth endpoints lean on Argon2 lockout for the most-abused path)
    - App chrome (NavRail, UserProfileMenu, SecurityView, Members list)
    - 2FA, WebAuthn, magic links, audit log
    """
  end

  defp patch_file!(path, old, new) do
    contents = File.read!(path)

    unless String.contains?(contents, old) do
      Mix.raise("""
      Could not find anchor in #{Path.relative_to_cwd(path)}:

      #{indent(old, 4)}
      """)
    end

    File.write!(path, String.replace(contents, old, new))
    Mix.shell().info("* patching #{Path.relative_to_cwd(path)}")
  end

  defp indent(text, n) do
    prefix = String.duplicate(" ", n)
    text |> String.split("\n") |> Enum.map_join("\n", &(prefix <> &1))
  end

  defp run_formatter do
    Mix.shell().info("* formatting")
    Mix.Task.run("format")
  end

  defp anchor_files do
    [
      Path.join([File.cwd!(), "mix.exs"]),
      Path.join([File.cwd!(), "config", "config.exs"]),
      Path.join([File.cwd!(), "config", "runtime.exs"]),
      Path.join([
        File.cwd!(),
        "lib",
        "#{Atom.to_string(Mix.Project.config()[:app])}_web",
        "router.ex"
      ])
    ]
  end

  defp expected_markers_for(path) do
    base = Path.basename(path)

    case base do
      "mix.exs" ->
        ["defp auth_deps,"]

      "config.exs" ->
        ["phoenix_vue:gen.auth:config_anchor"]

      "runtime.exs" ->
        ["auth_crontab", "phoenix_vue:gen.auth:prod_anchor"]

      "router.ex" ->
        ["phoenix_vue:gen.auth:pipelines_anchor", "phoenix_vue:gen.auth:scopes_anchor"]

      _ ->
        []
    end
  end

  # -- Misc ------------------------------------------------------------------

  defp print_next_steps(_assigns) do
    Mix.shell().info("""

    ==> Done.

    Next steps:

        mix deps.get
        mix ecto.migrate
        mix phx.server

    Sign-up flow: visit /, register, click the verification link in
    /dev/mailbox, log in. In multi mode you'll be routed to onboarding to
    create your first organization.
    """)
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
