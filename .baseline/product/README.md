# subscription-payments

Vercel's [Next.js Subscription Payments Starter](https://github.com/vercel/nextjs-subscription-payments)
— Supabase Auth with cookie sessions through `@supabase/ssr`, an account
page, a Postgres schema of users, customers, products, prices and
subscriptions kept in sync by Stripe's webhooks, Stripe Checkout to subscribe
and the Customer Portal to manage — on **Cloudflare Workers + Static Assets**
through [`@opennextjs/cloudflare`](https://opennext.js.org/cloudflare), with a
**Supabase** project per environment. Terraform provisions the project and
Orun's `db-migrate` applies the schema, row-level security on every table
included, all on every merge to `main`.

## Live deployment

<!-- 02-docs:begin -->
Not recorded yet. The bootstrap's last phase writes the live URLs, the
workspace, whether Stripe is connected and the secrets the product uses into
[ai/context/deployment.md](ai/context/deployment.md); how the product deploys
and how to operate it is in
[ai/context/operations.md](ai/context/operations.md).
<!-- 02-docs:end -->

## What is here

| Surface | Where |
|---|---|
| The product's name | `apps/web/utils/site.ts` |
| Pricing (`/`), sign-in views (`/signin/[id]`), the account page (`/account`), the auth code exchanges, the Stripe webhook (`/api/webhooks`), `/api/health` | `apps/web/app` |
| Supabase clients (browser, server, admin, the session-refreshing proxy) and their queries | `apps/web/utils/supabase`, `apps/web/proxy.ts` |
| Stripe: the client and whether it is connected, Checkout and the Customer Portal, the sample plans shown before it is | `apps/web/utils/stripe` |
| Workers build and deploy contract | `apps/web/next.config.mjs`, `open-next.config.ts`, `wrangler.template.jsonc` → `wrangler.jsonc`, `component.yaml` |
| The deploy-time wiring: the wrangler render and the Worker-secret push | `tooling/wire` |
| The schema as migrations, and their runner | `packages/db` (`@saas/db`) |
| The Supabase project and the migration step | `infra/terraform/supabase`, `infra/db-migrate` |
| Local development with the Supabase CLI and the Stripe CLI | `apps/web/supabase`, `apps/web/fixtures`, `apps/web/types_db.ts` |
| Tests | `tests/web`, `tests/db` (vitest) |

## Getting started

```bash
pnpm install
pnpm run wire:fixture   # re-render apps/web/wrangler.jsonc from its template (it is committed)
pnpm typecheck
pnpm lint
pnpm test               # tests/db runs every migration in PGlite and checks row-level security
pnpm build              # next build + opennextjs-cloudflare build → apps/web/.open-next
```

The build needs no Supabase project and no Stripe account: it inlines the
placeholder project from the committed `wrangler.jsonc`.

## Running it locally

1. **A Supabase project.** Either the Supabase CLI's local stack
   (`pnpm --filter @app/web supabase:start`, which applies
   `apps/web/supabase/migrations`; pnpm 10 blocks the `supabase` package's
   binary download until you `pnpm approve-builds` it), or a hosted project
   you apply `packages/db/src/migrations` to.
2. **Environment.** Copy `apps/web/.env.local.example` to
   `apps/web/.env.local`: the project URL, anon and service-role keys, and —
   optionally — the Stripe keys. `next dev` reads it:

   ```bash
   pnpm --filter @app/web dev          # http://localhost:3000
   ```

3. **Or the built Worker** under `wrangler dev`, which reads the Supabase URL
   and anon key from `wrangler.jsonc` (point them at your project in
   `wiring.fixture.json` and re-render, or override them in `.dev.vars`) and
   its secrets from `apps/web/.dev.vars` (copy `.dev.vars.example`):

   ```bash
   pnpm build
   pnpm --filter @app/web preview      # http://localhost:8787
   ```

4. **Stripe.** `pnpm --filter @app/web stripe:login`, then forward webhooks
   to the server you are running and create the template's plans:

   ```bash
   pnpm --filter @app/web stripe:listen     # → localhost:3000/api/webhooks
   pnpm --filter @app/web stripe:fixtures   # Hobby and Freelancer, monthly and yearly
   ```

   Test checkout with card `4242 4242 4242 4242`, any future date, any CVC.
   Without Stripe keys everything else runs, and the pricing page says
   checkout is not connected.

## How it deploys

Merges to `main` converge through [Orun](https://github.com/sourceplane/orun):
`.github/workflows/ci.yml` plans the changed components and runs each lane
against the workspace in `intent.yaml`. Per environment the order is
enforced — **the Supabase project, then the migrations, then the Worker** —
because each reads what the one before it published: the project's
credentials, then `WIRING_SUPABASE` (the project URL and anon key the build
inlines, and the service-role key the deploy hands the Worker as a secret).
`stage` deploys first and `prod` once stage has converged on the same
commit; `dev` only verifies. Every deploy is smoke-tested over HTTP,
`/api/health` included, which answers only when the Worker reaches its
migrated project with a valid service-role key.

The pipeline holds one credential, GitHub's own `GITHUB_TOKEN`. The
Cloudflare token and account id and the Supabase access token and org id are
brokered per run from the workspace's connections; the Supabase project's
credentials and keys are published by the Terraform apply as orun secrets.
Nothing provider-shaped is stored in the repository or in GitHub, and the
service-role key is never in a wrangler file or a browser bundle.

Every table in `public` has row-level security, with the template's
policies: a visitor reads the plans and their own user row and subscriptions,
never anyone else's, and the user→Stripe-customer map is the service role's
alone. Migration `020_row_level_security` stops a deploy that would leave a
table without it.

## Connect Stripe

Stripe is a third party no platform brokers, so the product deploys without
it: sign-up, sign-in and the account page work, the pricing page shows the
template's sample plans and says **"Connect Stripe to enable checkout."**,
and the webhook answers 503. To turn payments on, per environment (test mode
first):

1. Add a webhook endpoint at
   `https://subscription-payments-web-prod.your-workers-subdomain.workers.dev/api/webhooks`
   (and `-stage` for stage) for `product.*`, `price.*`,
   `checkout.session.completed` and `customer.subscription.*`.
2. Set the three Worker secrets:

   ```bash
   wrangler secret put STRIPE_SECRET_KEY      --name subscription-payments-web-prod
   wrangler secret put STRIPE_WEBHOOK_SECRET  --name subscription-payments-web-prod   # the endpoint's signing secret
   wrangler secret put STRIPE_PUBLISHABLE_KEY --name subscription-payments-web-prod   # pk_…: public, read per request
   ```

3. Create your products and prices in Stripe — after the endpoint exists,
   so the webhook syncs them into the database — or run
   `pnpm --filter @app/web stripe:fixtures` with that account for the
   template's two plans.
4. Configure the Customer Portal (Stripe → Settings → Billing → Customer
   portal).

Worker secrets survive every later deploy; the next request sees them.

## Supabase Auth email

The Supabase project's Auth sends visitors back to the Worker (its Site URL
and redirect allow-list are set by `infra/terraform/supabase`), and new
sign-ups are signed straight in, because a project without SMTP of its own
emails only its organization's members. Before real users arrive, give the
project an SMTP server (Supabase dashboard → Authentication → Emails → SMTP
Settings), then set `authEmailConfirmation: "true"` in
`infra/terraform/supabase/component.yaml` and merge: sign-up then confirms
the address first, and magic links and password resets reach anyone. OAuth
providers are enabled in the same dashboard.

## Custom domain

The app answers on workers.dev from its first deploy. To serve it on your
own domain, attach the domain to the Worker in Cloudflare (Workers & Pages →
`subscription-payments-web-prod` → Settings → Domains & Routes), set
`NEXT_PUBLIC_SITE_URL` in `apps/web/wrangler.template.jsonc` and the Auth
origin (`app_origin`) in `infra/terraform/supabase/terraform/main.tf` to it,
run `pnpm run wire:fixture`, merge, and point Stripe's webhook at the new
origin. In the same change, replace the reserved placeholder
`subscription-payments.example.com` the product was born with in
`intent.yaml`'s `BASE_DOMAIN` (one line per environment) — the one place the
repository names the domain itself.

## CI

| Workflow | What it runs |
|---|---|
| `ci.yml` | the Orun pipeline, and the only workflow: `orun plan --changed`, then one job per lane. A pull request runs the verify lanes — the app built and dry-deployed for each environment, the Terraform root checked and planned, the migrations planned and their checksums verified — with nothing applied or deployed. It does not typecheck, lint or run the tests: those are the `pnpm` scripts above (Getting started), run them before you push. A merge applies, migrates and deploys stage → prod |
