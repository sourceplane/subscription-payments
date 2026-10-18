# db-migrate

Applies database migrations to stage and prod Supabase instances

Applies this repository's ordered database migrations per environment: plan on pull requests, apply on merge to `main`.

|              |                                                                                            |
| ------------ | ------------------------------------------------------------------------------------------ |
| Type         | `db-migrate`                                                                               |
| Source       | `infra/db-migrate`                                                                         |
| Environments | `stage`: `plan`, `apply` on a push to `main` · `prod`: `plan`, `apply` on a push to `main` |

## Depends on

- **db** — The database migrations and their runner (built by the db-migrate component before it plans or applies)
- **supabase** — Provisions Supabase projects for stage and prod, points their Auth at the app, and wires the database credentials and the app's URL and keys into orun secrets

## Depended on by

- **web** — The Next.js Subscription Payments Starter — Supabase Auth, Stripe Checkout, Customer Portal and webhooks (Next.js on Cloudflare Workers + Static Assets via @opennextjs/cloudflare, per environment)
