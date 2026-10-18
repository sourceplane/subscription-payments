# supabase

Provisions Supabase projects for stage and prod, points their Auth at the app, and wires the database credentials and the app's URL and keys into orun secrets

Terraform-managed infrastructure, planned and applied per environment by its CI lane.

| | |
|---|---|
| Type | `terraform` |
| Source | `infra/terraform/supabase` |
| Environments | `stage`: `plan-only`, `apply` on a push to `main` · `prod`: `plan-only`, `apply` on a push to `main` |

## Depends on

- (none)

## Depended on by

- **db-migrate** — Applies database migrations to stage and prod Supabase instances
- **web** — The Next.js Subscription Payments Starter — Supabase Auth, Stripe Checkout, Customer Portal and webhooks (Next.js on Cloudflare Workers + Static Assets via @opennextjs/cloudflare, per environment)
