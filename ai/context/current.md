# subscription-payments — where this repository stands

The entry page for anyone (or any agent) picking this repository up. It is
this repository's own state and does not ship to a product built from it;
the two pages that do are [operations.md](operations.md) and
[deployment.md](deployment.md).

## What it is

Vercel's Next.js Subscription Payments Starter — Supabase Auth, a Postgres
schema behind row-level security, Stripe Checkout, the Customer Portal and
webhooks — on Cloudflare Workers + Static Assets (through
`@opennextjs/cloudflare`), with its Supabase project from Terraform and its
schema applied by db-migrate. It is packaged as an Orun baseline:
`orun new --blueprint repo-blueprint.yaml` builds a new product in its own
repository and takes it to live on stage and prod in one landing
(`01-product`: the Supabase project, then the migrations, then the app),
then records what went live (`02-docs`). Stripe is the owner's to connect
afterwards; the app deploys and serves without it.

## Release

| | |
|---|---|
| Latest tag | `baseline-v2` (SP6 — the cirrus standard, [#7](https://github.com/sourceplane/subscription-payments/pull/7) and [#8](https://github.com/sourceplane/subscription-payments/pull/8): no kiox, generated component docs, this context pack, and the workers.dev subdomain read from the Cloudflare connection instead of asked) |
| Before it | `baseline-v1` (SP5, [#6](https://github.com/sourceplane/subscription-payments/pull/6)) |
| Proven live | No. Everything short of the platform is proven offline in Baseline CI: the e2e tier migrates a local Postgres under the real Supabase Auth and Data API with the product's own runner, builds in orun's staged job tree, and signs a user up and in with no Stripe key. No bootstrap from a tag has run against a workspace: the Supabase root's apply through the brokered token (SP-M), db-migrate against a real project, the service-role push, a real deploy and the card's twenty minutes (SP-N) are unproven |

## Where to read

| Question | Page |
|---|---|
| What shipped, and every departure from upstream | `specs/epics/subscription-payments/IMPLEMENTATION-STATUS.md` |
| Why it is built this way | [decisions.md](decisions.md), then `specs/epics/subscription-payments/design.md` |
| What could still go wrong | [open-risks.md](open-risks.md), then `specs/epics/subscription-payments/risks-and-open-questions.md` |
| How to instantiate it | `BOOTSTRAP.md`, `docs/phases/` |
| What each component is | `<component>/docs/` beside each `component.yaml` — `apps/web`, `packages/db`, `infra/db-migrate`, `infra/terraform/supabase`, `tests/{web,db}` (generated; `python3 tooling/catalog/gen-component-docs.py`) |

## Next

1. Bootstrap one product from `baseline-v2` against a workspace with
   Cloudflare and Supabase connected, and record its timings (closes SP-M
   and SP-N).
