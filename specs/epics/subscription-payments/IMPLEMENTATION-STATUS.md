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
| SP5 — a baseline | ✅ Shipped | [#6](https://github.com/sourceplane/subscription-payments/pull/6) (SP-6), tagged `baseline-v1` |
| SP6 — the cirrus standard | ✅ Shipped | [#7](https://github.com/sourceplane/subscription-payments/pull/7) (SP-7), [#8](https://github.com/sourceplane/subscription-payments/pull/8) (SP-8), tagged `baseline-v2` |

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

## SP5 — a baseline (SP-6)

The repository is an Orun baseline on the Lumen conventions, built the way
cirrus-baseline v22 builds a product: ONE landing, after the saas-starter
reference (SA5) without its Hyperdrive. `blueprint.yaml` is the card
(`requires: [github, cloudflare, supabase]`; the four brokered keys —
`CLOUDFLARE_API_TOKEN` workers-deploy, `CLOUDFLARE_ACCOUNT_ID` account-id,
`SUPABASE_ACCESS_TOKEN` management-access, `SUPABASE_ORG_ID` org-id — as a
preview; programme `01-product`, `02-docs`; the two-Supabase-projects
prerequisite in its description); `repo-blueprint.yaml` places every module
in `01-product`, brands it, links the repository, reconciles the four keys
and lands it as one pull request, then awaits the convergence, the four
published secrets (`SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`,
`SUPABASE_DB_URL`, `WIRING_SUPABASE`) on stage and prod and `/` +
`/api/health`; `02-docs` restores the promotion gate and dev's lanes and
renders the record. The machinery is portfolio-starter-kit's (`baseline-v2`)
as saas-starter adapted it — `.baseline/`, the rename engine, the bootstrap
helpers, the deployment-record hook, `ai/context/`, `testing/`,
`baseline.yml`, `tag.yml`, `ci.yml`'s `linked` gate.

### Departures, in the product

- **Stripe is optional** (`utils/stripe/config.ts`). Upstream built the
  client at module load from `STRIPE_SECRET_KEY_LIVE ?? STRIPE_SECRET_KEY ??
  ''`. `getStripe()` builds it only once a key exists; without one the
  pricing page (`app/page.tsx`) shows the plans — the database's, or, while
  the webhook has synced none, the template's sample plans
  (`utils/stripe/sample-plans.ts`, held equal to `fixtures/stripe-fixtures.json`
  by `tests/web`) — with the Subscribe buttons disabled and "Connect Stripe to
  enable checkout"; `checkoutWithStripe` and `createStripePortal` answer with
  the "Stripe is not connected." toast redirect; the webhook answers 503
  `{"error":"Stripe is not connected."}` until the secret key and
  `STRIPE_WEBHOOK_SECRET` are both set (it answered 400 "Webhook secret not
  found." before). With Stripe connected and no products synced, the page is
  upstream's "No subscription pricing plans found".
- **The publishable key is read per request** (`STRIPE_PUBLISHABLE_KEY`, a
  Worker secret, then upstream's `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY[_LIVE]`)
  and handed to `Pricing` as a prop; `getStripe()` in `utils/stripe/client.ts`
  takes it. Upstream inlined it at build, which would have made connecting
  Stripe a rebuild. Checkout is on only with both halves.
- **The Supabase values come from one wiring document.** The supabase root
  publishes `WIRING_SUPABASE` = `{supabase_url, supabase_anon_key,
  supabase_service_role_key}` beside Lumen's three database credentials, and
  no longer publishes `SUPABASE_URL`, `SUPABASE_ANON_KEY` or
  `SUPABASE_SERVICE_ROLE_KEY` on their own. The web component reads only
  `WIRING_SUPABASE_<ENV>`, scoped to its own environment (stage resolves the
  stage document, prod the prod one, dev none — Lumen's per-environment
  `secretEnv`). Its `buildCommand` re-renders `wrangler.jsonc` from it (the
  URL, the anon key, and `NEXT_PUBLIC_SITE_URL` = the Worker's origin), builds
  — `next.config.mjs` inlines those three vars from `wrangler.jsonc`, so the
  browser and the Worker always talk to the same project — and pushes the
  service-role key with `wrangler secret bulk`, the value over stdin
  (`tooling/wire/secrets.mjs`; only the deploy profile holds a Cloudflare
  credential, so verify lanes push nothing). Before, the build read
  `NEXT_PUBLIC_SUPABASE_*` from separate secrets, nothing pushed the
  service-role key to the Worker, and `NEXT_PUBLIC_SITE_URL` was built from
  `WORKERS_DEV_SUBDOMAIN`, which the composition exports only to the smoke
  step — so it came out as `https://…-web-stage..workers.dev`.
- **The supabase root points the project's Auth at the app**
  (`supabase_settings`): the Worker's origin as Site URL and the one allowed
  redirect, and `mailer_autoconfirm` on unless `authEmailConfirmation` is
  `"true"`, because a project without SMTP of its own emails only its
  organization's members — with confirmation on, nobody else could finish a
  sign-up. It waits for the project to report `ACTIVE_HEALTHY` before reading
  its keys or writing its Auth config (`terraform_data.project_ready`).
  Every other Auth setting stays the project's. (SP-C is resolved by this.)
- **Row-level security, checked** (migration `020_row_level_security`):
  upstream's `init.sql` (010) already enables RLS on all five tables with its
  policies — own `users` row (select, update), public `products` and
  `prices`, own `subscriptions`, no policy on `customers`. 020 re-enables it
  by name and then RAISES if any table in `public` is without RLS, so a
  deploy that would serve one to the anon key stops at db-migrate.
  `tests/db` runs every migration in PGlite over a stub of Supabase's `auth`
  schema and roles and checks the catalog, the policies and what anon, a
  signed-in user and the service role can read and write; the e2e asks the
  real Data API.
- **`/api/health`** (new): 200 only when the anon key reads `products` (the
  project reachable, the schema migrated) and the service-role key lists
  Auth's users (the secret the deploy pushed is the project's own). The
  deploy's smoke and both phases' probes read it.
- **The product's name is one seam** (`utils/site.ts`, `SITE_NAME`): every
  page's `<title>` (upstream: "Next.js Subscription Starter"), the footer's
  brand and its copyright line (upstream's literal "ACME"). The template's own
  identity — `nextjs-subscription-payments` (its repository, the Stripe app
  info, the Supabase CLI project id) and its demo site — stays upstream's;
  the rename engine protects it, and every migration.
- **`apps/web/wrangler.jsonc` is committed** — the fixture render of the
  template — because the composition checks for it before the build. The
  stage and prod lanes re-render it; dev verifies with the fixture.
  `tests/web` holds the two equal and the service-role key out of both.
- **The deploy order is enforced on main** (component `dependsOn` with
  `mode: enforced` and an advisory `modeRules` entry for pull requests):
  `db-migrate` → `supabase`; `web` → `supabase`, `db-migrate`.
- **The supabase root carries Lumen's `.terraform.lock.hcl`**.
- **stack-tectonic 0.19.0** (was 0.18.2; not 0.20.0, whose lane-scoped
  install Turbopack refuses), **`checks.yml` on pull requests only**,
  `ci.yml`'s `linked` gate in place of the `ORUN_CI` variable and its lanes on
  v2.78.4.
- `packages/db`'s runner reads `SUPABASE_API_URL` (default
  `https://api.supabase.com`) so the e2e can point it at a stand-in.
- `apps/web/README.md` describes the app as it runs here (upstream's text is
  upstream's repository); `intent.yaml`'s docs pages are the product's
  `ai/context/` pages; `tests/web` depends on `@supabase/supabase-js` (to mock
  it) and `tests/db` on `@electric-sql/pglite` 0.5.8 (pinned by override).

### Verified (SP5)

See the pull request for the run log. In short: the repository's checks
(`pnpm install --frozen-lockfile`, `wire:fixture`, typecheck, lint, test —
53 tests: 42 in `tests/web`, 11 in `tests/db` — build); every
`testing/*.test.sh` — the e2e over the real Supabase Auth (GoTrue 2.180.0)
and Data API (PostgREST 12.2.12) on a local Postgres; `orun new --status` at
v2.58.11, v2.78.4 and 2.79.0; `orun validate`; `orun work check`;
`terraform fmt`, `init -backend=false` and `validate` on the supabase root.
Not verified: a Terraform apply (the project, its API keys and its Auth
settings through the brokered OAuth token — SP-M), a db-migrate apply
against a real project, the `wrangler secret bulk` push and a deploy to a
real account, a live bootstrap, and checkout against a real Stripe account.

## The cirrus standard (SP6)

Nothing about the app changed. What changed is the baseline around it:

| What | Before | After | Why |
|---|---|---|---|
| orun pin | `kiox.yaml` (v2.15.0) + `kiox.lock`, shipped to every product | gone; orun is pinned where it runs, the `orun-action` `version:` in each workflow | nothing ran the kiox pin, and it disagreed with the lanes (v2.78.4) |
| `root-kiox`, `root-kiox-lock` modules | in `01-product` | removed (`testing/phases.test.sh` and the rebrand's skip list follow) | a product is placed with 181 files: 165 − 2 kiox + 18 docs pages |
| component docs | none | `docs/overview.md`, `architecture.md`, `runbook.md` beside each of the six `component.yaml` | cirrus-baseline documents every component; the workspace Docs library renders `docs/` beside each manifest |
| how the docs stay true | — | `tooling/catalog/gen-component-docs.py` derives them from the manifest, the Worker config, Terraform, migrations and package scripts; Baseline CI runs it with `--check` | a hand-written copy of a manifest drifts silently |
| context pack | `operations.md`, `deployment.md` | plus `current.md`, `decisions.md`, `open-risks.md` | cirrus-baseline's shape; the three new pages are this repository's own and no module places them (the leak gate still allows exactly two) |
| status | SP5 "in review", on a branch | SP5 shipped and tagged `baseline-v1` | the tag existed; the documents had not caught up |

### The subdomain from the Cloudflare connection (SP-8)

`subdomain` was the one input an operator typed that the platform could
answer itself: it belongs to the Cloudflare account the same way its id does,
and it has exactly one right answer. A typed one could only be wrong, and
wrong showed up after deploy — in the origin Stripe and Supabase Auth send
visitors back to, the deploy's smoke, the phase probes and the console's
verify URLs. `blueprint.yaml` now declares
`from: connection.cloudflare.workersSubdomain`, as cirrus-baseline does since
baseline-v23: the Cloudflare integration reads the subdomain at connect and on
its hourly health check, and the bootstrap door fills the input from the
connection the build is bound to — the same one `CLOUDFLARE_ACCOUNT_ID` and the
deploy tokens mint from. The console renders no field for it, and an account
with no workers.dev subdomain is refused at the door with the fix named.

- `testing/manifest.test.sh` takes cirrus-baseline's rule verbatim: the source
  is accepted, and only when `spec.requires.integrations` lists its provider.
- `repo-blueprint.yaml` keeps the input and its default; it, `BOOTSTRAP.md`
  and `docs/phases/README.md` say only a hand-run build passes
  `--set subdomain`.
- Nothing a product carries changes: the rename writes the value where it
  always did (`workersDevSubdomain` on the web and Supabase components, the
  site URL, the URLs), and the probes read it as before.

Verified:

- `testing/{manifest,phases,coverage,rebrand,retouch,bootstrap-defer}.test.sh`
  green; `gen-component-docs.py --check` green (6 components).
- Mutation: with `cloudflare` dropped from `spec.requires.integrations`,
  `manifest.test.sh` fails with exactly one finding, naming
  `inputs[subdomain]`; restored, it passes.
- At v2.58.11 (the blueprint job's pin, placement included):
  `orun new --status` reads the document (`01-product` pending, 181 files);
  `testing/leak.test.sh` 181 files derived, 174 text files read;
  `testing/placement.test.sh` 181 files placed, both landings, the product's
  own plan orders supabase → db-migrate → web on stage and prod; `--resume`
  changes nothing.
- `orun task check SP-8` complete.

## Verified (SP6)

- `testing/{manifest,phases,coverage,rebrand,retouch,bootstrap-defer}.test.sh`
  green; `gen-component-docs.py --check` green (6 components, 18 pages).
- `orun new --status` at v2.58.11: `01-product` 181 files, `02-docs`
  hook-only.
- `testing/leak.test.sh` at v2.58.11: 181 files derived, 174 text files
  read; ai/context still exactly the two declared pages; the generated pages
  name no factory path.
- `testing/placement.test.sh` at v2.58.11: 181 files placed, both landings,
  branded, re-tenanted; the product's own plan orders supabase → db-migrate →
  web on stage and prod, enforced; `--resume` changes nothing.
- `pnpm install --frozen-lockfile`, `wire:fixture` (the tree unchanged),
  `typecheck`, `lint`, `test` (53 tests: 42 in `tests/web`, 11 in
  `tests/db`), `build` green.
- `testing/e2e.test.sh` at v2.78.4 green: the stage db-migrate and web lanes
  in staged job trees over a local Supabase (GoTrue v2.180.0, PostgREST
  v12.2.12); `wrangler dev` with the service-role key as its one secret; a
  sign-up, the account page, checkout and the portal saying Stripe is not
  connected, a sign-out and a sign-in; 0 of 5 public tables without RLS.
- `orun task check SP-7` complete.
