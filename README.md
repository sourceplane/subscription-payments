# subscription-payments

Vercel's [Next.js Subscription Payments Starter](https://github.com/vercel/nextjs-subscription-payments)
— Supabase Auth with cookie sessions through `@supabase/ssr`, a Postgres
schema of users, customers, products, prices and subscriptions kept in sync
by Stripe webhooks, Stripe Checkout to subscribe and the Customer Portal to
manage — running on **Cloudflare Workers + Static Assets** through
[`@opennextjs/cloudflare`](https://opennext.js.org/cloudflare), with a
**Supabase** project per environment provisioned by Terraform and its schema
applied by the `db-migrate` runner through
[Orun](https://github.com/sourceplane/orun) — the way the
[Lumen baseline](https://github.com/sourceplane/lumen) does it — and
packaged as an **Orun baseline**: one command takes a new product from
nothing to live on stage and prod, in its own repository, under its own
name, in ONE landing.

The template's code is the code, moved to Next 16 / React 19 with only the
changes Next 16 and Workers force. What a fresh, unattended deployment forces
on top: the app reads its Supabase project from ONE wiring document per
environment (`WIRING_SUPABASE`: the URL and anon key the build inlines, and
the service-role key the deploy pushes to the Worker as a secret — never a
var or a bundle); the Stripe client exists only once a key does, so the app
deploys, signs users up and in and renders the account page with no Stripe
account, while pricing shows the template's sample plans and says checkout
is not connected and the webhook answers 503; and every table in `public`
keeps upstream's row-level security, checked by a migration of its own.
What the baseline adds is everything needed to make a copy of it somebody
else's — built the way
[cirrus-baseline](https://github.com/sourceplane/cirrus-baseline) builds a
product, in one landing. See
[`specs/epics/subscription-payments`](specs/epics/subscription-payments/README.md)
for the design, the milestones and the as-built status, including every
departure.

## Instantiating a product

```bash
git clone --depth 1 --branch <baseline-tag> https://github.com/sourceplane/subscription-payments
cd subscription-payments
orun new --blueprint repo-blueprint.yaml --out ~/products/acme-pay --run-hooks --resume \
  --set reponame=acme-pay --set productname="Acme Cloud" \
  --set githuborg=acme-inc --set subdomain=<workers-dev-subdomain>
```

Or, once the platform's registry lists it, from the Orun console (Baselines →
`subscription-payments` → Build). Two phases: **`01-product`** creates the
repository, mints the four brokered credentials (Cloudflare and Supabase)
and lands the whole product as one pull request, whose convergence on
`main` provisions and deploys it per environment in a fixed order —

```
supabase ──▶ db-migrate ──▶ web
```

— each edge `mode: enforced` on a push to main and advisory on a pull
request; then **`02-docs`** records the live deployment from probed facts.
The Supabase organization needs room for **two** projects (stage and prod;
its free plan allows exactly two active ones).
**[BOOTSTRAP.md](BOOTSTRAP.md)** is the operator guide;
[docs/phases/](docs/phases/README.md) has a page per phase.

The new repository receives the **product only** — the app, the Terraform
root, the migrations, the tests, its CI, its tooling, a README of its own
and its operating contract — renamed throughout to the product's name,
repository, Worker and Supabase project. None of this repository's machinery
ships. **Stripe is the owner's to connect afterwards** (the product's README,
"Connect Stripe"): no platform brokers it, so the card asks for no Stripe
key. Neither is Supabase Auth's email: the project signs new users straight
in until its owner gives it SMTP (the product's README, "Supabase Auth
email").

| What makes it a baseline | Where |
|---|---|
| The console card (inputs, secrets, programme) | `blueprint.yaml` |
| The build document (modules, phases, hooks) | `repo-blueprint.yaml` |
| This tree's identity, the product's README and the bootstrap's task contracts | `.baseline/` |
| The rename engine (product-name seam: `apps/web/utils/site.ts`) | `tooling/rebrand/rebrand.mjs` |
| The bootstrap's helpers (deferrals, redeploy marker, work-tree strip) | `tooling/bootstrap/` |
| The deployment-record renderer | `hooks/render-deployment-docs.sh` |
| The product's context pack | `ai/context/` |
| The baseline's tests: contract, leak, offline bootstrap and plans, end to end | `testing/`, `.github/workflows/baseline.yml` |
| Cutting a `baseline-vN` tag | `.github/workflows/tag.yml` |

## What is here (the product)

| Surface | Where |
|---|---|
| The product's name | `apps/web/utils/site.ts` |
| Pricing (`/`), sign-in views (`/signin/[id]`), the account page (`/account`), the auth code exchanges, the Stripe webhook (`/api/webhooks`), `/api/health` | `apps/web/app` |
| Supabase clients (browser, server, admin, the proxy), Stripe (whether it is connected, Checkout, the portal, the sample plans), auth server actions, helpers | `apps/web/utils`, `apps/web/proxy.ts` |
| The schema and the Stripe fixtures, for local Supabase-CLI / Stripe-CLI development | `apps/web/supabase`, `apps/web/schema.sql`, `apps/web/fixtures`, `apps/web/types_db.ts` |
| The same schema as the migrations CI applies, and row-level security checked | `packages/db/src/migrations` (`010_subscriptions_init`, `020_row_level_security`), `infra/db-migrate` |
| Workers build and deploy contract | `apps/web/next.config.mjs`, `open-next.config.ts`, `wrangler.template.jsonc` → `wrangler.jsonc` (committed), `component.yaml` |
| The deploy-time wiring: the wrangler render and the Worker-secret push | `tooling/wire` |
| The Supabase project (stage, prod) and its Auth settings | `infra/terraform/supabase` |
| Tests | `tests/web`, `tests/db` (vitest; `tests/db` runs every migration in PGlite and checks row-level security) |

## Getting started

```bash
pnpm install
pnpm run wire:fixture   # re-render apps/web/wrangler.jsonc from its template (committed; this changes nothing)
pnpm typecheck
pnpm lint
pnpm test
pnpm build              # packages/db → dist; next build + opennextjs-cloudflare build → apps/web/.open-next
```

The build needs no Supabase project and no Stripe account. Running it
locally — the Supabase CLI's stack or a hosted project, `.env.local`,
`next dev` or `wrangler dev`, the Stripe CLI — is in the product's README
(`.baseline/product/README.md`), which is what a product built from here
carries.

## How it maps to Vercel

| Vercel | Here |
|---|---|
| Next.js hosting, `middleware.ts` on the edge | One Cloudflare Worker (`.open-next/worker.js`) + Static Assets; the middleware is `proxy.ts` (Next 16's name) and runs in the Worker |
| Project env vars set by the Supabase integration | `WIRING_SUPABASE` per environment: the URL and anon key as wrangler vars the build inlines, the service-role key a Worker secret every deploy pushes |
| The integration running `schema.sql` (or `supabase db push`) | `infra/db-migrate` applies `packages/db/src/migrations` through Supabase's Management API per environment, after the project exists, before the Worker deploys |
| Stripe keys in the project's env vars | Worker secrets the owner adds when ready; until then pricing shows the sample plans and checkout says it is not connected |
| The Supabase project's Site URL, set by hand | `infra/terraform/supabase` sets it (and the redirect allow-list) to the Worker |
| A Supabase project created by the integration | `infra/terraform/supabase` (one project per environment), credentials and keys as orun secrets |
| "Deploy with Vercel" (clone the template) | `orun new --blueprint repo-blueprint.yaml` — a new repository, branded, provisioned, deployed |

## CI

| Workflow | What it runs | Ships to a product |
|---|---|---|
| `checks.yml` | install, wire fixture, typecheck, lint, test, build — every PR (not pushes: on main, `ci.yml` must be the only run a commit has, because the bootstrap's convergence watch takes the newest one) | yes |
| `ci.yml` | the Orun pipeline: `orun plan --changed`, then one job per lane; applies, migrates and deploys stage → prod on merge. It plans nothing while `intent.yaml` names the placeholder workspace `ws_CHANGE_ME`, as this repository does | yes |
| `baseline.yml` | the baseline's own tiers: contract tests; the blueprint read by the pinned orun, the leak gate, the offline bootstrap and the product's own plans; the product built, migrated into a local Supabase (its real Auth and Data API), dry-deployed, served and signed up, out and in on | no |
| `tag.yml` | cuts a `baseline-vN` tag (manual) | no |
