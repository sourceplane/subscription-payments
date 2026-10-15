# 02-docs — the deployment, recorded

**Places** nothing. Its work is hooks: it records what `01-product` built,
from probed facts rather than from what the blueprint intended, and it puts
back the two things `01-product` deferred for the bootstrap's sake.

**Requires** `01-product` placed. (A hook-only phase derives as `unknown`, so
no phase may require this one.)

## What runs

| hook | what it does |
|---|---|
| `task` (pre) | finds the phase's task and yields its key |
| `promotion` | restores `environments.prod.promotion` — from now on prod deploys only after stage |
| `dev-lanes` | restores dev's activation on pushes to main |
| `render` | `hooks/render-deployment-docs.sh`: probes `/` and `/api/health` on both environments, reads whether the pricing page still says Stripe is not connected, lists the secrets by name and the workspace's integrations, and regenerates `ai/context/deployment.md` and the README's live-deployment section |
| `land` | one PR, waited for and merged. It touches no component, so it deploys nothing |
| `verify` (await) | the same probe `01-product` ended on |

## Re-running it

Idempotent, and the way to refresh the record after a redeploy, a custom
domain, or connecting Stripe: every generated section is re-rendered from
scratch.

```bash
orun new --blueprint repo-blueprint.yaml --out <product-checkout> \
  --run-hooks --phase 02-docs --values <values.yaml>
```

## If a bootstrap stops before this phase

The promotion gate and dev's push activation stay deferred: `intent.yaml`
carries a `# @promotion-deferred:…` and a `# @dev-lanes-deferred:…` marker.
Running this phase restores both, or by hand from the baseline checkout:

```bash
node tooling/bootstrap/promotion.mjs --restore --file <product>/intent.yaml
node tooling/bootstrap/dev-lanes.mjs --restore --file <product>/intent.yaml
```
