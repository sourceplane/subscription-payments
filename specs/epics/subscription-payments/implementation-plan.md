# subscription-payments — implementation plan

Milestones land in order; each task is one pull request on an
`orun/SP-n-<slug>` branch with an `Orun-Task: SP-n` trailer.

## SP0 — the spec ✅

This doc set, `epic.yaml` and the task contracts, merged to `main`.

**Done when**
- the five documents and `epic.yaml` are on `main`
- `tasks/SP-1..SP-5.TaskContract.yaml` exist

## SP1 — the app on Workers ✅

`apps/web` is the upstream template with the Workers build around it, on
Next 16 / React 19 with only the forced changes (`proxy.ts`, the ssr 0.12
cookie adapters, awaited `cookies()`/`params`, the Stripe fetch client and
async webhook verification, the per-call admin client);
`wrangler.template.jsonc` + `wiring.fixture.json` render the config;
`.dev.vars.example` names the Worker secrets; `tests/web` exercises the
helpers, the auth settings and the webhook route's decisions.

**Done when**
- `pnpm install && pnpm run wire:fixture && pnpm typecheck && pnpm lint && pnpm test && pnpm build` is green locally and in `Checks`
- `wrangler dev` answers `/` with the pricing page, `/signin` with a 307 to `/signin/password_signin`, a signed-out `/account` with a 307 to `/signin`, and an unsigned `POST /api/webhooks` with 400 "Webhook secret not found."
- the sign-in views render (`/signin/password_signin`, `/signin/signup`)

## SP2 — the schema through db-migrate ✅

`packages/db` is `@saas/db` with the control migration and
`010_subscriptions_init/up.sql` (the template's `init.sql`, byte for byte)
in a checksummed manifest; `infra/db-migrate` plans on pull requests and
applies on merge after the `supabase` root; `tests/db` verifies the
manifest and the offline plan.

**Done when**
- `pnpm --filter @saas/db run manifest:check` passes
- `node packages/db/dist/runner/cli.js plan --env stage` lists `000_control_baseline` and `010_subscriptions_init`
- `tests/db` is green in `Checks`

## SP3 — the Supabase project from Terraform ✅

`infra/terraform/supabase` provisions a project per environment and
publishes URL, keys, DB URL and the wiring document; `apps/web/component.yaml`
depends on it and on `db-migrate`, and declares the `secretEnv` the build,
the Worker and the deploy read.

**Done when**
- `terraform validate` passes on the root
- the component's `secretEnv` keys match the root's `secretOutputs`
- the fixture's wiring keys match the template's tokens (`wire:fixture` renders)

## SP4 — ready to instantiate ✅

README (run, test, preview, deploy, Stripe fixtures / webhook / secrets,
the Supabase auth Site URL), `IMPLEMENTATION-STATUS.md` with PRs and
departures, epic `completed`.

**Done when**
- the README quick start works from a fresh clone with a `.env.local` and a `.dev.vars`
- the status file lists every PR and departure

## SP5 — a baseline

The repository becomes an Orun baseline on the Lumen conventions, built the
way cirrus-baseline v22 builds a product — in ONE landing — following the
saas-starter reference (SA5) without its Hyperdrive:

- `blueprint.yaml` (the card: `requires [github, cloudflare, supabase]`, the
  four brokered secrets as a preview, the programme `01-product`, `02-docs`,
  the two-Supabase-projects prerequisite in its description) and
  `repo-blueprint.yaml` (every module placed by `01-product` and landed as one
  pull request; `02-docs` hook-only);
- the components' edges `mode: enforced` on a push to main, advisory on a
  pull request, so one convergence runs supabase → db-migrate → web per
  environment;
- `WIRING_SUPABASE` carries the project URL, the anon key and the
  service-role key: the deploy renders the first two into `wrangler.jsonc`
  (the build inlines them) and pushes the third as a Worker secret
  (`tooling/wire/secrets.mjs`); the supabase root publishes Lumen's three
  database credentials and that document, nothing else, and points the
  project's Auth at the Worker;
- the app deployable with no Stripe key: the Stripe client is lazy, pricing
  shows the template's sample plans with a connect-Stripe notice, checkout
  and the portal say so, the webhook answers 503;
- row-level security on every table in `public`, upstream's policies kept,
  checked by migration `020` and by `tests/db`;
- `wrangler.jsonc` committed as the fixture render, so the composition's
  pre-build structure check passes in a fresh checkout;
- `.baseline/`, the rename engine, the bootstrap helpers, the deployment
  record, `ai/context/`, `testing/` and the `baseline.yml` / `tag.yml` lanes.

**Done when**
- orun reads the build document at the bootstrap floor (v2.58.11), the lane
  pin (v2.78.4) and 2.79.0, and the card agrees with it
- the product's own `orun plan --trigger github-push-main` shows the order,
  enforced; a pull request's plan holds the same edges advisory
- the e2e tier migrates a local Supabase (real Auth and Data API) with the
  product's own runner, builds in the job tree orun stages, and signs a user
  up, out and in with no Stripe key, the anon key refused every row the
  policies do not give it

## Sequencing note

SP1's component already names the root's secrets and the db-migrate
component, so SP2 and SP3 are the halves that make those names true; both
are independent files but SP3's `dependsOn` from `db-migrate` to `supabase`
orders the apply. Applying either needs a workspace with a Supabase
connection; until then the Orun lane is gated and `Checks` is the merge
gate. SP4 is documentation over all three.
