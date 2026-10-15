#!/usr/bin/env bash
# TIER 2 — the product a bootstrap produces builds, migrates, deploys (dry),
# serves, and signs a user up, out and in again, with no Stripe key — through
# Supabase Auth and the Data API, every table in `public` behind row-level
# security.
#
# placement.test.sh proves the tree a bootstrap ends with is the right tree,
# and that its own plan converges in the right order. This proves it WORKS,
# by doing to it what its own pipelines will:
#
#   1. at the 01-product landing (the commit its PR merges), run what
#      `checks.yml` runs on that PR — install with the lockfile the phase
#      placed, render the wrangler fixture (which must change nothing: the
#      render is committed), typecheck, lint, test, build. That landing WAITS
#      on its checks;
#   2. a Supabase project's API on this machine: a Postgres of its own on a
#      random port with Supabase's roles (testing/lib/local-postgres.sh), and
#      on it the REAL Supabase Auth (GoTrue) and Data API (PostgREST) — pinned
#      releases, checksummed (testing/lib/local-supabase.sh) — with Auth set
#      the way the supabase root sets a project's (sign-up signs the user in);
#      a stand-in for the ONE Management API endpoint the migration runner
#      calls (testing/lib/fake-supabase-api.py);
#   3. the db-migrate lane's own steps, rendered by `orun plan` for a push to
#      main and run IN THE TREE THE RUNNER STAGES for the job: install, build
#      @saas/db, apply — upstream's schema with its policies, then row-level
#      security re-enabled and checked on every table in `public` — then apply
#      again, which must apply nothing, and the pull-request profile's offline
#      plan;
#   4. the Data API and one gateway in front of both services that checks the
#      API key, as Kong does (testing/lib/supabase-gateway.py) — the origin
#      the stage wiring document names;
#   5. the web lane's own steps for stage, rendered for a pull request (the
#      verify profile carries deploy-dry-run; the deploy profile does not) and
#      run in its staged job tree: install, `verify-app-structure` (the
#      committed wrangler.jsonc must exist BEFORE the build, in a tree with no
#      build output), `build-app` — which re-renders the config from the
#      stage wiring document it is handed, as the deploy does, inlines its
#      public half, and pushes nothing (a verify lane holds no Cloudflare
#      credential) — then `verify-build-output` and `deploy-dry-run`. The
#      service-role key must be in no wrangler file and no bundle;
#   6. the built Worker under `wrangler dev`, its one secret the service-role
#      key written by the same tool the deploy pushes it with, NO Stripe key —
#      and the component's OWN `smokeCommand` against it, verbatim; then every
#      route the product promises: the pages carry the product's name, pricing
#      shows the sample plans with checkout off and says Stripe is not
#      connected (not a 500), the webhook answers 503, `/api/health` (answered
#      only by the Worker) answers ok, and a visitor signs up, opens the
#      account page, renames themselves, is told checkout and the portal need
#      Stripe, signs out, fails a wrong password and signs in again — every
#      step through the app's OWN server actions, as its pages call them;
#   7. the Data API's view of the same project: every table in `public` has
#      row-level security; the anon key reads no user, customer or
#      subscription and writes nothing; the signed-in user reads their own row
#      and nobody's customer record; the service role, as the webhook's sync,
#      reads and writes everything.
#
# What it cannot do is the platform's half: create the repository, mint the
# brokered tokens, create a real Supabase project (Terraform is validated,
# not applied, in this repository), push the Worker secret and deploy for
# real, and probe workers.dev. That is a bootstrap against a workspace
# (BOOTSTRAP.md); everything short of it is here.
#
# Needs: orun, node, pnpm, python3 (+PyYAML), git, curl, tar (xz), sha256sum,
# psql and a PostgreSQL server install (initdb, pg_ctl), and the network for
# `pnpm install` and the two pinned releases (or a warm store and cache —
# SUPABASE_E2E_CACHE, default ~/.cache/supabase-e2e). A few minutes: three
# installs, two builds.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=lib/bootstrap.sh
source "$here/lib/bootstrap.sh"
# shellcheck source=lib/local-postgres.sh
source "$here/lib/local-postgres.sh"
# shellcheck source=lib/local-supabase.sh
source "$here/lib/local-supabase.sh"

for bin in orun node pnpm python3 git curl psql tar sha256sum; do
  command -v "$bin" >/dev/null || { echo "e2e.test.sh needs $bin on PATH" >&2; exit 1; }
done
pg_bin >/dev/null || { echo "e2e.test.sh needs a PostgreSQL server install (initdb, pg_ctl)" >&2; exit 1; }
# Nothing here deploys. A Cloudflare credential in the caller's environment
# would make the web lane's build push its secret to a real account.
unset CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID

scratch="$(mktemp -d)"
pgdir="$(mktemp -d)"
dev_pid=""
api_pid=""
gw_pid=""
SB_AUTH_PID=""
SB_REST_PID=""
# wrangler dev runs under pnpm, node and two workerd processes; a TERM to the
# first does not reach the rest, and waiting on it then never returns. So each
# server is started as its own process group (setsid) and the group stopped.
stop_group() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- "-$pid" 2>/dev/null || break; sleep 0.5; done
  kill -KILL -- "-$pid" 2>/dev/null || true
}
cleanup() {
  stop_group "$dev_pid"
  stop_group "$gw_pid"
  stop_group "$SB_REST_PID"
  stop_group "$SB_AUTH_PID"
  stop_group "$api_pid"
  pg_down "$pgdir"
  [ -n "$pgdir" ] && [ -d "$pgdir" ] && rm -rf "$pgdir"
  [ -n "$scratch" ] && [ -d "$scratch" ] && rm -rf "$scratch"
}
trap cleanup EXIT
free_port() { python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()"; }
values="$here/fixtures/acme.json"
repo="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['reponame'])" "$values")"
sub="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['subdomain'])" "$values")"
export CI=1 WRANGLER_SEND_METRICS=false NEXT_TELEMETRY_DISABLED=1 TURBO_TELEMETRY_DISABLED=1

# What checks.yml runs, step for step, read out of the workflow the product
# carries so the two cannot drift: every `run:` of its one job, in order.
checks() { # DIR LOG
  local dir="$1" log="$2" cmd
  while IFS= read -r cmd; do
    echo "   \$ $cmd" | tee -a "$log"
    if ! (cd "$dir" && bash -c "$cmd") >> "$log" 2>&1; then
      echo "FAIL: \`$cmd\` failed in $dir" >&2; tail -40 "$log" >&2; return 1
    fi
  done < <(python3 - "$dir/.github/workflows/checks.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    for step in job["steps"]:
        if "run" in step:
            print(step["run"].strip())
PY
)
}

# One job of a plan, written out as the runner would run it: each `run:` step
# (the `use:` actions are setup-node and setup-pnpm, which this machine has)
# as a numbered script, the job's env, and the component path the steps run
# in. Steps are picked BY ID when given, else every `run:` step in order.
extract_job() { # PLAN JOB-ID OUT-DIR [STEP-ID…]
  python3 - "$@" <<'PY'
import json, pathlib, sys
plan, jid, out, *want = sys.argv[1:]
job = next((j for j in json.load(open(plan))["jobs"] if j["id"] == jid), None)
if job is None:
    sys.exit(f"the plan has no job {jid}")
out = pathlib.Path(out); out.mkdir(parents=True)
steps = [s for s in job["steps"] if s.get("run")]
if want:
    by = {s["id"]: s for s in steps}
    missing = [w for w in want if w not in by]
    if missing:
        sys.exit(f"{jid} has no step(s) {missing}")
    steps = [by[w] for w in want]
for i, s in enumerate(steps):
    (out / f"{i:02d}.sh").write_text(s["run"])
    (out / f"{i:02d}.id").write_text(s["id"])
(out / "path").write_text(job.get("path") or ".")
with (out / "env").open("w") as f:
    for k, v in (job.get("env") or {}).items():
        f.write(f"export {k}={json.dumps(v)}\n")
PY
}
run_job() { # STEPS-DIR WORK-TREE ENV LOG-PREFIX
  local steps="$1" work="$2" envname="$3" logp="$4" s id
  for s in "$steps"/[0-9][0-9].sh; do
    id="$(cat "${s%.sh}.id")"
    echo "   ▸ $id"
    if ! (cd "$work/$(cat "$steps/path")" && source "$steps/env" && export ORUN_ENVIRONMENT="$envname" \
          && bash -e "$s") > "$logp-$id.log" 2>&1; then
      echo "FAIL: the lane's $id step" >&2; tail -40 "$logp-$id.log" >&2; return 1
    fi
  done
}

echo "── the offline bootstrap (testing/lib/bootstrap.sh)"
tree="$scratch/$repo"
bootstrap_offline "$root" "$tree" "$values" "$scratch/logs" > "$scratch/bootstrap.log" 2>&1 || {
  echo "FAIL: the offline bootstrap stopped" >&2; tail -40 "$scratch/bootstrap.log" >&2; exit 1; }
echo "   2 phases placed and landed"

# ── 1. the product's own pull request ──────────────────────────────────────
echo "── 01-product's landing, under the checks its PR waits on"
s01="$(git -C "$tree" rev-parse HEAD~1)"
at01="$scratch/at-01/$repo"
git -C "$tree" worktree add -q "$at01" "$s01"
checks "$at01" "$scratch/checks.log"
dirty="$(git -C "$at01" status --porcelain)"
[ -z "$dirty" ] || { echo "FAIL: the checks changed tracked files — the committed wrangler.jsonc is not the fixture render:" >&2; echo "$dirty" >&2; exit 1; }
echo "   the checks left the tree as committed (wire:fixture rendered the committed wrangler.jsonc)"

# ── 2. a Supabase project's database and Auth, and the Management API ──────
echo "── a local Supabase: Postgres, Auth (GoTrue v$SB_AUTH_VERSION), the Management API stand-in"
pg_port="$(free_port)"
pgurl="$(pg_up "$pgdir" "$pg_port")" || { echo "FAIL: Postgres did not start" >&2; exit 1; }
pg_admin="postgres://supabase_admin@127.0.0.1:$pg_port/postgres"
sb_roles "$pg_admin" > "$scratch/roles.log" 2>&1 || { echo "FAIL: Supabase's roles" >&2; cat "$scratch/roles.log" >&2; exit 1; }
sbbin="$(sb_fetch "${SUPABASE_E2E_CACHE:-$HOME/.cache/supabase-e2e}")" || { echo "FAIL: the pinned Auth and Data API releases" >&2; exit 1; }
jwt_secret="$(python3 -c "import secrets;print(secrets.token_hex(32))")"
anon_key="$(sb_jwt "$jwt_secret" anon)"
service_key="$(sb_jwt "$jwt_secret" service_role)"
auth_port="$(free_port)"; rest_port="$(free_port)"; gw_port="$(free_port)"
gateway="http://127.0.0.1:$gw_port"
# Auth's Site URL is what the supabase root sets: the stage Worker's origin.
sb_auth_up "$sbbin" "$pg_port" "$auth_port" "$gateway" "https://$repo-web-stage.$sub.workers.dev" \
  "$jwt_secret" "$scratch/auth.log" || { echo "FAIL: Supabase Auth did not start" >&2; exit 1; }
sb_auth_grants "$pg_admin" > "$scratch/grants.log" 2>&1 || { echo "FAIL: the grants on auth" >&2; cat "$scratch/grants.log" >&2; exit 1; }
api_port="$(free_port)"
ref="localproject"
setsid python3 "$here/lib/fake-supabase-api.py" "$api_port" "$pgurl" --ref "$ref" > "$scratch/api.log" 2>&1 < /dev/null &
api_pid=$!
for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$api_port/" && break; sleep 0.3; done
echo "   $pgurl; Auth on :$auth_port (its own migrations applied); the Management API on :$api_port"

# The two plans the lanes below run from, each in the product's own tree: a
# push to main at the 01-product commit (the db-migrate lane's APPLY profile),
# and a pull request over the finished product against an empty base (the web
# lane's VERIFY profile, which carries deploy-dry-run, and db-migrate's PLAN).
(cd "$at01" && orun plan --intent intent.yaml --trigger github-push-main --env stage --output "$scratch/plan-main.json") > "$scratch/plan-main.log" 2>&1 \
  || { echo "FAIL: orun plan (push to main)" >&2; tail -15 "$scratch/plan-main.log" >&2; exit 1; }
git -C "$tree" worktree remove --force "$at01"
mkdir -p "$scratch/pr"
git clone -q "$tree" "$scratch/pr/$repo"
prtree="$scratch/pr/$repo"
git -C "$prtree" checkout -q --orphan empty
git -C "$prtree" rm -rqf .
git -C "$prtree" -c user.email=t@example.invalid -c user.name=t commit -qm empty --allow-empty
git -C "$prtree" checkout -q main
(cd "$prtree" && orun plan --intent intent.yaml --trigger github-pull-request --base empty --head HEAD --env stage \
   --output "$scratch/plan-pr.json") > "$scratch/plan-pr.log" 2>&1 \
  || { echo "FAIL: orun plan (pull request)" >&2; tail -15 "$scratch/plan-pr.log" >&2; exit 1; }
# This tier runs the orun the product's CI pins, which reads the per-edge
# `modeRules`: on a pull request — which applies and deploys nothing — the
# infrastructure edges that order a push to main are advisory, so no lane
# waits on another. (placement.test.sh checks the push to main's order.)
python3 - "$scratch/plan-pr.json" <<'PY'
import json, sys
jobs = {j["component"]: j for j in json.load(open(sys.argv[1]))["jobs"] if j["environment"] == "stage"}
chain = ["supabase", "db-migrate", "web"]
for a, b in zip(chain, chain[1:]):
    ja, jb = jobs[a], jobs[b]
    if ja["id"] in (jb.get("dependsOn") or []) or ja["id"] not in (jb.get("advisoryDependsOn") or []):
        sys.exit(f"FAIL: on a pull request {b}@stage must name {a}@stage as advisory, not wait on it")
print("   pull request: " + " → ".join(chain) + ", every edge advisory")
PY

# ── 3. the db-migrate lane, in its staged job tree ─────────────────────────
echo "── the stage db-migrate lane: install, build @saas/db, apply — then apply again, and the PR's plan"
extract_job "$scratch/plan-main.json" db-migrate.stage.migrate "$scratch/steps-migrate" \
  install-dependencies build-db-package "Migration Apply"
extract_job "$scratch/plan-main.json" db-migrate.stage.migrate "$scratch/steps-migrate-again" "Migration Apply"
extract_job "$scratch/plan-pr.json" db-migrate.stage.migrate "$scratch/steps-migrate-plan" "Migration Plan"
# Staged from the fresh clone (a CI checkout: no build output, no
# node_modules); its migrations are the 01-product commit's, byte for byte.
mwork="$prtree/.orun/runs/e2e/db-migrate.stage.migrate/work"
python3 "$here/lib/stage-job.py" "$prtree" "$mwork"
# The component's secretEnv, as the lane resolves it: the supabase apply's
# published credentials and the brokered access token. SUPABASE_API_URL is
# the one value no lane has — it points the runner at the stand-in.
export SUPABASE_ACCESS_TOKEN=e2e-token SUPABASE_PROJECT_REF="$ref" SUPABASE_DB_PASSWORD=postgres \
       SUPABASE_DB_URL="$pgurl" SUPABASE_API_URL="http://127.0.0.1:$api_port"
run_job "$scratch/steps-migrate" "$mwork" stage "$scratch/migrate"
applied() { python3 -c "import json,sys;t=open(sys.argv[1]).read();print(' '.join(json.loads(t[t.index('{'):t.rindex('}')+1])['applied']))" "$1"; }
want="000_control_baseline 010_subscriptions_init 020_row_level_security"
[ "$(applied "$scratch/migrate-Migration Apply.log")" = "$want" ] \
  || { echo "FAIL: the first apply applied '$(applied "$scratch/migrate-Migration Apply.log")', not '$want'" >&2; exit 1; }
echo "   applied $want"
run_job "$scratch/steps-migrate-again" "$mwork" stage "$scratch/migrate-again"
[ -z "$(applied "$scratch/migrate-again-Migration Apply.log")" ] \
  || { echo "FAIL: a second apply applied '$(applied "$scratch/migrate-again-Migration Apply.log")'" >&2; exit 1; }
echo "   a second apply applied nothing (the ledger holds $(psql "$pgurl" -XAtc 'select count(*) from _migrations.applied') migrations)"
run_job "$scratch/steps-migrate-plan" "$mwork" stage "$scratch/migrate-plan"
[ "$(applied "$scratch/migrate-plan-Migration Plan.log")" = "$want" ] \
  || { echo "FAIL: the pull request's offline plan did not verify every migration" >&2; exit 1; }
echo "   the pull request's plan step verifies every migration's checksum offline"
unset SUPABASE_ACCESS_TOKEN SUPABASE_PROJECT_REF SUPABASE_DB_PASSWORD SUPABASE_DB_URL SUPABASE_API_URL
rm -rf "$mwork"

# ── 4. the Data API, and the project's one origin ──────────────────────────
echo "── the Data API (PostgREST v$SB_REST_VERSION) over the migrated schema, behind the gateway"
sb_rest_up "$sbbin" "$pg_port" "$rest_port" "$jwt_secret" "$scratch/rest.log" || { echo "FAIL: the Data API did not start" >&2; exit 1; }
setsid python3 "$here/lib/supabase-gateway.py" "$gw_port" "$auth_port" "$rest_port" "$anon_key" "$service_key" \
  > "$scratch/gateway.log" 2>&1 < /dev/null &
gw_pid=$!
for _ in $(seq 1 30); do curl -s -o /dev/null "$gateway/rest/v1/" && break; sleep 0.3; done
[ "$(curl -s -o /dev/null -w '%{http_code}' "$gateway/rest/v1/products")" = 401 ] \
  || { echo "FAIL: the gateway served the Data API without an API key" >&2; exit 1; }
echo "   $gateway: /auth/v1 and /rest/v1, the anon and service-role keys checked"

# ── 5. the web lane's steps, for stage ─────────────────────────────────────
echo "── the stage web lane: install, verify-app-structure, build-app, verify-build-output, deploy-dry-run"
extract_job "$scratch/plan-pr.json" web.stage.verify-deploy "$scratch/steps-web" \
  install-workspace-dependencies verify-app-structure build-app verify-build-output deploy-dry-run
work="$prtree/.orun/runs/e2e/web.stage.verify-deploy/work"
# The job's private tree, staged as orun stages it — no build output, no
# node_modules: under stack-tectonic 0.19.0 the job installs inside it.
python3 "$here/lib/stage-job.py" "$prtree" "$work"
[ ! -e "$work/apps/web/.open-next" ] && [ -f "$work/apps/web/wrangler.jsonc" ] \
  || { echo "FAIL: the staged tree is not a fresh checkout with the committed wrangler.jsonc" >&2; exit 1; }
echo "   staged: $(realpath --relative-to="$prtree" "$work") — no build output, the committed wrangler.jsonc"
# The stage wiring document, as the supabase apply publishes it and the lane
# resolves it (secretEnv WIRING_SUPABASE_STAGE): this project's origin and
# its two keys.
wiring="$(python3 -c "import json,sys;print(json.dumps({'supabase_url':sys.argv[1],'supabase_anon_key':sys.argv[2],'supabase_service_role_key':sys.argv[3]}))" "$gateway" "$anon_key" "$service_key")"
export WIRING_SUPABASE_STAGE="$wiring"
run_job "$scratch/steps-web" "$work" stage "$scratch/web"
build_log="$scratch/web-build-app.log"
grep -q '(Turbopack)' "$build_log" \
  || { echo "FAIL: the staged build did not run on Turbopack" >&2; grep -m3 'Next.js' "$build_log" >&2; exit 1; }
grep -q "\"NEXT_PUBLIC_SUPABASE_URL\": \"$gateway\"" "$work/apps/web/wrangler.jsonc" \
  || { echo "FAIL: build-app did not re-render wrangler.jsonc from the stage wiring document" >&2; exit 1; }
grep -q "secrets: no Cloudflare credential in this job" "$build_log" \
  || { echo "FAIL: the verify lane's build-app did not stand down from pushing the Worker secret" >&2; exit 1; }
[ "$(node -e 'const fs=require("fs");process.stdout.write(String(fs.readdirSync(process.argv[1]).length))' "$work/node_modules")" -gt 0 ] && [ ! -L "$work/node_modules" ] \
  || { echo "FAIL: the job's install did not land inside its own tree" >&2; exit 1; }
# Inlined: the public half, in the browser's bundle. Nowhere: the service-role key.
grep -rqF "$gateway" "$work/apps/web/.open-next/assets/_next/static" \
  || { echo "FAIL: the browser bundle does not carry the project URL it was built for" >&2; exit 1; }
if grep -rlF "$service_key" "$work/apps/web/.open-next" "$work/apps/web/.next" "$work/apps/web/wrangler.jsonc" > "$scratch/leaked" 2>/dev/null; then
  echo "FAIL: the service-role key is in the build or the wrangler config:" >&2; head -5 "$scratch/leaked" >&2; exit 1
fi
echo "   the staged build ran on Turbopack, inside its own tree, inlined the stage project's URL and anon key, and carries no service-role key"

# ── 6. serve it with no Stripe key ─────────────────────────────────────────
echo "── wrangler dev over the built Worker, its one secret the service-role key"
[ ! -e "$work/apps/web/.dev.vars" ] || { echo "FAIL: the staged tree carries a .dev.vars" >&2; exit 1; }
# The deploy lane pushes the document's service-role key with `wrangler
# secret bulk`; wrangler dev reads .dev.vars as the Worker's secrets. Same
# tool, same mapping, written locally instead of pushed.
secret_args="$(sed -n 's/.*tooling\/wire\/secrets\.mjs --component supabase --env "${ORUN_ENVIRONMENT}" \(--secret [^ ]*\).*/\1/p' "$tree/apps/web/component.yaml")"
[ -n "$secret_args" ] || { echo "FAIL: component.yaml's buildCommand pushes no secret" >&2; exit 1; }
(cd "$work/apps/web" && node ../../tooling/wire/secrets.mjs --component supabase --env stage $secret_args --dev-vars .dev.vars) > "$scratch/devvars.log" 2>&1 \
  || { echo "FAIL: the secret mapping" >&2; cat "$scratch/devvars.log" >&2; exit 1; }
[ "$(cut -d= -f1 "$work/apps/web/.dev.vars")" = SUPABASE_SERVICE_ROLE_KEY ] \
  || { echo "FAIL: .dev.vars holds more than the service-role key" >&2; exit 1; }
unset WIRING_SUPABASE_STAGE
port="$(free_port)"
(cd "$work/apps/web" && exec setsid pnpm exec wrangler dev --config wrangler.jsonc --ip 127.0.0.1 --port "$port" \
   --name "$repo-web-stage" --show-interactive-dev-session=false) > "$scratch/dev.log" 2>&1 < /dev/null &
dev_pid=$!
url="http://127.0.0.1:$port"
for _ in $(seq 1 90); do
  curl -s -o /dev/null "$url/" && break
  kill -0 "$dev_pid" 2>/dev/null || { echo "FAIL: wrangler dev exited" >&2; tail -30 "$scratch/dev.log" >&2; exit 1; }
  sleep 1
done
curl -s -o /dev/null "$url/" || { echo "FAIL: wrangler dev never answered" >&2; tail -30 "$scratch/dev.log" >&2; exit 1; }

echo "   ▸ the component's own smokeCommand, DEPLOYED_URL=$url"
smoke="$(python3 -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['spec']['parameters']['smokeCommand'])" "$tree/apps/web/component.yaml")"
DEPLOYED_URL="$url" bash -c "$smoke" || { echo "FAIL: the deploy's smoke refused the product" >&2; tail -20 "$scratch/dev.log" >&2; exit 1; }

echo "   ▸ every route the product promises, and a visitor signing up, out and in"
python3 - "$url" "$values" "$work/apps/web/.next/server/server-reference-manifest.json" "$gateway" "$anon_key" "$service_key" "$scratch/user.json" <<'PY' \
  || { echo "FAIL: the routes; wrangler dev said:" >&2; tail -40 "$scratch/dev.log" >&2; exit 1; }
import base64, html, http.client, json, re, sys, time, urllib.error, urllib.parse, urllib.request, uuid
base, values, manifest, gateway, anon_key, service_key, user_out = sys.argv[1:8]
values = json.load(open(values))
name = values["productname"]
problems = []
def bad(m): problems.append(m)

# The app's server actions, by the name its code exports them under, from
# the build's own manifest — the ids its client bundle calls them by.
ACTIONS = {v["exportedName"]: k for k, v in json.load(open(manifest))["node"].items()}

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
opener = urllib.request.build_opener(NoRedirect)
jar = {}
def remember(headers):
    for k, v in headers:
        if k.lower() != "set-cookie":
            continue
        cookie, _, attrs = v.partition(";")
        n, _, val = cookie.partition("=")
        if not val or re.search(r"max-age=0\b", attrs, re.I) or "1970" in attrs:
            jar.pop(n.strip(), None)
        else:
            jar[n.strip()] = val
def req(path, data=None, headers=None, method=None, use_jar=True):
    # A GET whose CONNECTION drops (not one that answers an error) is asked
    # again, twice at most, and says so: `wrangler dev` on a loaded machine
    # has dropped one. A POST is never repeated — it would submit twice.
    for attempt in range(3):
        h = dict(headers or {})
        if use_jar and jar:
            h["cookie"] = "; ".join(f"{k}={v}" for k, v in jar.items())
        r = urllib.request.Request(base + path, data=data, headers=h, method=method)
        try:
            with opener.open(r, timeout=60) as resp:
                if use_jar:
                    remember(resp.headers.items())
                return resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read().decode()
        except urllib.error.HTTPError as e:
            if use_jar:
                remember(e.headers.items())
            return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read().decode()
        except (http.client.RemoteDisconnected, ConnectionResetError) as e:
            if data is not None or attempt == 2:
                raise
            print(f"   (GET {path}: the connection dropped ({e.__class__.__name__}) — asking again)")
            time.sleep(1)
def location(h):
    return urllib.parse.urlparse(h.get("location", "")).path

# A server action, called the way the app's client components call it
# (`handleRequest(e, signUp, router)` and friends): a POST to the page that
# renders the form, `Next-Action: <id>`, the arguments encoded as React's
# encodeReply encodes them. A FormData argument travels as multipart fields
# under its reference's prefix — `_1_<field>` since React 19.3, `1_<field>`
# before it; both are sent, and each decoder reads only its own. The
# action's return value is the RSC payload's row 1.
def action(page, fn, form=None, args=None):
    h = {"next-action": ACTIONS[fn], "accept": "text/x-component", "origin": base}
    if form is not None:
        b = uuid.uuid4().hex
        fields = [("0", '["$K1"]')]
        for k, v in form.items():
            fields += [(f"_1_{k}", v), (f"1_{k}", v)]
        body = "".join(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n' for k, v in fields)
        body += f"--{b}--\r\n"
        h["content-type"] = f"multipart/form-data; boundary={b}"
        data = body.encode()
    else:
        h["content-type"] = "text/plain;charset=UTF-8"
        data = json.dumps(args).encode()
    s, hd, payload = req(page, data, h, "POST")
    for line in payload.splitlines():
        if line.startswith("1:"):
            return s, json.loads(line[2:])
    return s, None
def text(fragment):
    return html.unescape(re.sub(r"<[^>]+>", "", fragment)).strip()

# ── the public pages, under the product's own name ────────────────────────
s, _, home = req("/")
if s != 200:
    bad(f"/ answered {s}")
title = re.search(r"<title>(.*?)</title>", home, re.S)
if not title or html.unescape(title.group(1)) != name:
    bad(f"the pricing page's <title> is {title and title.group(1)!r}, not {name!r}")
if name not in [text(m) for m in re.findall(r"<span>(.*?)</span>", home, re.S)]:
    bad(f"the footer's brand does not read {name!r}")
if f"{name}, Inc. All rights reserved." not in html.unescape(re.sub(r"<!-- -->", "", home)):
    bad("the footer's copyright line does not name the product")
if ">ACME<" in home or "ACME, Inc." in home:
    bad("the pricing page still carries the baseline's name")
if 'href="https://github.com/vercel/nextjs-subscription-payments"' not in home:
    bad("the footer's upstream link was renamed")
# Pricing with no Stripe key: the template's sample plans, checkout off, and
# the notice — not upstream's "No subscription pricing plans found".
if 'data-stripe="not-connected"' not in home or "Connect Stripe to enable checkout." not in home:
    bad("/ does not say Stripe is not connected")
if "sample plans" not in home:
    bad("/ does not say the plans are the template's samples")
for plan in ("Hobby", "Freelancer"):
    if f">{plan}<" not in home:
        bad(f"/ does not show the {plan} plan")
if "$10" not in home or "$20" not in home:
    bad("/ does not show the plans' monthly prices")
buttons = [b for b in re.findall(r"<button[^>]*>.*?</button>", home, re.S) if ">Subscribe<" in b]
if len(buttons) != 2 or not all(re.search(r"\sdisabled(=\"\")?[\s>]", b) for b in buttons):
    bad(f"/'s two Subscribe buttons are not disabled: {[b[:120] for b in buttons]}")
if "No subscription pricing plans found" in home:
    bad("/ shows upstream's empty state instead of the sample plans")

s, h, _ = req("/signin")
if s != 307 or location(h) != "/signin/password_signin":
    bad(f"/signin answered {s} → {h.get('location')}, not 307 → /signin/password_signin")
for path, want in (("/signin/password_signin", 200), ("/signin/signup", 200), ("/signin/email_signin", 200),
                   ("/signin/forgot_password", 200), ("/no-such-page", 404)):
    s, _, _ = req(path)
    if s != want:
        bad(f"{path} answered {s}, want {want}")
s, h, _ = req("/account")
if s != 307 or location(h) != "/signin":
    bad(f"/account signed out answered {s} → {h.get('location')}, not 307 → /signin")
s, h, _ = req("/auth/callback")
if s != 307 or location(h) != "/account":
    bad(f"/auth/callback without a code answered {s} → {h.get('location')}, not 307 → /account")

# ── what only the Worker answers ──────────────────────────────────────────
s, _, body = req("/api/health")
if s != 200 or json.loads(body) != {"ok": True, "supabase": "reachable", "schema": "migrated", "serviceRole": "valid"}:
    bad(f"/api/health answered {s} {body}")
s, _, body = req("/api/webhooks", b'{"id":"evt_1"}', {"stripe-signature": "t=1,v1=x"}, "POST")
if s != 503 or json.loads(body) != {"error": "Stripe is not connected."}:
    bad(f"the Stripe webhook answered {s} {body[:80]}, not 503 'Stripe is not connected.'")

# ── a visitor signs up, through the app's own server action ───────────────
email, password = "sam@seats.example", "correct horse battery"
s, result = action("/signin/signup", "signUp", {"email": email, "password": password})
signed_in = "/?status=Success!&status_description=You%20are%20now%20signed%20in."
session_cookies = [k for k in jar if re.match(r"^sb-.+-auth-token(\.\d+)?$", k)]
if s != 200 or result != signed_in or not session_cookies:
    bad(f"sign-up answered {s} {result!r} with session cookies {session_cookies}")
s, _, account = req("/account")
if s != 200 or email not in account or ">Account<" not in account:
    bad(f"/account signed in answered {s}, without the user's email")
s, _, home = req("/")
if ">Sign out<" not in home or "Connect Stripe to enable checkout." not in home:
    bad("/ signed in does not offer sign-out, or lost the Stripe notice")
s, result = action("/account", "updateName", {"fullName": "Sam Seats"})
if result != "/account?status=Success!&status_description=Your%20name%20has%20been%20updated.":
    bad(f"renaming answered {s} {result!r}")
# Checkout and the customer portal, called directly (the Subscribe buttons
# are disabled): both answer with the notice, never a 500.
s, result = action("/", "checkoutWithStripe", args=[{"id": "sample_price_hobby_month", "type": "recurring",
                                                      "trial_period_days": None}, "/"])
if s != 200 or not str((result or {}).get("errorRedirect", "")).startswith("/?error=Stripe%20is%20not%20connected."):
    bad(f"checkout without Stripe answered {s} {result!r}")
s, result = action("/account", "createStripePortal", args=["/account"])
if s != 200 or not str(result).startswith("/account?error=Stripe%20is%20not%20connected."):
    bad(f"the customer portal without Stripe answered {s} {result!r}")

# ── signs out, fails a wrong password, signs in again ─────────────────────
s, result = action("/account", "SignOut", {"pathName": "/account"})
if result != "/signin" or any(re.match(r"^sb-.+-auth-token(\.\d+)?$", k) for k in jar):
    bad(f"sign-out answered {s} {result!r}, cookies left {sorted(jar)}")
s, h, _ = req("/account")
if s != 307 or location(h) != "/signin":
    bad(f"/account after sign-out answered {s} → {h.get('location')}")
s, result = action("/signin/password_signin", "signInWithPassword", {"email": email, "password": "not the password"})
if not str(result).startswith("/signin/password_signin?error=Sign%20in%20failed."):
    bad(f"a wrong password answered {s} {result!r}")
s, result = action("/signin/password_signin", "signInWithPassword", {"email": email, "password": password})
if result != signed_in:
    bad(f"sign-in answered {s} {result!r}")
s, _, account = req("/account")
if s != 200 or email not in account:
    bad(f"/account after sign-in answered {s}, without the user's email")

# The session the cookies carry, for the Data API checks below: @supabase/ssr
# stores it base64url-encoded, split across numbered cookies when it is long.
def session():
    chunks = sorted((k for k in jar if re.match(r"^sb-.+-auth-token(\.\d+)?$", k)),
                    key=lambda k: int(k.rsplit(".", 1)[1]) if k[-1].isdigit() and "." in k else -1)
    raw = "".join(urllib.parse.unquote(jar[k]) for k in chunks)
    if raw.startswith("base64-"):
        raw = base64.urlsafe_b64decode(raw[7:] + "=" * (-len(raw[7:]) % 4)).decode()
    return json.loads(raw)
try:
    sess = session()
    json.dump({"id": sess["user"]["id"], "access_token": sess["access_token"],
               "cookie": "; ".join(f"{k}={v}" for k, v in jar.items())}, open(user_out, "w"))
except Exception as e:
    bad(f"the session cookie does not carry a session: {e}")

if problems:
    for p in problems:
        print(f"  ✕ {p}", file=sys.stderr)
    sys.exit(1)
print(f"   /: {name!r}, the sample plans, checkout off and the Stripe notice; the sign-in views; /account guarded; "
      f"/api/health ok; the webhook 503; a sign-up, the account page, a rename, checkout and the portal "
      f"answering 'Stripe is not connected.', a sign-out, a refused password and a sign-in — every step an action of the app's own")
PY

# ── 7. what Supabase's Data API serves, and to whom ────────────────────────
echo "── the Data API's view of the same project: the anon key, the signed-in user, the service role"
python3 - "$gateway" "$anon_key" "$service_key" "$scratch/user.json" "$url" <<'PY' \
  || { echo "FAIL: row-level security through the Data API; PostgREST said:" >&2; tail -20 "$scratch/rest.log" >&2; exit 1; }
import json, sys, urllib.error, urllib.request
gateway, anon, service, user, app = sys.argv[1], sys.argv[2], sys.argv[3], json.load(open(sys.argv[4])), sys.argv[5]
problems = []
def bad(m): problems.append(m)
def api(method, path, token, apikey=None, body=None, prefer=None):
    h = {"apikey": apikey or anon, "authorization": f"Bearer {token}", "content-type": "application/json"}
    if prefer:
        h["prefer"] = prefer
    r = urllib.request.Request(gateway + "/rest/v1/" + path, data=json.dumps(body).encode() if body is not None else None,
                               headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        return e.code, json.loads(raw) if raw else None

# The webhook's sync, as utils/supabase/admin.ts does it: the service role
# writes a plan, the user's Stripe customer and a subscription.
s, _ = api("POST", "products", service, apikey=service, body={"id": "prod_e2e", "active": True, "name": "Pro"})
s2, _ = api("POST", "prices", service, apikey=service, body={"id": "price_e2e", "product_id": "prod_e2e", "active": True,
             "currency": "usd", "type": "recurring", "unit_amount": 900, "interval": "month", "interval_count": 1})
s3, _ = api("POST", "customers", service, apikey=service, body={"id": user["id"], "stripe_customer_id": "cus_e2e"})
s4, _ = api("POST", "subscriptions", service, apikey=service, body={"id": "sub_e2e", "user_id": user["id"],
             "status": "active", "price_id": "price_e2e"})
if (s, s2, s3, s4) != (201, 201, 201, 201):
    bad(f"the service role could not write as the webhook does: {(s, s2, s3, s4)}")

# The anon key, which every browser holds: the plans, and nothing else.
for table, want in (("products", 1), ("prices", 1), ("users", 0), ("customers", 0), ("subscriptions", 0)):
    s, rows = api("GET", f"{table}?select=*", anon)
    if s != 200 or len(rows) != want:
        bad(f"the anon key reads {table}: {s} {len(rows) if isinstance(rows, list) else rows} row(s), want {want}")
for table, body in (("products", {"id": "prod_anon", "name": "Free"}),
                    ("customers", {"id": user["id"], "stripe_customer_id": "cus_anon"})):
    s, err = api("POST", table, anon, body=body)
    if s not in (401, 403) or (err or {}).get("code") != "42501":
        bad(f"the anon key wrote {table}: {s} {err}")
s, rows = api("PATCH", "users?id=eq." + user["id"], anon, body={"full_name": "Mallory"}, prefer="return=representation")
if s != 200 or rows != []:
    bad(f"the anon key updated a user: {s} {rows}")

# The signed-in user: their own row and subscription; never the customer map.
token = user["access_token"]
s, rows = api("GET", "users?select=id,full_name", token)
if s != 200 or [r["id"] for r in rows] != [user["id"]]:
    bad(f"the signed-in user reads users: {s} {rows}")
s, rows = api("GET", "subscriptions?select=id,prices(products(name))", token)
if s != 200 or [r["id"] for r in rows] != ["sub_e2e"]:
    bad(f"the signed-in user reads subscriptions: {s} {rows}")
s, rows = api("GET", "customers?select=*", token)
if s != 200 or rows != []:
    bad(f"the signed-in user reads the customer map: {s} {rows}")

# The service role (the webhook's sync, the customer mapping): everything.
s, rows = api("GET", "customers?select=*", service, apikey=service)
if s != 200 or len(rows) != 1:
    bad(f"the service role reads customers: {s} {rows}")

# …and the app, reading as the signed-in user through the same policies:
# its account page shows the subscription the sync wrote, its pricing page
# the synced plan instead of the samples (still no checkout: no Stripe key).
def page(path):
    r = urllib.request.Request(app + path, headers={"cookie": user["cookie"]})
    with urllib.request.urlopen(r, timeout=60) as resp:
        return resp.read().decode()
account = page("/account")
if "You are currently on the Pro plan." not in account or "$9/month" not in account:
    bad("the account page does not show the user's own subscription (read through row-level security)")
home = page("/")
if ">Pro<" not in home or ">Hobby<" in home or 'data-stripe="not-connected"' not in home:
    bad("the pricing page does not show the synced plan, with checkout still off")

if problems:
    for p in problems:
        print(f"  ✕ {p}", file=sys.stderr)
    sys.exit(1)
print("   the anon key: the plans, no user, customer or subscription, no write; the user: their own row and "
      "subscription, no customer record; the service role: everything; the app's account page: the user's own plan")
PY
psql "$pgurl" -X -q -v ON_ERROR_STOP=1 -At > "$scratch/rls.out" 2> "$scratch/rls.err" <<'SQL' \
  || { echo "FAIL: the catalog's row-level security" >&2; cat "$scratch/rls.err" >&2; exit 1; }
SELECT 'public tables without RLS: ' || count(*) FILTER (WHERE NOT c.relrowsecurity) || ' of ' || count(*)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p');
SQL
sed 's/^/   /' "$scratch/rls.out"
grep -qx "public tables without RLS: 0 of 5" "$scratch/rls.out" \
  || { echo "FAIL: a table in public is without row-level security" >&2; exit 1; }

echo "e2e.test.sh: ok"
