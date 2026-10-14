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

## SP-B — Where each key lives (RESOLVED)

The anon key is a wrangler `var`, rendered from the wiring document: it is
shipped to every browser by design and Row Level Security is the boundary.
The service-role key, the Stripe secret key and the webhook signing secret
are Worker secrets. `SUPABASE_SERVICE_ROLE_KEY` is published by the
`supabase` root and declared in the component's `secretEnv`, so the deploy
lane can set it; the two Stripe values are the product's own and are set
once per environment with `wrangler secret put` (or as orun secrets the
deploy lane reads). `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` is public and
build-time; the component's `buildCommand` is where to export it.

## SP-C — Auth emails and Stripe redirects go to the right host (ACCEPTED, documented)

`getURL()` builds every absolute URL — Checkout success/cancel, the Portal
return URL, the auth callback and reset links — from `NEXT_PUBLIC_SITE_URL`,
which the component's `buildCommand` sets to the environment's Worker URL.
Supabase additionally allow-lists redirects against the project's
`Site URL`, which Terraform's `supabase_project` does not set; it is set
once per environment in the dashboard. The README names both values.

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
