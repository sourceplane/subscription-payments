# subscription-payments

Vercel's [Next.js Subscription Payments Starter](https://github.com/vercel/nextjs-subscription-payments)
— Supabase Auth with cookie sessions through `@supabase/ssr`, a Postgres
schema of users, customers, products, prices and subscriptions kept in sync
by Stripe webhooks, Stripe Checkout to subscribe and the Customer Portal to
manage — running on **Cloudflare Workers + Static Assets** through
[`@opennextjs/cloudflare`](https://opennext.js.org/cloudflare), with the
Supabase project provisioned by Terraform and its schema applied by the
`db-migrate` runner through [Orun](https://github.com/sourceplane/orun), the
way the [Lumen baseline](https://github.com/sourceplane/lumen) does it.

The template's code is the code, moved to Next 16 / React 19 with only the
changes Next 16 and Workers force (every one is listed in the
[as-built status](specs/epics/subscription-payments/IMPLEMENTATION-STATUS.md)).
What the port adds is the Workers build, the monorepo wrapper, test packages,
the migrations package and the db-migrate component, the Supabase Terraform
root, and the deploy contract that threads the project's URL, keys and the
site origin into the build and the Worker per environment. See
[`specs/epics/subscription-payments`](specs/epics/subscription-payments/README.md)
for the design, the milestones and the as-built status.

## What is here

| Surface | Where |
|---|---|
| Pricing (`/`), sign-in views (`/signin/[id]`), account (`/account`), auth code exchanges, the Stripe webhook (`/api/webhooks`) | `apps/web/app` |
| Supabase clients (browser, server, admin, middleware), Stripe clients and server actions, auth server actions, helpers | `apps/web/utils`, `apps/web/proxy.ts` |
| The schema and the Stripe fixtures, for local Supabase-CLI / Stripe-CLI development | `apps/web/supabase`, `apps/web/schema.sql`, `apps/web/fixtures`, `apps/web/types_db.ts` |
| The same schema as the migration CI applies | `packages/db/src/migrations/010_subscriptions_init/up.sql` (+ `000_control`), `infra/db-migrate` |
| Workers build and deploy contract | `apps/web/next.config.mjs`, `apps/web/open-next.config.ts`, `apps/web/wrangler.template.jsonc`, `apps/web/component.yaml`, `apps/web/.dev.vars.example` |
| The Supabase project (stage, prod) | `infra/terraform/supabase` |
| Tests | `tests/web` (helpers, auth settings, the webhook route's decisions), `tests/db` (manifest, offline plan) — vitest |

## Getting started

```bash
pnpm install
pnpm run wire:fixture   # render apps/web/wrangler.jsonc from the offline fixture
pnpm typecheck
pnpm lint
pnpm test
pnpm build              # packages/db → dist; next build + opennextjs-cloudflare build → apps/web/.open-next
```

To run against a Supabase project and a Stripe test account, copy
`apps/web/.env.local.example` to `apps/web/.env.local` and fill it in (the
Supabase URL, anon and service-role keys; the Stripe publishable, secret and
webhook keys; `NEXT_PUBLIC_SITE_URL=http://localhost:3000`), then:

```bash
pnpm --filter @app/web dev              # http://localhost:3000, Next's dev server
pnpm --filter @app/web stripe:listen    # in another terminal: forwards Stripe events to /api/webhooks
pnpm --filter @app/web stripe:fixtures  # once: two products with monthly and yearly prices
```

To preview the built Worker instead, copy `apps/web/.dev.vars.example` to
`apps/web/.dev.vars` with the three server secrets, then
`pnpm --filter @app/web preview` (or `pnpm exec wrangler dev --config
wrangler.jsonc` in `apps/web`); the rendered `wrangler.jsonc` supplies the
Supabase URL and anon key as vars.

The upstream README (`apps/web/README.md`) describes local development with
the Supabase CLI and Docker (`pnpm --filter @app/web supabase:start`, …).
pnpm 10 blocks the `supabase` package's postinstall, which downloads the CLI
binary; run `pnpm approve-builds` once and pick `supabase` if you want the
local stack (it allow-lists the package in your checkout's
`pnpm-workspace.yaml`; a plain `pnpm rebuild` does not run a blocked script).
CI never needs it: the runner applies the schema.

## How it maps to Vercel

| Vercel | Here |
|---|---|
| Next.js hosting, `middleware.ts` on the edge | One Cloudflare Worker (`.open-next/worker.js`) + Static Assets; the middleware runs in the Worker as `proxy.ts` |
| Project env vars in the dashboard | Build time: `NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY` from orun secrets (inlined by `next build`), `NEXT_PUBLIC_SITE_URL` = the environment's Worker URL. Run time: the two Supabase values as wrangler `vars` rendered per environment from the Supabase root's wiring document; `SUPABASE_SERVICE_ROLE_KEY`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` as Worker secrets |
| A Supabase project created by the Vercel integration | `infra/terraform/supabase`: one project per environment, URL and API keys published as orun secrets |
| The integration running `schema.sql` (or `supabase db push`) | `packages/db` carries the same SQL as migration `010_subscriptions_init`; `infra/db-migrate` plans it on pull requests and applies it on merge through Supabase's Management API |
| Stripe webhook at `https://<deployment>/api/webhooks` | The same route on the Worker: `https://subscription-payments-web-<env>.<subdomain>.workers.dev/api/webhooks` |
| Deploy on push | Orun deploys `subscription-payments-web-{stage,prod}` on merge to `main`, after the Supabase root and the migrations (`apps/web/component.yaml`) |

The anon key is a wrangler var, not a secret: it is shipped to every browser
by design, and Row Level Security is the boundary. The service-role key and
the Stripe secrets are Worker secrets and never appear in a wrangler file.

## Deploying

`.github/workflows/checks.yml` runs install, wire, typecheck, lint, test and
build on every push and pull request. `ci.yml` is the Orun pipeline: set
`execution.state.workspace` in `intent.yaml` to this product's workspace
(`orun cloud link`), connect Cloudflare **and Supabase** to that workspace,
and set the `ORUN_CI` repository variable to `true`. A merge to `main` then
applies the Supabase root, applies the migrations, builds the app with that
environment's URL, key and site origin, and deploys the Worker to `stage`,
then `prod`.

### Stripe (once per environment — the one manual step)

1. In the Stripe dashboard (test mode), create products and prices — or run
   `pnpm --filter @app/web stripe:fixtures` against your account for the
   template's two products with monthly and yearly prices.
2. Add a webhook endpoint at
   `https://subscription-payments-web-<env>.<subdomain>.workers.dev/api/webhooks`
   listening to all events; copy its signing secret (`whsec_…`).
3. Set the Worker's secrets:
   ```bash
   cd apps/web
   wrangler secret put STRIPE_SECRET_KEY     --name subscription-payments-web-<env>
   wrangler secret put STRIPE_WEBHOOK_SECRET --name subscription-payments-web-<env>
   ```
   (or store them as orun secrets the deploy lane reads). The deploy lane
   sets `SUPABASE_SERVICE_ROLE_KEY` from the Supabase root's published
   secret. `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` is public and build-time:
   export it in the component's `buildCommand`; while it is empty the app
   builds and renders, and Checkout is unreachable.
4. Configure the Customer Portal (`Settings → Billing → Customer portal`) as
   the upstream README describes.

Products and prices reach the database through the webhook, so create them
after the endpoint exists; the pricing page shows "No subscription pricing
plans found" until then.

### Supabase auth URLs

After the first apply, set the project's auth **Site URL** and redirect
allow-list (Supabase dashboard → Authentication → URL Configuration) to the
deployed Worker's origin, e.g.
`https://subscription-payments-web-prod.<subdomain>.workers.dev`, so
confirmation, magic-link and recovery emails link back to the app;
`getURL()` already builds those links from `NEXT_PUBLIC_SITE_URL`, which the
build sets to the same origin.
