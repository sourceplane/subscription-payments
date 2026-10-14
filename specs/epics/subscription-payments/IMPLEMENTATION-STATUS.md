# subscription-payments (SP) — Implementation status

As-built ≠ intent. This file records what actually shipped, and every place
the code departed from `design.md` or from the upstream template.

| Milestone | State | PR |
|---|---|---|
| SP0 — the spec | ✅ Shipped | [#1](https://github.com/sourceplane/subscription-payments/pull/1) |
| SP1 — the app on Workers | ✅ Shipped | [#2](https://github.com/sourceplane/subscription-payments/pull/2) |
| SP2 — the schema through db-migrate | ✅ Shipped (planned offline; apply gated on a linked workspace) | [#3](https://github.com/sourceplane/subscription-payments/pull/3) |
| SP3 — the Supabase project from Terraform | ✅ Shipped (validated; apply gated on a linked workspace) | [#4](https://github.com/sourceplane/subscription-payments/pull/4) |
| SP4 — ready to instantiate | ✅ Shipped | [#5](https://github.com/sourceplane/subscription-payments/pull/5) |

## Departures from the upstream template

The template is Next 14 / React 18 / `@supabase/ssr` 0.1 / eslint 8;
`@opennextjs/cloudflare` needs Next ≥ 15.5, so the port runs on Next 16.3.8
and React 19. Only what Next 16 and Workers force changed; everything below
is the complete list.

### `middleware.ts` → `proxy.ts`

Next 16 names the middleware file `proxy.ts` and its export `proxy`. Same
matcher, same `updateSession`; `utils/supabase/middleware.ts` keeps its
name. OpenNext 1.20 bundles it as Node.js middleware (an experimental
warning at build; it works).

### `@supabase/ssr` 0.12: `getAll` / `setAll` cookie adapters

The 0.1 `get` / `set` / `remove` cookie API no longer exists.
`utils/supabase/middleware.ts` and `utils/supabase/server.ts` use the
`getAll` / `setAll` pair; the request-and-response cookie dance in the
middleware and the try/catch in the server client (a Server Component
cannot set cookies) are preserved.

### `cookies()` is async: `createClient()` is async and awaited

`utils/supabase/server.ts`'s `createClient` awaits `cookies()` and is
therefore `async`; every caller awaits it — `app/page.tsx`,
`app/account/page.tsx`, `app/auth/callback/route.ts`,
`app/auth/reset_password/route.ts`, `app/signin/[id]/page.tsx`,
`components/ui/Navbar/Navbar.tsx`, `utils/stripe/server.ts` (two) and
`utils/auth-helpers/server.ts` (eight). `cookies()` itself is awaited in
`utils/auth-helpers/server.ts` (two), `app/signin/page.tsx` (the component
is `async` now) and `app/signin/[id]/page.tsx`.

### `params` / `searchParams` are Promises

`app/signin/[id]/page.tsx` takes `props` and awaits `props.params` and
`props.searchParams` before the template's logic runs unchanged.

### Stripe on Workers

`utils/stripe/config.ts` passes `httpClient: Stripe.createFetchHttpClient()`.
`app/api/webhooks/route.ts` verifies with
`await stripe.webhooks.constructEventAsync(body, sig, webhookSecret,
undefined, Stripe.createSubtleCryptoProvider())` instead of the synchronous
`constructEvent`. `stripe` stays on the template's v14 (both adapters are
there); `@stripe/stripe-js` stays at 2.4.0.

### The service-role client is built per call

`utils/supabase/admin.ts` built its `createClient(url || '', key || '')`
at module scope. `next build` evaluates `app/api/webhooks/route.ts` while
collecting page data, and supabase-js throws `supabaseUrl is required.` on
an empty URL — so a build without a Supabase project (Checks, a fresh
clone) failed, which on Vercel the integration's env vars hid.
`supabaseAdmin` is a function now (`supabaseAdmin().from(...)` at its ten
call sites), which is also Supabase's guidance for serverless and the
Workers-correct shape (the environment is populated per request). The
rejected alternative was injecting fixture values into a credential-free
build from `next.config.mjs`.

### React 19 types

`components/ui/AuthForms/OauthSignIn.tsx`: `JSX.Element` →
`React.JSX.Element` (the global `JSX` namespace is gone).

### `tsconfig.json`: Next 16's mandatory rewrite

`next build` rewrites `moduleResolution` to `bundler` and `jsx` to
`react-jsx` and adds `.next/dev/types/**/*.ts` to `include`; those three
changes are committed, in the template's formatting. `bundler` resolution
is also what lets `@opennextjs/cloudflare/config` resolve. `target: es5`,
`baseUrl: "."` (the template's bare `utils/...` and `types_db` imports rely
on it) and everything else stay.

### `package.json`

Scripts: `dev` is `next dev` (Next 16 removed `--turbo`; Turbopack is the
default), `lint` is `eslint .` (`next lint` is removed), and `build`,
`preview`, `typecheck` and `wire:fixture` are the port's. The `prettier-fix`,
`stripe:*` and `supabase:*` scripts are as written. Dependencies: `next`
16.3.8, `react` / `react-dom` ^19.2.1, `@supabase/ssr` ^0.12.7,
`@opennextjs/cloudflare`, `wrangler`; devDependencies `eslint` ^9,
`eslint-config-next` 16.3.8, `@types/react*` ^19, `@types/node` ^22. The
template's `eslint-config-prettier`, `eslint-plugin-react` and
`eslint-plugin-tailwindcss` devDependencies are dropped: no eslint config in
the template referenced them (it shipped none). `prettier` and
`prettier-plugin-tailwindcss` stay, as do `.prettierrc.json` and
`.prettierignore`.

### eslint-config-next 16 flat config, with the template's patterns allowed

The template had no eslint config and ran `next lint`, which Next 16
removed. `eslint.config.mjs` is what `create-next-app` writes for Next 16
(`core-web-vitals` + `typescript`), and the rules that set brings and the
template was never written against are off, each named with its reason:
`@typescript-eslint/no-explicit-any`, `@typescript-eslint/ban-ts-comment`,
`@typescript-eslint/no-non-null-asserted-optional-chain`,
`react/no-unescaped-entities`, `no-var`, `prefer-const`;
`react-hooks/rules-of-hooks` only for `components/ui/Navbar/Navlinks.tsx`
and `components/ui/AuthForms/*.tsx` (the `redirectMethod === 'client' ?
useRouter() : null` switch, settled by a constant);
`@typescript-eslint/no-require-imports` only for `*.config.js`, so
`tailwind.config.js` and `postcss.config.js` stay CommonJS as shipped
(supabase-starter converted its `tailwind.config.ts` to an import instead;
here the file is `.js` and `components.json` names it). `types_db.ts` is
ignored by eslint: upstream commits it as UTF-16 LE with a BOM (the
Supabase CLI's output), which eslint's parser rejects as binary and tsc
reads fine. Thirteen warnings remain (`<img>`, unused `error` bindings,
an effect dependency) — the template's, left as written.

### `next.config.mjs` (new)

The template had none. `output: "standalone"` and `outputFileTracingRoot`
= the monorepo root, which `@opennextjs/cloudflare` requires.

### `tests/web/tsconfig.json`

Typechecks the app's files through the test imports under the app's own
strictness (`noUncheckedIndexedAccess` off, `baseUrl` = `apps/web`) rather
than the shared `tooling/tsconfig/web.json` defaults, so the template's
code is not held to rules it was not written against.

### Left as upstream wrote it, on purpose

`getURL()` in `utils/helpers.ts` still falls back to
`NEXT_PUBLIC_VERCEL_URL`; it is unset here, `NEXT_PUBLIC_SITE_URL` is set
first and wins, and the fallback is harmless. `.env.local.example` still
carries the local Supabase CLI's URL and demo anon key. `supabase/`
(config.toml, the migration, seed.sql), `schema.sql`, `fixtures/` and
`types_db.ts` are in `apps/web` for local Supabase-CLI / Stripe-CLI
development; the `@saas/db` runner applies the same SQL in CI. The
`supabase` npm devDependency stays for the `supabase:*` scripts; pnpm 10
blocks its postinstall (the CLI download) and warns at install —
`pnpm approve-builds` once for the local stack. `lucide-react` 0.330.0's
peer range stops at React 18; pnpm warns and the icons render.

### Additions around the template

`proxy.ts` (above), `component.yaml`, `wrangler.template.jsonc`,
`wiring.fixture.json`, `.dev.vars.example`, `open-next.config.ts`,
`turbo.json`, `eslint.config.mjs`, `next.config.mjs` in `apps/web`;
`packages/db` (the control migration + `010_subscriptions_init/up.sql`,
which is `supabase/migrations/20230530034630_init.sql` byte for byte),
`infra/db-migrate`, `infra/terraform/supabase`, `tests/web`, `tests/db`.
The app component depends on `supabase` and `db-migrate` (supabase-starter
depended on `supabase` alone): the pricing page reads the tables the
webhook fills.

### Versions

| Package | Version | Why |
|---|---|---|
| next | 16.3.8 | newest inside `@opennextjs/cloudflare` 1.20.11's range (16.4.x fails at Worker boot) |
| react, react-dom | ^19.2.1 (19.3.1) | Next 16 requires React 19 |
| @supabase/ssr | ^0.12.7 | the template's ^0.1 has the retired cookie API |
| @supabase/supabase-js | ^2.43.4 (2.117.3) | the template's range, resolved fresh |
| stripe | ^14.25.0 (14.25.0) | kept: v14 has `createFetchHttpClient` and `constructEventAsync` |
| @stripe/stripe-js | 2.4.0 | kept |
| @opennextjs/cloudflare | ^1.20.11 | static-assets incremental cache + `populateCache local`; Next 16 `proxy.ts` as Node.js middleware |
| wrangler | ^4.151.0 | current |
| eslint, eslint-config-next | ^9.27 (9.39.5), 16.3.8 | the template's eslint 8 / eslint-config-next 14.1 pair has no Next 16 config |
| typescript | ^5.8.3 (5.9.3) | the template's ^5.4.5 range, bumped with the monorepo |
| tailwindcss | ^3.4.4 (3.4.19) | kept (Tailwind 3) |
| lucide-react | 0.330.0 | kept; React 19 peer warning |
| supabase (CLI) | ^1.172.2 (1.226.4) | kept; postinstall blocked by pnpm 10 |

## Verified

- Local: `pnpm install`, `pnpm run wire:fixture`, `pnpm typecheck`,
  `pnpm lint` (0 errors, 13 warnings), `pnpm test` (19 tests in `tests/web`,
  3 in `tests/db`), `pnpm build` (`@saas/db` to `dist`, the Worker to
  `apps/web/.open-next`) green; `pnpm --filter @saas/db run manifest:check`
  passes; `node packages/db/dist/runner/cli.js plan --env stage` lists
  `000_control_baseline` and `010_subscriptions_init`.
- `wrangler dev` over the built Worker with the fixture vars and a dummy
  `.dev.vars`: `/` 200 (the template's "No subscription pricing plans
  found" state — the fixture host answers nothing), `/signin` 307 →
  `/signin/password_signin`, `/signin/password_signin` and `/signin/signup`
  200 (password, magic-link, third-party and sign-up links present),
  `/account` signed out 307 → `/signin`, `POST /api/webhooks` unsigned 400
  "Webhook secret not found.", with a bad signature 400 "Webhook Error: No
  signatures found matching the expected signature for payload. …"
  (SubtleCrypto verification on workerd), `/nope` 404.
- `terraform init -backend=false && terraform validate` green on
  `infra/terraform/supabase` (supabase/supabase 1.5.1).
- CI: `Checks` green on #2, #3 and #4 (install, wire, typecheck, lint, test,
  build); the Orun `plan` job skips until `ORUN_CI` is set.
- Not verified: an apply of the Supabase root, an apply of the migration
  (both need the product linked to an Orun workspace with Supabase and
  Cloudflare connections), a live deploy, and a real Stripe round-trip
  (Checkout → webhook → `subscriptions` row), which needs the product's
  Stripe keys as Worker secrets and products created through the webhook.
  Supabase's auth Site URL must then be set to the Worker's origin (README).
