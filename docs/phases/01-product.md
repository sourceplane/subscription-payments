# 01-product — the product, in one landing

The whole product lands as ONE pull request, and ONE convergence on main
provisions and deploys it on stage and prod: the Supabase project, the
migrations, and the app — in that order, per environment.

**Places** every module `repo-blueprint.yaml` declares: the root manifests,
CI, tooling and identity; `infra/terraform/supabase` and `infra/db-migrate`;
`packages/db` (the migrations and their runner); `apps/web`; and
`tests/web`, `tests/db`. `testing/phases.test.sh` holds the set.

**Requires** three live connections, probed and waited for (up to ten
minutes, so a consent can be clicked while it waits): the GitHub App on the
account that OWNS the repository — the platform sees a PR only through that
installation — and Cloudflare and Supabase, which every credential below is
minted from. The Supabase organization the connection is anchored on needs
room for **two** projects, `<reponame>-stage` and `<reponame>-prod` (its free
plan allows exactly two active ones).

## How one convergence keeps the order

| what has to come first | how the plan holds it |
|---|---|
| the Supabase project before the migrations | `db-migrate` reads `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD` and `SUPABASE_DB_URL`, which the `supabase` apply lease-publishes, and declares `dependsOn: supabase`, `mode: enforced` on main. A job resolves its secrets when it STARTS, so the values are there |
| the app last | `web` reads `WIRING_SUPABASE_<ENV>` — the project URL and anon key it builds with and renders into `wrangler.jsonc`, and the service-role key it pushes to the Worker as a secret — and queries the migrated schema (the pricing page, `/api/health`), so it declares `dependsOn` on `supabase` and `db-migrate`, enforced on main |
| stage before prod | deferred during the bootstrap (below), so both environments run their chains side by side |

Every one of these edges is **advisory on a pull request**, which applies and
deploys nothing. `testing/placement.test.sh` plans the placed product's own
push to main and reads the order off it: `supabase → db-migrate → web`.

## What runs

The run's task set-up — the epic, both milestones, both tasks — runs in the
background from the start (`background: true`), so every hook up to `task`
runs beside it; `task` is the first that waits for it.

| hook | what it does |
|---|---|
| `retouch` | one trailing `# orun: redeploy 01-product <stamp>` line in each component `.baseline/tasks/01-product.TaskContract.yaml` names (supabase, db, db-migrate, web), so a RE-RUN has a diff to land |
| `git-init`, `stage` | the tree becomes a git repository with a populated index (the rebrand enumerates `git ls-files`) |
| `rebrand` | renames the baseline's identity to the product's: the slug (intent, worker, secret project, the `repo` the Supabase project is named after), the name seam, the domain, the workers.dev subdomain. The upstream template's own identity (`nextjs-subscription-payments`, its demo site) and every migration are left alone |
| `orun-workspace` | writes the product's workspace into `intent.yaml` |
| `work-tree` | strips this repository's `work:` block from the product's intent |
| `promotion`, `dev-lanes` | defer prod's wait on stage and dev's push lanes until `02-docs` |
| `restage`, `rebrand-verify` | the sweep: no baseline identity left |
| `repo` | `orun.repo/ensure@v1`: creates (or finds) `<githuborg>/<reponame>` |
| `link` | the repository becomes the workspace's (`orun cloud link`, best effort; `orun cloud check` is the gate). Every convergence lane authenticates over GitHub OIDC through that link |
| `secrets-cloudflare` | `orun.integrations/reconcile@v1`, Cloudflare's two keys in one hook, each under its own scope, created side by side: `CLOUDFLARE_API_TOKEN` (workers-deploy — the app's deploy and its service-role secret), `CLOUDFLARE_ACCOUNT_ID` (account-id). Keys that exist are kept |
| `secrets-supabase` | the same for Supabase's two: `SUPABASE_ACCESS_TOKEN` (management-access — the project, its Auth settings and the migrations), `SUPABASE_ORG_ID` (org-id) |
| `task` | finds the phase's task and yields its key — waiting, if it must, for the background set-up |
| `land` | one PR bound to the task, its commit checked in the box first (`checks: local`: `orun validate`, then `orun plan` as the PR and as the merge would plan it, under a second); merged without waiting for the PR's CI (`plan` alone on a bootstrap branch) |
| `converge` (await) | `orun.run/watch@v1` on the merge commit's run, read every 5 s; resumes it up to three times |
| `verify` (await) | `orun.http/probe@v1`: `/` and `/api/health` on both workers.dev URLs |

## What the convergence does, per environment

1. **supabase** — `terraform apply`: one project, `<reponame>-<env>`, in the
   org `SUPABASE_ORG_ID` names, with a generated database password; it waits
   for the project to come up (five to seven minutes when new), reads its API
   keys, and points its Auth at the app — the Worker's origin as the Site URL
   and the one allowed redirect, and sign-up signing users straight in until
   the project has SMTP of its own (`authEmailConfirmation`). Its outputs are
   lease-published as `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`,
   `SUPABASE_DB_URL` and `WIRING_SUPABASE` (the URL, the anon key and the
   service-role key, one document).
2. **db-migrate** — builds `@saas/db` and applies every migration the
   database's `_migrations.applied` ledger does not have, through Supabase's
   Management API: the template's schema with its row-level-security
   policies, then `020_row_level_security`, which re-enables RLS on every
   table and stops the convergence if any table in `public` is without it.
3. **web** — installs, re-renders `wrangler.jsonc` from this environment's
   wiring document, builds with OpenNext (the URL, anon key and origin
   inlined), pushes the service-role key to the Worker as a secret
   (`wrangler secret bulk`, the value over stdin), deploys
   `<reponame>-web-<env>`, and smoke-tests it: the pricing page, and
   `/api/health`, which answers only when the project is reachable with those
   keys, the schema is migrated and the service-role secret is the project's
   own.

Stripe is not in it: no connection brokers it. The app deploys without a
Stripe key and its pricing page shows the sample plans and says checkout is
not connected until the owner adds one (the product's README, "Connect
Stripe").

## Verify / done means

- The convergence for the merge commit is green on stage and prod — in it,
  db-migrate resolved the Supabase project's `SUPABASE_PROJECT_REF`,
  `SUPABASE_DB_PASSWORD` and `SUPABASE_DB_URL`, and the app's deploy
  `WIRING_SUPABASE`, from stage and prod, where every later run reads them.
  A missing one fails its lane, so there is no separate check that they
  exist.
- `/` and `/api/health` answer on both workers.dev URLs.

## Failure modes

| symptom | meaning → fix |
|---|---|
| parks on the `providers` probe | a connection is missing — GitHub on the repository's owner, Cloudflare, or Supabase. Connect it (console → Integrations); the probe is a wait, not a failure |
| supabase apply: project limit reached | the Supabase organization has no room for both projects (the free plan allows two active ones). Pause or delete one, or upgrade, then re-run the phase |
| supabase apply: `does not support oauth access` | the provider is above 1.5.x, which reads billing endpoints an OAuth token cannot — `~> 1.5.1` is pinned for this reason |
| supabase apply: forbidden on the Auth settings (`supabase_settings`) | the brokered token cannot write the project's Auth config. Set the Site URL, the redirect allow-list and "Confirm email" by hand (the product's README, "Supabase Auth email"), drop the `supabase_settings` resource from the product's root, and re-run |
| supabase apply: project name already exists | `adopt.tf` looks the project up by name and imports it — if you removed that file, restore it |
| db-migrate lane: secret resolution failed (`SUPABASE_*`) | the supabase apply for that environment did not publish — read its log; db-migrate waits on it, so it shows as not run |
| db-migrate: checksum mismatch | an applied migration's file changed. Never edit one; add a new migration |
| db-migrate: `tables in public without row-level security …` | migration 020's check: a table in `public` (named in the message) has no RLS, so the Data API would serve it to the anon key. Nothing deployed. Enable RLS on it (and add the policies the app needs) in a new migration, or drop it, then re-run the phase |
| web `build-app`: `wire: missing wiring documents … WIRING_SUPABASE_<ENV>`, or the web lane's secret resolution failed (`WIRING_SUPABASE`) | the supabase apply for that environment did not publish (the root lost its `secretOutputs`, or its lane was not in the plan); web waits on it, so read that lane — re-run the phase and its retouch marker re-plans the root |
| `land`: `the landing's own check failed — orun plan for …` | the placed tree does not plan; the next line is orun's own error. Nothing was pushed. Fix it (or the baseline) and re-run the phase |
| `land` waits on CI after all | the product's repository requires a status check on `main` (branch protection or a ruleset), so GitHub refused the early merge; the landing waits for the check as a `checks: ci` landing would, then merges |
| web `build-app`: `wrangler secret bulk failed` | the deploy token cannot write the Worker's secrets — reconnect Cloudflare with the recipe's permission groups (Workers Scripts Write) and re-run the phase |
| web smoke: `/api/health` 503 | `supabase: unreachable` — the project is paused or the URL is wrong; `schema: missing` — db-migrate did not run for that environment; `serviceRole: missing` or `invalid` — the secret push did not happen or the key is not the project's (the build-app log says which) |
| `build-app` fails: `Symlink apps/web/node_modules/next is invalid, it points out of the filesystem root` | the product's intent pins stack-tectonic ≥ 0.20.0 (lane-scoped install), which Next 16's Turbopack refuses. Pin 0.19.0 — `intent.yaml` says why |
| `verify-app-structure` fails: `test -f wrangler.jsonc` | `apps/web/wrangler.jsonc` is not committed. It must be: the check runs before the build, in a fresh checkout (`pnpm run wire:fixture` renders it) |
| the watch says green, the probe says 404 | another workflow ran on the push and the watch took its run. Only `ci.yml` may run on a push to main |
| re-run lands nothing | the hooks did not run (`--run-hooks`), or the contract names no component — `node tooling/bootstrap/retouch.mjs --check --affects .baseline/tasks/01-product.TaskContract.yaml` in the product's tree says which |

## Re-running

Idempotent: placement is additive, the rebrand is a no-op on branded files,
`git init` and the repo step are guarded, the Supabase project is adopted
rather than recreated, the Auth settings converge to the same three values,
and the migration ledger lives in the database, so only missing migrations
apply. A re-run of a phase whose PR already merged lands the retouch markers
alone, which re-plans exactly the components they name. Once the tree is
branded the phase derives as `drifted`, so `--resume` leaves it alone;
re-run it deliberately with `--phase 01-product` (or `--redo 01-product`).

## What one convergence will run, before running it

From a placed product's tree:

```bash
node <baseline>/tooling/bootstrap/promotion.mjs --defer && node <baseline>/tooling/bootstrap/dev-lanes.mjs --defer
orun plan --intent intent.yaml --trigger github-push-main -v lanes
git checkout intent.yaml
```
