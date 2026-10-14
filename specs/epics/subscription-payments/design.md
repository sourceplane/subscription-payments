# subscription-payments — design

## 1. What the template is

Next.js App Router + Supabase Auth + Supabase Postgres + Stripe.
`utils/supabase/{client,server,middleware}.ts` build the browser, server and
middleware clients from `NEXT_PUBLIC_SUPABASE_URL` and
`NEXT_PUBLIC_SUPABASE_ANON_KEY`; `utils/supabase/admin.ts` builds the
service-role client from `SUPABASE_SERVICE_ROLE_KEY` for the webhook's
upserts and the user→Stripe-customer mapping. `middleware.ts` calls
`updateSession`, which refreshes the auth cookie on every request.
`utils/stripe/{config,server,client}.ts` are the Stripe server client
(`STRIPE_SECRET_KEY`), the Checkout and Customer Portal server actions, and
Stripe.js (`NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY`). `app/api/webhooks/route.ts`
verifies `STRIPE_WEBHOOK_SECRET` signatures and syncs products, prices and
subscriptions into Postgres. Pages: `/` (pricing, reads `products` and
`prices`), `/signin/[id]` (password, magic link, OAuth, forgot/update
password, sign-up), `/account` (name, email, Customer Portal), the
`/auth/callback` and `/auth/reset_password` code exchanges. The schema is
`supabase/migrations/20230530034630_init.sql` (= `schema.sql`): `users`,
`customers`, `products`, `prices`, `subscriptions`, the `auth.users` trigger,
RLS policies, the realtime publication. `fixtures/stripe-fixtures.json`
creates two products with monthly and yearly prices through the Stripe CLI.
Tailwind 3, Radix toast, `getURL()` for every absolute URL.

## 2. The mapping (Vercel → Cloudflare + Supabase)

| Vercel primitive the template uses | Here |
|---|---|
| Next.js hosting: Serverless Functions for SSR, server actions and route handlers | Cloudflare Workers + Static Assets; the Worker is `@opennextjs/cloudflare`'s output, assets bound as `ASSETS` |
| `middleware.ts` on the edge | `proxy.ts` (Next 16's name for it), bundled by OpenNext as Node.js middleware inside the same Worker; same matcher, same `updateSession` |
| Project env vars set in the Vercel dashboard (the Supabase integration sets the three Supabase ones) | Build time: `component.yaml` `secretEnv` maps the `supabase` root's `SUPABASE_URL` / `SUPABASE_ANON_KEY` to `NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY` (the template's names) so `next build` inlines them, and `NEXT_PUBLIC_SITE_URL` is the environment's Worker URL. Run time: the same two Supabase values as wrangler `vars`, rendered per environment from the root's wiring document; `SUPABASE_SERVICE_ROLE_KEY`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` as Worker secrets |
| `NEXT_PUBLIC_VERCEL_URL`, the fallback in `getURL()` | Left in place, unset and harmless: `NEXT_PUBLIC_SITE_URL` is set first and wins |
| A Supabase project created by hand or by the Vercel integration | `infra/terraform/supabase` (Lumen's root): one project per environment, keys read with `supabase_apikeys`, published as orun secrets and a wiring document |
| `supabase db push` / the integration running the SQL migration | `packages/db` (`@saas/db`, Lumen's runner) carries `init.sql` verbatim as migration `010_subscriptions_init`; `infra/db-migrate` plans it on pull requests and applies it on merge through Supabase's Management API, after the project exists |
| Stripe webhook endpoint `https://<deployment>.vercel.app/api/webhooks` | The same route on the Worker: `https://subscription-payments-web-<env>.<subdomain>.workers.dev/api/webhooks`; signatures verified with `constructEventAsync` + SubtleCrypto |
| Deploy on push | Orun: `apps/web/component.yaml` (`cloudflare-workers-assets-turbo`) deploys `subscription-payments-web-{stage,prod}` on merge to `main`, after `supabase` and `db-migrate` |

## 3. The env and secret flow

```
infra/terraform/supabase ──apply──► orun secrets (project/<env> rung)
   outputs: project_ref, db password,    SUPABASE_PROJECT_REF, SUPABASE_DB_PASSWORD, SUPABASE_DB_URL,
            project_url, anon_key,       SUPABASE_URL, SUPABASE_ANON_KEY,
            service_role_key, wiring     SUPABASE_SERVICE_ROLE_KEY, WIRING_SUPABASE
                                               │                         │
infra/db-migrate secretEnv ◄───────────────────┘                         │
   SUPABASE_PROJECT_REF (+ SUPABASE_ACCESS_TOKEN brokered per run)       │
   → node dist/runner/cli.js apply --env <env>                           │
                                                                         │
apps/web/component.yaml secretEnv ◄──────────────────────────────────────┘
   NEXT_PUBLIC_SUPABASE_URL / NEXT_PUBLIC_SUPABASE_ANON_KEY → next build (inlined)
   SUPABASE_SERVICE_ROLE_KEY                                → Worker secret (admin client)
   WIRING_SUPABASE_<ENV>                                    → tooling/wire/live.mjs → wrangler.jsonc vars
   buildCommand: NEXT_PUBLIC_SITE_URL=https://subscription-payments-web-<env>.<subdomain>.workers.dev

the product, once per environment (the one manual step):
   STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET  → Worker secrets (`wrangler secret put` on
                                               subscription-payments-web-<env>, or orun secrets the deploy lane reads)
   NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY        → a build-time public value to export in buildCommand
                                               (empty is a valid build: Checkout is unreachable until set)
```

`wrangler.template.jsonc` carries `@@wiring(supabase/__ENV__:…)@@` tokens for
the two public Supabase values. The verify lane (and `pnpm run wire:fixture`)
renders it from `wiring.fixture.json`; the deploy lane renders it from the
live document for `$ORUN_ENVIRONMENT`. The rendered `wrangler.jsonc` is
git-ignored. The three server secrets are never in a wrangler file:
`.dev.vars.example` lists them for `wrangler dev`, and `.dev.vars` is
git-ignored.

A build with no values at all (Checks, a fresh clone) is a valid build of the
un-configured app: `NEXT_PUBLIC_*` reads that are unset at build time stay
runtime lookups, so `wrangler dev` over that build reads the fixture vars,
and the pricing page renders its own "no plans found" state.

## 4. Stripe on Workers

Two things in `stripe-node` assume Node: its default HTTP client (`http`)
and synchronous webhook signature verification (`crypto.createHmac`).
Workers have `fetch` and `crypto.subtle`, and stripe-node has shipped
adapters for both since v8:

- `utils/stripe/config.ts` passes `httpClient: Stripe.createFetchHttpClient()`.
- `app/api/webhooks/route.ts` calls
  `await stripe.webhooks.constructEventAsync(body, sig, secret, undefined,
  Stripe.createSubtleCryptoProvider())` instead of `constructEvent`.

Nothing else in the Stripe code changes; `stripe` stays on the template's
v14 (`^14.25.0`), which has both, and `@stripe/stripe-js` stays at `2.4.0`.
The webhook endpoint is the same path on the Worker's origin; Stripe's
`stripe listen --forward-to=localhost:3000/api/webhooks` works against
`next dev` exactly as upstream documents.

The service-role client in `utils/supabase/admin.ts` is built per call
rather than at module scope. On Workers the environment is populated per
request, and a credential-free `next build` evaluates the webhook route
while collecting page data — a module-level `createClient('', '')` throws
there. Per-call construction is also what Supabase documents for serverless.

## 5. The repository

```
apps/web                      the template (app/, components/, utils/, styles/, public/, fixtures/, supabase/, schema.sql, types_db.ts) + the Workers build
  proxy.ts                    middleware.ts under Next 16's name; utils/supabase/middleware.ts keeps its name
  component.yaml              build with turbo after rendering wrangler; NEXT_PUBLIC_SITE_URL = the Worker URL; deploy with wrangler; smoke /
  wrangler.template.jsonc     worker name, nodejs_compat, ASSETS, the two public Supabase vars as wiring tokens
  wiring.fixture.json         offline values for the verify lane
  .dev.vars.example           the three Worker secrets, for wrangler dev
  open-next.config.ts         static-assets incremental cache (pre-rendered shells), no R2/KV/D1
packages/db                   @saas/db: the control migration + 010_subscriptions_init (init.sql verbatim), the Management-API runner
infra/db-migrate              plan on PRs, apply on merge, after supabase
infra/terraform/supabase      the Supabase project per environment (Lumen's root + API keys + wiring document)
tests/web                     vitest: getURL, trial-end, toDateTime, the toast redirects, the auth settings, the webhook route's 400 paths (mocked stripe + admin)
tests/db                      vitest: manifest checksums, offline plan, applied-skip
```

`apps/web/supabase/` (config.toml, the migration, seed.sql), `schema.sql`,
`fixtures/` and `types_db.ts` stay where upstream has them, for local
development with the Supabase CLI and Docker exactly as the upstream README
describes (`pnpm supabase:start`, `supabase:generate-types`, …). The runner
is what CI uses: the same SQL, applied once, recorded in
`_migrations.applied`.

## 6. Out of scope

OAuth provider setup (GitHub in `supabase/config.toml` is for local dev;
the hosted project's providers are dashboard settings), custom SMTP for
auth emails, Stripe live mode and its separate webhook, a custom domain,
and Supabase's auth `Site URL` / redirect allow-list, which Terraform's
`supabase_project` does not set — the README names the values.

## 7. Alternative rejected: keeping `supabase db push` (or drizzle-kit) in CI

The template's own path is the Supabase CLI: `supabase link` then
`supabase db push` from `supabase/migrations`. Running that in CI would need
the CLI binary (a postinstall download pnpm 10 blocks by default), a linked
project ref and database password on the runner, a direct Postgres
connection (IPv6-only on the free tier, so a pooler too), and the CLI's own
`supabase_migrations.schema_migrations` bookkeeping, which nothing else in
the baseline reads. Lumen's runner applies the same SQL through the
Management API with the per-run token the platform already brokers for the
Terraform root, records what it applied in `_migrations.applied` with a
checksum the tests verify, and plans on every pull request for free. The
CLI stays for local development, where it is good; CI uses the runner.
