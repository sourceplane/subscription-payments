# apps/web — the app

A subscription site from Vercel's
[Next.js Subscription Payments Starter](https://github.com/vercel/nextjs-subscription-payments)
(MIT, see `LICENSE`; its demo is https://subscription-payments.vercel.app/),
running on Cloudflare Workers + Static Assets:

- Secure user management and authentication with Supabase Auth — password,
  magic link and OAuth sign-in, sign-up, password reset — with cookie
  sessions through `@supabase/ssr` and a proxy that refreshes them
- Pricing (`/`) from the `products` and `prices` tables, which Stripe's
  webhooks keep in sync — or, until Stripe is connected, the template's
  sample plans with checkout off and a notice saying so
- Stripe Checkout to subscribe and the Stripe Customer Portal to manage,
  from the account page (`/account`)
- The Stripe webhook (`/api/webhooks`), which syncs products, prices and
  subscription statuses — and answers 503 until Stripe is connected
- `/api/health`, which answers 200 only when the Supabase project is
  reachable with the keys the Worker was built with, migrated, and its
  service-role key valid

The product's name is `utils/site.ts`. The Supabase URL, the anon key and
the site's origin come from `wrangler.jsonc`'s vars, which `next build`
inlines (`next.config.mjs`); the service-role key is a Worker secret, read
only by server code (`utils/supabase/admin.ts`); the Stripe client exists
only once `STRIPE_SECRET_KEY` does (`utils/stripe/config.ts`).

```bash
pnpm dev               # next dev on http://localhost:3000, with .env.local
pnpm build             # next build + opennextjs-cloudflare build → .open-next/
pnpm preview           # wrangler dev over the built Worker, with .dev.vars
pnpm supabase:start    # the Supabase CLI's local stack (supabase/migrations, supabase/config.toml)
pnpm stripe:listen     # forward Stripe's events to localhost:3000/api/webhooks
pnpm stripe:fixtures   # the template's plans in your Stripe account (fixtures/stripe-fixtures.json)
```

How it runs locally, how it deploys — per environment, after the Supabase
project and the migrations, on merge to `main` — how to connect Stripe and
how to configure Supabase Auth's email are the repository's README and
`component.yaml` beside this file.
