# The phases — one blueprint, two selections, one landing that deploys

`repo-blueprint.yaml` declares two phases that take a subscription product from
**nothing** to **live on stage and prod, documented**. Run them one at a time
with `--phase <name>`, or both unattended with `--resume`. There is no
umbrella workflow and no per-phase document: a phase is a selection on one
artifact, which is what makes running one alone, months later, from a fresh
container the same operation as running them all.

Each phase follows the same contract:

> **place its modules → brand them → land them as one pull request → watch
> the convergence that merge triggers (auto-resumed) → verify the outcome.**

Run from the baseline checkout (the blueprint's source is `path: .`); the
product's repository is wherever `--out` points.

## Execution order

| phase | lands | verified by |
|---|---|---|
| [`01-product`](01-product.md) | **the GitHub repo created**, then the WHOLE product in one PR: intent, CI, tooling, the Supabase Terraform root, the migrations, the app and its tests — one convergence provisions and deploys it in dependency order | convergence green; `SUPABASE_*` and `WIRING_SUPABASE` published on stage and prod; `/` and `/api/health` answer on both |
| [`02-docs`](02-docs.md) | the live-deployment record; the promotion gate and dev's lanes put back | committed manifest matches probed reality |

**One landing builds the product.** The order the data plane needs — the
Supabase project before the migrations, both before the app — is not a
sequence of landings. It is the components' own `dependsOn`, every edge
`mode: enforced` on a push to `main` and advisory on a pull request:

```
supabase ──▶ db-migrate ──▶ web        (per environment)
```

A job resolves its secrets when it starts, so each one reads what the apply
before it published: db-migrate the project's credentials, the app's deploy
`WIRING_SUPABASE` — the project URL and anon key it builds with, and the
service-role key it hands the Worker as a secret. There is no Hyperdrive: the
app reaches Supabase through supabase-js (Auth and the Data API), never as
raw Postgres.
`testing/placement.test.sh` reads that order off the product's own
`orun plan --trigger github-push-main`.

Every landing is a pull request on a branch named for its task
(`orun/BASE-<n>-<phase>`). On those branches `ci.yml` runs `plan` only — the
intent, every component and every composition resolve — and skips the lanes,
because the merge runs them on main a minute later, for real, and that
convergence is what the phase watches. `checks.yml` (install, typecheck,
lint, test, build) runs on every pull request regardless.

There is no custom-domain phase: the app answers on workers.dev. Attaching a
domain needs zone permissions the brokered `workers-deploy` token does not
carry, so it is an owner's step after the bootstrap (the product's README,
"Custom domain").

## Inputs

`01-product` takes the product's identity once and writes it into the repo
(`.rebrand/values.json`); `02-docs` reads it back from the placed tree. But
the blueprint's **required** inputs — `reponame`, `productname`,
`productdomain`, `githuborg` — are validated before any phase runs, so they
must be supplied on every invocation, single-phase ones included. A
`--values` file is easier than repeating `--set`.

- `subdomain` — the workers.dev subdomain of the Cloudflare account you
  deploy into. It is in every URL the phases probe, in the origin Stripe
  returns visitors to, and in the Site URL the Supabase root gives the
  project's Auth. A console or `--from bst_…` build reads it from the
  Cloudflare connection; pass it only for a hand-run build.
- `orunWorkspace` — workspace id (`ws_…`). Unset, it is the workspace the
  build runs in (`from: workspace`); with none anywhere, a placeholder that
  fails loudly rather than silently claiming another tenant's workspace.
- `epicSlug` (default `subscriptions-baselining`) — the epic every phase clubs its
  task under. Found by slug, so a fresh run and a resumed run find the same
  work.
- `repoPrivate` (default `true`) — the repository's visibility at creation.

```bash
orun new --blueprint repo-blueprint.yaml \
  --out $HOME/products/acme-pay --run-hooks --phase 01-product \
  --values ~/acme-pay.values.yaml
```

Drop `--run-hooks` (or add `--status`) to preview. Without it a phase places
files and stops: no repo, no landing, no convergence watch, and no probe —
which is exactly what makes a dry instantiation of this baseline possible in
CI with no workspace and no provider (`testing/placement.test.sh`,
`testing/e2e.test.sh`).

## Stripe is not a phase

Stripe is a third party the platform does not broker, so nothing here mints,
asks for or waits on a Stripe key. The product deploys, signs users up and
in, and renders the account page without one; the pricing page shows the
template's sample plans and says **"Connect Stripe to enable checkout."**,
and the webhook answers 503. The owner adds `STRIPE_SECRET_KEY`,
`STRIPE_WEBHOOK_SECRET` and `STRIPE_PUBLISHABLE_KEY` as Worker secrets
afterwards, creates the products and the webhook endpoint in Stripe (the
product's README, "Connect Stripe"), and re-running `02-docs` records it.

## When a phase fails

- **Before it lands** (a probe that timed out, a rebrand residue, a refused
  link): nothing was merged. Fix what the message names and re-run the phase.
- **After it lands** (the convergence went red): the files are on main.
  `orun.run/watch@v1` has already resumed the run up to three times. Re-run
  the phase (`--phase 01-product`, `--redo 01-product` under `--resume`, or
  the console's Retry): its `retouch` hook gives the landing a diff and the
  components it names re-plan. The Supabase project is adopted rather than
  recreated (`adopt.tf`), and the migration ledger lives in the database, so
  a re-run applies only what is missing.
