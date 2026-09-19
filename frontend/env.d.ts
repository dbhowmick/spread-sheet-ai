/// <reference types="vite/client" />

interface ImportMetaEnv {
  /**
   * `VITE_MOCK_BACKEND=1 mix phx.server` runs the SPA against the in-memory
   * mock backend (frontend-plan §9). Dev-only — see `lib/transport/index.ts`,
   * which also gates on `import.meta.env.DEV`.
   */
  readonly VITE_MOCK_BACKEND?: '1'
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
