# subscription-payments — operating contract (for humans and agents)

This is the standing guide to how this product is deployed and operated.
Instance facts (live URLs, workspace, whether Stripe is connected, the
secrets inventory) live in [deployment.md](deployment.md), rendered from
probed reality by the bootstrap's `02-docs` phase; this file is the contract
that stays true between deployments. It is written to give an agent with
repository read access enough context to reason about and operate the product
without any other source.

## What this system is

Vercel's Next.js Subscription Payments Starter — Supabase Auth (password,
magic link, OAuth) with cookie sessions through `@supabase/ssr`, an account
page, and a Postgres schema of users, customers, products, prices and
subscriptions kept in sync by Stripe's webhooks, Stripe Checkout to subscribe
and the Customer Portal to manage — on Cloudflare Workers, with a Supabase
project per environment, expressed as an Orun component-native desired-state
repo. Six components:

- **`infra/terraform/supabase`** (`supabase`) — one Supabase project per
  environment, its Auth pointed at the app (Site URL, redirect allow-list,
  sign-up confirmation). Its apply publishes `SUPABASE_PROJECT_REF`,
  `SUPABASE_DB_PASSWORD`, `SUPABASE_DB_URL` and `WIRING_SUPABASE` (the
  project URL, the anon key and the service-role key, one document) onto the
  environment's secret rung.
- **`infra/db-migrate`** (`db-migrate`) — applies `packages/db`'s migrations
  to the environment's database through Supabase's Management API. Each
  migration is recorded with its checksum in `_migrations.applied`; only the
  missing ones apply.
- **`packages/db`** (`db`) — the migrations and their runner.
- **`apps/web`** (`web`) — the app: Next.js built by `@opennextjs/cloudflare`
  into one Worker plus Static Assets. It reaches Supabase through
  supabase-js — Auth and the Data API — with the anon key and the visitor's
  session, and with the service-role key for the Stripe webhook's sync and
  the customer mapping (`utils/supabase/admin.ts`).
- **`tests/web`**, **`tests/db`** — vitest suites, verified on the `dev` rung.

Environments: **`stage`** and **`prod`** are deployed; **`dev` is
verify-only by design** — lanes build and test, nothing deploys.

## Identity and tenancy

Every remote operation runs against ONE Orun workspace, declared in
`intent.yaml` under `execution.state.workspace` — committed, enforced, and
what CI uses. Do not remove it; headless credentials depend on it. If it
reads `ws_SET_ME`, the bootstrap had no workspace to write: set the real one
before anything else.

## How deployment works

1. Merge (or push) to `main`.
2. CI (`.github/workflows/ci.yml`) runs `orun plan --changed` — only
   components whose files changed are planned — then runs each planned lane
   with `orun run --remote-state`, authenticated by GitHub OIDC (the
   exchange resolves this repository's linked workspace server-side).
3. Per environment, in this order — each edge `mode: enforced` on a push to
   main, advisory on a pull request (which deploys nothing):
   **`supabase` → `db-migrate` → `web`.** A job resolves its secrets when it
   starts, so each one reads what the apply before it published. The app's
   deploy re-renders `apps/web/wrangler.jsonc` from `WIRING_SUPABASE` before
   it builds (the URL, the anon key and the Worker's origin are inlined into
   the build), pushes the document's service-role key to the Worker as a
   Worker secret (`tooling/wire/secrets.mjs`, `wrangler secret bulk`, the
   value over stdin), deploys `subscription-payments-web-<env>`, and
   smoke-tests it: the pricing page, and `/api/health`, which answers 200
   only when the project is reachable with those keys, the schema is
   migrated, and the service-role secret is the project's own.
4. `prod` deploys after `stage` has converged on the same commit
   (`environments.prod.promotion` in intent.yaml).
5. **The convergence run is the deployment.** A green run means every
   planned lane applied. Failed lanes are retried with
   `gh run rerun --failed`, which resumes the same execution.

Caveats that matter:

- A push that touches no component files plans zero lanes — that run is
  green and deployed nothing. Never treat "latest run green" as "product
  converged"; probe the URLs instead.
- `apps/web/wrangler.jsonc` is committed as the render of
  `wrangler.template.jsonc` from `wiring.fixture.json` (a placeholder project
  URL and key): edit the template and run `pnpm run wire:fixture`. The deploy
  lanes render the real one in their own job tree; never commit a real key.
  The service-role key is never in a wrangler file: it is a Worker secret.
- Every table in `public` has row-level security. Supabase's Data API
  serves `public` to the anon key, which every browser has, so the policies
  ARE the access control: a visitor reads the plans (`products`, `prices`),
  their own `users` row (and updates it) and their own `subscriptions`; the
  user→Stripe-customer map (`customers`) has no policy and is the service
  role's alone. Migration `020_row_level_security` fails the deploy if any
  table in `public` is without RLS; give every new table RLS and the policies
  the app needs in its own migration, and never `FORCE` it.
- A migration is immutable once applied: its checksum is in
  `packages/db/src/manifest.ts` and in the database's ledger. Change the
  schema with a NEW migration in `packages/db/src/migrations` (and the same
  SQL in `apps/web/supabase/migrations` for the Supabase CLI's local stack).

## Secrets model

- **Brokered provider secrets**, minted per run from the workspace's
  connections — no long-lived values at rest, nothing to rotate by hand:
  `CLOUDFLARE_API_TOKEN` (the Worker's deploy and its secrets),
  `CLOUDFLARE_ACCOUNT_ID`, `SUPABASE_ACCESS_TOKEN` (project create, its Auth
  settings, migrations) and `SUPABASE_ORG_ID`.
- **Published by the apply** onto the stage and prod rungs:
  `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`, `SUPABASE_DB_URL`,
  `WIRING_SUPABASE`.
- **The service-role key** bypasses row-level security. It travels only in
  `WIRING_SUPABASE` and reaches the Worker as the Worker secret
  `SUPABASE_SERVICE_ROLE_KEY`, set by every deploy; it is never a wrangler
  var and never in a client bundle (only server code — the webhook and the
  checkout and portal actions — reads it).
- **Worker secrets the owner adds**, because no platform brokers Stripe:
  `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` and `STRIPE_PUBLISHABLE_KEY`
  (below). Until they exist the pricing page shows the template's sample
  plans with checkout off and a "Connect Stripe" notice, the checkout and
  portal actions answer with that notice, and the webhook answers 503.
- Inspect by NAME only: `orun secrets list --org <ws> --project` and
  `--env stage|prod`. No tooling in this repository prints a secret value,
  and no document in `ai/context/` may contain one.

## Connect Stripe

Per environment (`stage`, `prod`), in the Stripe account you want to charge
from (test mode first):

1. Add a webhook endpoint at
   `https://subscription-payments-web-<env>.your-workers-subdomain.workers.dev/api/webhooks`
   listening to the product, price, checkout-session and
   customer-subscription events (`product.*`, `price.*`,
   `checkout.session.completed`, `customer.subscription.*`); copy its signing
   secret.
2. Set the three Worker secrets:

   ```bash
   wrangler secret put STRIPE_SECRET_KEY      --name subscription-payments-web-<env>
   wrangler secret put STRIPE_WEBHOOK_SECRET  --name subscription-payments-web-<env>   # the endpoint's signing secret
   wrangler secret put STRIPE_PUBLISHABLE_KEY --name subscription-payments-web-<env>   # pk_…, public, read per request
   ```

3. Create the products and prices — after the endpoint exists, because they
   reach the database through it: in the dashboard, or
   `pnpm --filter @app/web stripe:fixtures` for the template's Hobby and
   Freelancer plans, monthly and yearly.
4. Configure the Customer Portal (Stripe → Settings → Billing → Customer
   portal).

Worker secrets survive every later deploy; nothing in CI touches them. The
pricing page shows the synced plans with checkout on from the next request.
Re-running the bootstrap's `02-docs` phase records the change in
[deployment.md](deployment.md).

## Supabase Auth email

The supabase root manages three Auth settings and leaves every other one to
the project: the Site URL and the one allowed redirect origin (the
environment's Worker), and whether sign-up needs a confirmed email —
off (`authEmailConfirmation: "false"` in `infra/terraform/supabase/component.yaml`),
because a project without SMTP of its own emails only its organization's
members. Before real users arrive:

1. Give the project an SMTP server (Supabase dashboard → Authentication →
   Emails → SMTP Settings), so confirmation, magic-link and password-reset
   emails reach anyone.
2. Set `authEmailConfirmation: "true"` and merge: new sign-ups then confirm
   their address first (the account page and the magic link already link
   back to the Worker).
3. A custom domain: also change the Site URL and allow-list (the root's
   `app_origin`) and `NEXT_PUBLIC_SITE_URL` in `apps/web/wrangler.template.jsonc`.

OAuth providers (GitHub, Google, …) are dashboard settings of the project;
the sign-in page's OAuth button works once one is enabled there.

## Verifying the system

```bash
# the app and its Supabase path on each environment (also recorded, probed, in deployment.md)
curl -s -o /dev/null -w '%{http_code}\n' https://subscription-payments-web-stage.your-workers-subdomain.workers.dev/
curl -s https://subscription-payments-web-prod.your-workers-subdomain.workers.dev/api/health

# workspace readiness (integrations + repository link)
orun integrations list --org <ws> --json && orun cloud check --org <ws>
```

## Common operations

| task | how |
|---|---|
| deploy a change | merge to `main`; watch the run; failed lanes → `gh run rerun --failed` |
| change the schema | a new `packages/db/src/migrations/<nnn>_<name>/up.sql` and its manifest entry (`pnpm --filter @saas/db run manifest:fix` for its checksum) — with RLS and the policies the app needs on any new table — then merge: db-migrate applies it before the app deploys. `pnpm test` fails on a table in `public` without row-level security; regenerate `apps/web/types_db.ts` with the Supabase CLI |
| redeploy without a change | edit the last line of the component's `component.yaml` (`# orun: redeploy <reason> <stamp>`) and merge — it is a deploy trigger, nothing reads it |
| connect Stripe | above |
| turn on email confirmation | above, "Supabase Auth email" |
| rotate the service-role key | rotate it in the Supabase dashboard (API keys), then re-run the supabase apply (a merge touching `infra/terraform/supabase`): it republishes `WIRING_SUPABASE`, and the next web deploy pushes the new key |
| serve a custom domain | attach it to the Worker in Cloudflare; change `NEXT_PUBLIC_SITE_URL` in `apps/web/wrangler.template.jsonc` and the Auth origin in the supabase root; add the new webhook URL in Stripe |
| headless credentials | `ORUN_TOKEN` (workspace-scoped) + `GITHUB_TOKEN` |

The deployment record is the bootstrap's `02-docs` phase. Re-running it (the
Orun console's Retry on that phase, or `orun new … --phase 02-docs`)
re-probes the URLs and re-renders [deployment.md](deployment.md); it is
idempotent.

## Evolution

Structural changes (a second Worker, a queue, another data store) follow the
same contract that deployed the product: add a component under `apps/`,
`infra/` or `packages/` with a `component.yaml` — declaring `dependsOn` on
any infrastructure whose published secrets it reads, enforced on main — land
it as a pull request, and the convergence run applies it.
