import { fileURLToPath, URL } from 'node:url'

import vue from '@vitejs/plugin-vue'
import { defineConfig } from 'vitest/config'

// Deliberately standalone rather than `mergeConfig(viteConfig, ...)`, which is
// the create-vue default. `vite.config.ts` carries the dev-server port that
// `mix phx.server` owns (4001, strictPort), Phoenix's build output path
// (`../priv/static`), and the `vueDevTools()` / `@tailwindcss/vite` plugins.
// `mergeConfig` *concatenates* plugin arrays, so none of that can be merged
// back out. The `@` alias is the only piece worth duplicating — keep it in
// sync with vite.config.ts.
export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  test: {
    environment: 'happy-dom',
    // Explicit imports (`import { describe, it, expect } from 'vitest'`)
    // rather than globals: `.oxlintrc.json` declares only `env.browser` and
    // `eslint.config.ts` adds no vitest globals, so this keeps both lint
    // configs unchanged.
    globals: false,
    // Flat, single level — this must mirror tsconfig.app.json's
    // `"exclude": ["src/**/__tests__/*"]` exactly. A nested
    // `__tests__/foo/bar.test.ts` would escape that exclude and get
    // type-checked by the app project, which has no vitest types.
    include: ['src/**/__tests__/*.{test,spec}.ts'],
    // F1 ships no tests; the runner is wired up for F2's pure reducers.
    passWithNoTests: true,
    restoreMocks: true,
  },
})
