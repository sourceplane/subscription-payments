# subscription-payments — risks and open questions

## SP-A — The init migration is not idempotent (RISK, accepted and documented)

The template's `init.sql` is plain `create table` / `create type` /
`create policy`, and the Management-API runner applies each migration's
statements in autocommit mode — there is no transaction to roll back. A
first run that fails half-way (a network error after `users` and
`customers` exist, say) leaves tables behind that the next run's
`create table` will trip over, while `_migrations.applied` records nothing,
because the control table is written only after a migration fully applies.
Repair is by hand: drop what the partial run created (or finish it in the
SQL editor and insert the row with the manifest's checksum), then re-run.
The SQL is kept verbatim on purpose — it is the template's schema and its
`schema.sql` twin — rather than rewritten with `IF NOT EXISTS`, which would
silently mask a drifted table. Later migrations a product adds should be
idempotent, as the PLAYBOOK asks.

## SP-B — Where each key lives (RESOLVED; reworked in SP5)

The anon key is a wrangler `var`, rendered from the wiring document: it is
shipped to every browser by design and Row Level Security is the boundary.
The service-role key, the Stripe secret key and the webhook signing secret
are Worker secrets.

Until SP5 nothing actually set the service-role secret: the component's
`secretEnv` put it in the deploy job's environment, where `wrangler deploy`
does not look. Since SP5 it travels in `WIRING_SUPABASE` with the URL and
the anon key, and the deploy lane's build pushes it to the Worker with
`wrangler secret bulk` (`tooling/wire/secrets.mjs`, the value over stdin).
On a Worker that does not exist yet, `secret bulk` creates a draft one
(wrangler's own non-interactive default) that the deploy then replaces;
Worker secrets survive every deploy. The three Stripe values are the
product's own and set once per environment with `wrangler secret put`,
the publishable key included (`STRIPE_PUBLISHABLE_KEY`), because it is read
per request rather than inlined at build since SP5.

## SP-C — Auth emails and Stripe redirects go to the right host (RESOLVED, SP5)

`getURL()` builds every absolute URL — Checkout success/cancel, the Portal
return URL, the auth callback and reset links — from `NEXT_PUBLIC_SITE_URL`.
SP1 built it in `buildCommand` from `WORKERS_DEV_SUBDOMAIN`, which the
workers-assets composition exports to the smoke step only, so the build saw
an empty subdomain. Since SP5 it is a var of the rendered `wrangler.jsonc`
(`https://<repo>-web-<env>.<subdomain>.workers.dev`, renamed with the
product) that the build inlines. Supabase additionally allow-lists redirects
against the project's Site URL; the supabase root now sets it, and the one
allowed redirect origin, to the same Worker (`supabase_settings`).

## SP-D — A credential-free build must not throw (RESOLVED)

`next build` evaluates `app/api/webhooks/route.ts` while collecting page
data, which imported a module-scope `createClient(url || '', key || '')`
that throws without a Supabase project. The admin client is built per
call now (Supabase's own serverless guidance), so Checks and a fresh clone
build; `NEXT_PUBLIC_*` values unset at build time stay runtime lookups and
`wrangler dev` reads the fixture vars.

## SP-E — Stripe on Workers (RESOLVED)

The Node http client and synchronous `constructEvent` are replaced by
stripe-node's own `createFetchHttpClient()` and
`constructEventAsync` + `createSubtleCryptoProvider()`, both present in
v14. Verified under `wrangler dev`: an unsigned POST answers 400 "Webhook
secret not found."; a bad signature answers 400 "Webhook Error: No
signatures found matching the expected signature for payload."

## SP-F — `supabase` CLI devDependency under pnpm 10 (ACCEPTED)

The template lists the `supabase` npm package for its `supabase:*` scripts;
its postinstall downloads the CLI binary, which pnpm 10 blocks unless
allow-listed. The dependency stays (the scripts stay as written) and the
install warns; a developer who wants the local Supabase stack runs
`pnpm approve-builds` once (it allow-lists the package in the checkout's
`pnpm-workspace.yaml`; `pnpm rebuild` alone does not run a blocked script). CI never needs
it: the runner applies the schema.

## SP-G — Node ≥ 25 stub `localStorage` at prerender (SETTLED)

Nothing in this template reads `localStorage`, and every page is dynamic
(cookies). CI builds on Node 22.

## SP-H — lucide-react 0.330.0 and React 19 (ACCEPTED)

The pinned `lucide-react` declares a React ≤ 18 peer; pnpm warns and the
icon components render under React 19 unchanged. Kept at the template's
pin; a bump is a one-liner when wanted.

## SP-I — A fresh product has no Stripe key (RESOLVED, SP5)

A bootstrapped product is deployed by a convergence nobody attends, and
Stripe is a third party no platform brokers. Before SP5 the pricing page
showed "No subscription pricing plans found" on a fresh deployment (the
webhook had synced nothing), the Subscribe buttons led to a checkout that
would fail, and the webhook answered 400. Now the Stripe client exists only
once a key does: pricing shows the template's sample plans (or what the
database holds) with checkout off and "Connect Stripe to enable checkout",
the checkout and portal actions answer "Stripe is not connected.", the
webhook answers 503. Sign-up, sign-in and the account page never touched
Stripe and work as before.

## SP-J — `wrangler.jsonc` must exist before the build (RESOLVED, SP5)

The workers-assets composition's `verify-app-structure` step runs
`test -f wrangler.jsonc` before `build-app`, in the job's fresh tree. SP1
rendered the file in the build and git-ignored it — every web lane would
have stopped there. It is committed as the fixture render now (tests/web
holds it equal to the template), and the stage and prod lanes re-render it
from their wiring document before the build. SP1's build command also
rendered on `dev`, which has no wiring document; dev verifies with the
committed render.

## SP-K — Row-level security is the app's access control (RESOLVED, SP5)

Unlike a Postgres-only app, this one reads and writes through Supabase's
Data API: the anon key (in every browser) and the visitor's session for
the pricing and account pages, the service-role key for the webhook's sync
and the customer mapping. So RLS is not a guard in front of the app, it IS
the app's authorization, and upstream's policies are kept exactly:
own `users` row (select, update), public `products` and `prices`, own
`subscriptions`, nothing on `customers`. Migration 020 re-enables RLS on the
five tables by name and fails the migration — before the app deploys — if
any table in `public` is without it. `tests/db` checks the catalog, the
policy list, and what anon, a signed-in user and the service role can read
and write, after every migration; the e2e asks the real PostgREST, after a
real sign-up, and reads the user's subscription through the app's own
account page.

## SP-L — The service-role key's path (ACCEPTED)

The key bypasses RLS. It is in exactly three places: the supabase root's
state (sensitive output), the `WIRING_SUPABASE` orun secret on each
environment rung, and the Worker's secrets. It is never a wrangler var and
never inlined: `next build` inlines only `NEXT_PUBLIC_*` and the three vars
`next.config.mjs` names, and the e2e greps the built Worker, its static
assets and the rendered config for the key it was handed. The deploy job
holds the whole wiring document in its environment while it builds (as
every lane holds its resolved secrets); the build reads only the public
half of it.

## SP-M — The brokered token's reach on the Management API (OPEN)

The supabase root reads the project's API keys (`supabase_apikeys`, `GET
/v1/projects/{ref}/api-keys`), waits on `GET /v1/projects/{ref}`, and writes
its Auth config (`supabase_settings`, `PATCH /v1/projects/{ref}/config/auth`)
with the OAuth token the platform brokers (`management-access`). Lumen's
roots never call the API-keys or Auth-config endpoints, so whether that
token's scopes reach them is untested — the same class of gap as the
billing endpoint that pinned the provider below 1.6. If either is refused,
the apply fails on its first run and nothing deploys; the fallback is a
personal access token connection, or, for the Auth config alone, setting
the three values by hand and dropping the resource (docs, "Failure modes").
The first live bootstrap settles it.

## SP-N — Unmeasured wall-clock, unapplied root (OPEN)

The card's twenty minutes is summed from the phases' estimates; no
bootstrap has been timed. Supabase project creation dominates (five to seven
minutes, Lumen's measurement). The root has not been applied from this
repository and no db-migrate has run against a real project: the root is
validated offline, the migrations are applied by the product's own runner to
a local Postgres under the real Auth and Data API in the e2e tier, and the
order is proven on the product's own plan.

## SP-O — The bootstrap floor plans `modeRules` as enforced (ACCEPTED)

orun v2.58.11, the floor a bootstrap runs on, ignores per-edge `modeRules`,
so a pull-request plan it makes holds the infra edges enforced rather than
advisory. The product's own CI plans with its lane pin (v2.78.4), which
reads them; the placement tier says when it cannot check them and the e2e
tier, pinned at the lane version, does.

## SP-P — Two Supabase projects per product (ACCEPTED, documented)

Every product gets `<repo>-stage` and `<repo>-prod`. Supabase's free plan
allows two active projects per organization, so a free organization fits
exactly one product built from this baseline. The card's description and
BOOTSTRAP.md state it as an owner prerequisite, and the supabase lane fails
on the limit naming it.

## SP-Q — The e2e's Supabase is real binaries, downloaded (ACCEPTED)

The end-to-end tier needs Supabase Auth and the Data API, not just
Postgres: the app signs users up through GoTrue and reads through PostgREST.
It downloads the two pinned releases (supabase/auth v2.180.0, PostgREST
v12.2.12), verifies their sha256, caches them, and runs them over its own
Postgres behind a gateway that checks the API key as Kong does. It is not
Supabase's whole stack — no Kong, Realtime, Storage or Studio — and its
roles and grants are reproduced from Supabase's defaults
(`testing/lib/local-supabase.sh`), not taken from the hosted image.
