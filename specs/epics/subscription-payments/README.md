# Epic: subscription-payments (SP)

**Vercel's subscription-payments starter is the template that exercises everything the Lumen baseline brokers at once: Supabase Auth for the session, a Postgres schema the app reads with Row Level Security and writes with the service-role key, and Stripe for money — Checkout to subscribe, the Customer Portal to manage, webhooks to keep products, prices and subscriptions in sync. None of that cares whether the server is a Vercel function or a Cloudflare Worker. The port keeps the code and moves the three things that are Vercel's: where the app runs (an OpenNext Worker + Static Assets), where the Supabase project and its schema come from (Terraform and the db-migrate runner through Orun, from the template's own `init.sql`), and how its env vars reach the build and the Worker (build-time secretEnv, wrangler vars, Worker secrets).**

The upstream code stays the code: the `@supabase/ssr` clients and the session-refreshing middleware, the auth forms and server actions, the pricing page, the account page with the Customer Portal, the Stripe server actions and the webhook handler, the SQL schema, the Stripe fixtures. What Next 16 and Workers force is changed and nothing else: `middleware.ts` is `proxy.ts`, the cookie adapters use `@supabase/ssr` 0.12's `getAll`/`setAll`, `cookies()` and page `params` are awaited, Stripe talks over `fetch` and verifies webhook signatures with SubtleCrypto, and the service-role client is built per call. The port adds the Workers build, the monorepo wrapper, test packages for the template's helpers and the webhook route's decisions and for the migration manifest, the migrations package and the db-migrate component, the Supabase Terraform root, and the deploy contract that threads the project's URL, keys and the site origin into the build and the Worker per environment.

## Status

| Field | Value |
|-------|-------|
| Status | ✅ SP0–SP4 shipped (#1–#5) · 🔄 SP5 — a baseline (SP-6) in review. The Supabase and migration applies and a live deploy are gated on a linked workspace; Stripe keys are the product owner's |
| Cluster | **SP** (SP0–SP5) |
| Owner(s) | `apps/web` (the app) · `tests/web` (helper and webhook tests) · `packages/db` + `infra/db-migrate` + `tests/db` (the schema) · `infra/terraform/supabase` (the project) |
| Builds on | `lumen` conventions — the `supabase` Terraform root, the `@saas/db` runner and `db-migrate` component, the orun-secrets wiring; `supabase-starter` for the app-on-Workers shape; `cirrus-baseline` conventions for the repository shape |
| Upstream | [vercel/nextjs-subscription-payments](https://github.com/vercel/nextjs-subscription-payments) (sunset upstream in favour of `nextjs/saas-starter`; ported as it stands) |
| Changes | Adds the Workers build, the monorepo wrapper, tests, the migrations package, the db-migrate component, the Supabase root and the deploy contract; the template's code changes only where Next 16 / Workers force it (every change is in `IMPLEMENTATION-STATUS.md`) |
| Decisions locked | (1) OpenNext on Workers + Static Assets. (2) The anon key is a wrangler var, not a secret: RLS protects the data; the service-role key and the Stripe secrets are Worker secrets — the service-role key pushed by every deploy from `WIRING_SUPABASE` (SP5), the Stripe keys added by the owner when ready, the app deploying and serving without them (SP5). (3) `wrangler.jsonc` rendered from the template: committed as the fixture render (the composition checks it exists before the build), re-rendered per environment from the wiring document by the deploy lanes, which the build inlines (SP5; it was never committed before). (4) The schema is applied by the `@saas/db` runner through Supabase's Management API, from the template's `init.sql` verbatim — not by `supabase db push` in CI — then RLS checked on every table (`020`, SP5). (5) No Hyperdrive: the app speaks PostgREST over HTTPS, never a Postgres socket. (6) `stripe` stays on v14: it already has the fetch client and async webhook verification. (7) Infra before app on main: supabase → db-migrate → web, enforced; advisory on pull requests (SP5). |
| Gate | SP1 is the first user-visible rung. SP2 and SP3 need a workspace with a Supabase connection to apply; they are verified by `plan` / `terraform validate`. Checkout and the webhook need the product's Stripe keys as Worker secrets (the one manual step, see `design.md` §3). |
| Shipped as | `main` after [#5](https://github.com/sourceplane/subscription-payments/pull/5); verified locally under `wrangler dev` with fixture vars and dummy Worker secrets |

## Read order

1. `design.md` — what maps to what, the env/secret flow, Stripe on Workers, what is out of scope, the rejected alternative
2. `implementation-plan.md` — the milestones and what "done" means for each
3. `risks-and-open-questions.md` — what could go wrong and what was decided
4. `IMPLEMENTATION-STATUS.md` — what actually shipped (kept distinct from intent)

## Milestones at a glance

| Milestone | What it lands | Done when |
|---|---|---|
| SP0 — the spec | this doc set and the task contracts | merged on `main` |
| SP1 — the app on Workers | `apps/web` built by OpenNext on Next 16, rendered wrangler config, `.dev.vars.example`, `tests/web` | `wrangler dev` serves `/`, redirects `/signin` and a signed-out `/account`, answers an unsigned webhook 400; Checks green |
| SP2 — the schema through db-migrate | `packages/db` with the template's `init.sql` as migration 010, `infra/db-migrate`, `tests/db` | `manifest:check` and the offline plan list both migrations; Checks green |
| SP3 — the Supabase project from Terraform | `infra/terraform/supabase`, the app's `secretEnv` and `dependsOn` it completes | the root validates; the secret and wiring keys match the component |
| SP4 — ready to instantiate | README, as-built status | a reader can run, test, preview, configure Stripe and deploy it |
| SP5 — a baseline | card, build document, rename, bootstrap tooling, the product's README and context pack, tests | a new product goes from nothing to live on stage and prod in one landing, with no Stripe key, every table behind RLS; Baseline CI green |
