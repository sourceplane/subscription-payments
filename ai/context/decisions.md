# subscription-payments — decisions

The choices that shape this repository, one line each, with where the full
reasoning lives. Superseded decisions stay listed, marked, so the history
reads in order.

| # | Decision | Why | Source |
|---|---|---|---|
| 1 | OpenNext on Workers + Static Assets (Next 16.3.8, React 19) | `@opennextjs/cloudflare` needs Next ≥ 15.5; only what Next 16 and Workers force changes in the template | epic README, IMPLEMENTATION-STATUS |
| 2 | One wiring document per environment, `WIRING_SUPABASE`: the URL and anon key are wrangler vars the build inlines; the service-role key is pushed as a Worker secret by every deploy (`wrangler secret bulk`). *Supersedes SP1–SP4's separate secrets* | The anon key is public (RLS protects the data); the service-role key bypasses RLS and never enters a wrangler file or a bundle | design.md §3, risks SP-B, SP-L |
| 3 | Stripe is optional: the app deploys and serves with no key (sample plans, checkout disabled, webhook 503); the owner adds the three Stripe secrets when ready | The platform brokers no Stripe connection, so a fresh product must come up without one | risk SP-I |
| 4 | `stripe` stays on v14, with `createFetchHttpClient` and SubtleCrypto webhook verification | v14 already has both Workers adapters; nothing else in the Stripe code changes | design.md §4, risk SP-E |
| 5 | The schema is applied by the `@saas/db` runner through Supabase's Management API, from the template's `init.sql` verbatim — not `supabase db push` in CI | The token is already brokered; no CLI binary, no direct Postgres connection on the runner | design.md §7, risk SP-A |
| 6 | Row-level security on every table in `public`, upstream's policies kept; migration `020` raises if any table lacks it | RLS is the app's access control over the Data API | risk SP-K |
| 7 | No Hyperdrive | The app speaks PostgREST over HTTPS, never a Postgres socket | epic README |
| 8 | `apps/web/wrangler.jsonc` is committed as the fixture render; stage and prod re-render it | The composition checks it exists before the build | risk SP-J |
| 9 | The supabase root points the project's Auth at the Worker (`supabase_settings`) and autoconfirms unless SMTP is configured | Auth emails and redirects must reach the product's own origin | risk SP-C |
| 10 | One landing (`01-product`) then the record (`02-docs`); supabase → db-migrate → web enforced on main, advisory on a pull request; stack-tectonic 0.19.0 | A landing has a fixed cost; 0.20.0's lane-scoped install is refused by Turbopack | `repo-blueprint.yaml`, `intent.yaml`, IMPLEMENTATION-STATUS (SP5) |
| 11 | orun is pinned only where it runs (the `orun-action` `version:` in each workflow); no kiox | `kiox.yaml` pinned a version (v2.15.0) nothing ran | IMPLEMENTATION-STATUS (SP6) |
| 12 | Component docs are generated from the manifests and checked in CI | A hand-written copy of the dependency graph and bindings drifts silently | `tooling/catalog/gen-component-docs.py` |
