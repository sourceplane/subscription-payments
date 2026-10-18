# web — architecture

Built by the turbo pipeline from `apps/web` and deployed with wrangler.

| | |
|---|---|
| Worker config | `apps/web/wrangler.template.jsonc` |
| Entry | `.open-next/worker.js` |
| Compatibility date | `2026-10-01` |
| Compatibility flags | `nodejs_compat`, `global_fetch_strictly_public` |

## Bindings

| Binding | Kind | Source |
|---|---|---|
| `ASSETS` | Static assets | `.open-next/assets` |

## Variables

`NEXT_PUBLIC_SITE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_SUPABASE_URL`.
