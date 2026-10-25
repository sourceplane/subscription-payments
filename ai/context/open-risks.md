# subscription-payments — open risks

What is not yet proven or not yet decided. The full write-up of every risk,
including the accepted and resolved ones, is
`specs/epics/subscription-payments/risks-and-open-questions.md`; this page
lists only what is still live, so it should be short.

| ID | Risk | State | What closes it |
|---|---|---|---|
| SP-M | The supabase root reads the project's API keys and writes its Auth config with the brokered `management-access` token; whether that token's scopes reach those endpoints is untested, and a refusal fails the first apply | OPEN | The first live bootstrap's supabase apply |
| SP-N | No bootstrap has been timed (the card's sixteen minutes is summed from estimates); the root has not been applied and db-migrate has not run against a real project | OPEN | One bootstrap from a tag against a workspace |

Accepted, and worth knowing before you change them: SP-A (`init.sql` is not
idempotent), SP-F (the `supabase` CLI devDependency under pnpm 10), SP-H
(lucide-react 0.330.0 on React 19), SP-L (the service-role key's path), SP-O
(the bootstrap floor plans `modeRules` as enforced), SP-P (two Supabase
projects per product), SP-Q (the e2e downloads real Supabase binaries).
