#!/usr/bin/env bash
# The phases in `repo-blueprint.yaml` must be the phases the bootstrap runs,
# placing what they are meant to place, in the order their hooks must run,
# saying what they are, and naming only what the engine can resolve.
#
# TWO PHASES, ONE LANDING THAT DEPLOYS. `01-product` places every module the
# blueprint declares — root files, workflows, tooling, the Supabase root, the
# migrations, the app and the tests — and lands them as
# ONE pull request; the convergence after that merge provisions and deploys it
# all, the order carried by the components' enforced `dependsOn` (placement
# proves it on the product's own plan). `02-docs` places nothing: it records
# the deployment and restores what 01-product deferred.
#
# The partition is written down a second time below on purpose: a module that
# drifts out of 01-product, or a phase that grows back between the two, is a
# change to how a product is built and has to be argued in the diff that edits
# both places. The hook ORDER is written down too: every step of the identity
# chain depends on the one before it (rebrand reads `git ls-files`, the verify
# reads the restaged tree, the credentials are minted after the link and
# before the landing whose convergence uses them), and a reorder fails live.
#
# Adapted from sourceplane/cirrus-baseline's testing/phases.test.sh: the
# narration rules and the hook-only rule are Cirrus's, unchanged.
#
# bash + python3 + PyYAML. No network, no fakes, no credential.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

echo "── repo-blueprint.yaml phases against what the bootstrap runs"
python3 - "$root" <<'PY'
import pathlib, re, sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required for the phase contract test (pip install pyyaml)")

root = pathlib.Path(sys.argv[1])
problems = []
def bad(m): problems.append(m)

bp = yaml.safe_load((root / "repo-blueprint.yaml").read_text())
phases = bp.get("phases") or []
if not phases:
    sys.exit("repo-blueprint.yaml declares no phases — this check has gone blind")

PRODUCT = ["ai-deployment", "ai-operations", "db", "db-migrate",
           "db-tests", "github-workflows", "rebrand-values", "root-gitignore", "root-intent",
           "root-package-json", "root-pnpm-lock",
           "root-pnpm-workspace", "root-readme", "root-turbo", "supabase", "tooling-eslint",
           "tooling-migrations", "tooling-tsconfig", "tooling-wire", "vscode", "web",
           "web-tests"]
PARTITION = {"01-product": PRODUCT, "02-docs": []}
HOOK_ONLY = {"02-docs"}
# The phase that DEPLOYS, and so must give a re-run something to land.
DEPLOYS = {"01-product"}

# The post hooks, in the order they must run (the brief's chain): the
# re-run marker and the git index; the rebrand and the re-tenant; the three
# rewrites a product needs before it lands; the restage and the verify; the
# lockfile; the repository and its link; one brokered reconcile per key;
# the landing. `secret-*` stands for the reconcile hooks, checked below.
POST_ORDER = {
    "01-product": ["retouch", "git-init", "stage", "rebrand", "orun-workspace",
                   "work-tree", "promotion", "dev-lanes", "restage", "rebrand-verify",
                   "pnpm-lockfile", "repo", "link", "secret-*", "land"],
    "02-docs": ["promotion", "dev-lanes", "render", "land"],
}
# The scripts behind the run: hooks that rewrite intent.yaml, with the mode
# each must be called in.
RUNS = {
    ("01-product", "work-tree"): ("tooling/bootstrap/work-tree.mjs", "--strip"),
    ("01-product", "promotion"): ("tooling/bootstrap/promotion.mjs", "--defer"),
    ("01-product", "dev-lanes"): ("tooling/bootstrap/dev-lanes.mjs", "--defer"),
    ("02-docs", "promotion"): ("tooling/bootstrap/promotion.mjs", "--restore"),
    ("02-docs", "dev-lanes"): ("tooling/bootstrap/dev-lanes.mjs", "--restore"),
    ("02-docs", "render"): ("hooks/render-deployment-docs.sh", None),
}
AWAIT_ORDER = {"01-product": ["orun.run/watch@", "orun.secrets/exists@", "orun.http/probe@"],
               "02-docs": ["orun.http/probe@"]}

by_name = {p["name"]: p for p in phases}
names = [p["name"] for p in phases]

# ── the order IS the execution order ──────────────────────────────────────
if names != sorted(names):
    bad(f"phases are not in execution order: {names}. The numbered name IS the "
        f"order; a phase out of sequence is a barrier in the wrong place.")
if names != list(PARTITION):
    bad(f"phases are {names}; the bootstrap runs {list(PARTITION)}")

# ── the partition has not drifted ─────────────────────────────────────────
for name, want in PARTITION.items():
    if name not in by_name:
        continue
    now = sorted(by_name[name].get("modules") or [])
    if now != sorted(want):
        bad(f"phase {name} no longer places what it placed: gained "
            f"{sorted(set(now) - set(want)) or '[]'}, lost {sorted(set(want) - set(now)) or '[]'}")
declared = {m["name"] for m in bp.get("modules") or []}
placed = {m for p in phases for m in (p.get("modules") or [])}
for m in sorted(declared - placed):
    bad(f"module {m} is declared and no phase places it")
for m in sorted(declared - set(PRODUCT)):
    bad(f"module {m} is declared and 01-product does not place it — every module lands in the one landing")
for name in HOOK_ONLY:
    if by_name.get(name, {}).get("modules"):
        bad(f"phase {name} places modules — it is declared as hooks only")

# ── nothing may GATE on a phase the tree cannot answer for ────────────────
for p in phases:
    for need in ((p.get("requires") or {}).get("phases") or []):
        if need in HOOK_ONLY:
            bad(f"phase {p['name']} requires {need}, which places no files — require "
                f"its predecessor instead")
        if need not in by_name or names.index(need) >= names.index(p["name"]):
            bad(f"phase {p['name']} requires {need}, which does not run before it")

# ── 01-product asks for every connection it mints from, before it creates anything
probe = ((by_name.get("01-product") or {}).get("requires") or {}).get("probe") or []
doctor = [h for h in probe if (h.get("uses") or "").startswith("orun.doctor/check@")]
want_providers = {"github", "cloudflare", "supabase"}
if not doctor or set((doctor[0].get("with") or {}).get("providers") or []) != want_providers:
    bad(f"01-product must probe {sorted(want_providers)} with orun.doctor/check@v1 before it places")
elif (doctor[0].get("with") or {}).get("githubOwner") != "{{ .inputs.githuborg }}":
    bad("01-product's doctor probe must wait for the GitHub App on the repository's owner")

# ── every phase says what it is and what to budget ────────────────────────
for p in phases:
    for field in ("title", "expectedMinutes"):
        if not p.get(field):
            bad(f"phase {p['name']} declares no {field} — an operator reads both")
    if not (p.get("hooks") or {}):
        bad(f"phase {p['name']} declares no hooks — a phase that only places files "
            f"still has to land them")

def hooks_of(p):
    h = p.get("hooks") or {}
    if isinstance(h, list):
        return list(h)
    return [x for slot in ("pre", "post", "await") for x in (h.get(slot) or [])]

run_hooks = list((bp.get("hooks") or {}).get("preInstantiate") or [])

# ── the hook chain, in order ──────────────────────────────────────────────
for name, want in POST_ORDER.items():
    p = by_name.get(name)
    if not p:
        continue
    post = (p.get("hooks") or {}).get("post") or []
    ids = [h.get("id") for h in post]
    folded = []
    for i in ids:
        tok = "secret-*" if (i or "").startswith("secret-") else i
        if not folded or folded[-1] != tok:
            folded.append(tok)
    if folded != want:
        bad(f"phase {name}'s post hooks run {ids}; the chain is {want}")
    for h in post:
        if (h.get("id") or "").startswith("secret-") and not (h.get("uses") or "").startswith("orun.integrations/reconcile@"):
            bad(f"phase {name} hook {h.get('id')} is not an orun.integrations/reconcile@v1")
        if (h.get("uses") or "").startswith("orun.integrations/reconcile@"):
            keys = (h.get("with") or {}).get("keys") or []
            if len(keys) != 1:
                bad(f"phase {name} hook {h.get('id')} reconciles {keys} — one key per hook, one scope per key")
    for (ph, hid), (script, mode) in RUNS.items():
        if ph != name:
            continue
        hook = next((h for h in post if h.get("id") == hid), None)
        argv = " ".join((hook or {}).get("run") or [])
        if script not in argv or (mode and mode not in argv):
            bad(f"phase {name} hook {hid} must run {script} {mode or ''}".rstrip())
for name, want in AWAIT_ORDER.items():
    awaits = ((by_name.get(name) or {}).get("hooks") or {}).get("await") or []
    got = [h.get("uses") or "" for h in awaits]
    if len(got) != len(want) or not all(g.startswith(w) for g, w in zip(got, want)):
        bad(f"phase {name}'s await hooks are {got}; they must be {want} (in that order)")

# ── the await checks what the infrastructure publishes, on stage and prod ─
# Each infra component's `secretOutputs` is what its apply lease-publishes;
# the landing's `orun.secrets/exists@v1` must ask for exactly those keys —
# every WIRING_* document and the Supabase project's credentials — on the
# environments that apply them.
published = set()
for comp in sorted(root.glob("infra/**/component.yaml")):
    params = ((yaml.safe_load(comp.read_text()) or {}).get("spec") or {}).get("parameters") or {}
    for pair in str(params.get("secretOutputs") or "").split(","):
        if "=" in pair:
            published.add(pair.split("=", 1)[0].strip())
if not published:
    bad("no infra component declares secretOutputs — this check has gone blind")
awaits = ((by_name.get("01-product") or {}).get("hooks") or {}).get("await") or []
exists = [h for h in awaits if (h.get("uses") or "").startswith("orun.secrets/exists@")]
if exists:
    w = exists[0].get("with") or {}
    if set(w.get("keys") or []) != published:
        bad(f"01-product awaits secrets {sorted(w.get('keys') or [])}; the infrastructure "
            f"publishes {sorted(published)}")
    if sorted(w.get("environments") or []) != ["prod", "stage"]:
        bad(f"01-product awaits the published secrets on {w.get('environments')}, not stage and prod")
    if w.get("project") != "{{ .inputs.reponame }}":
        bad("01-product awaits the published secrets in another project than the product's")
for name in names:
    for h in ((by_name[name].get("hooks") or {}).get("await") or []):
        if (h.get("uses") or "").startswith("orun.http/probe@"):
            urls = (h.get("with") or {}).get("urls") or []
            for env in ("stage", "prod"):
                base = f"https://{{{{ .inputs.reponame }}}}-web-{env}.{{{{ .inputs.subdomain }}}}.workers.dev"
                for want in (base, base + "/api/health"):
                    if want not in urls:
                        bad(f"phase {name}'s probe does not ask {want}")

# ── every phase lands, and every landing is bound to its task ─────────────
for p in phases:
    ids = [h.get("id") for h in hooks_of(p)]
    lands = [h for h in hooks_of(p) if (h.get("uses") or "").startswith("orun.pr/land@")]
    if len(lands) != 1:
        bad(f"phase {p['name']} has {len(lands)} landing(s); a phase is ONE pull request")
        continue
    w = lands[0].get("with") or {}
    if w.get("task") != "{{ .phase.hooks.task.outputs.key }}":
        bad(f"phase {p['name']} lands without binding the PR to its task key")
    if "task" not in ids or ids.index("task") > ids.index(lands[0].get("id")):
        bad(f"phase {p['name']} must ensure its task before it lands")
    if p["name"] in DEPLOYS:
        if not any("retouch.mjs" in " ".join(h.get("run") or []) for h in hooks_of(p)):
            bad(f"phase {p['name']} deploys and has no retouch hook — a re-run after a "
                f"failed convergence would land an empty diff and redeploy nothing")
        awaits = (p.get("hooks") or {}).get("await") or []
        watch = [h for h in awaits if (h.get("uses") or "").startswith("orun.run/watch@")]
        if not watch or (watch[0].get("with") or {}).get("sha") != "{{ .phase.hooks.land.outputs.mergeSha }}":
            bad(f"phase {p['name']} deploys and does not watch the convergence of the "
                f"commit it merged (orun.run/watch@v1 with sha: mergeSha)")

# ── every phase's task is one the run-level list opens, in the same order ─
def task_names(hooks):
    return [(h.get("with") or {}).get("name") for h in hooks
            if (h.get("uses") or "").startswith("orun.task/ensure@")
            and (h.get("with") or {}).get("kind") == "task"]
opened = task_names(run_hooks)
per_phase = [n for p in phases for n in task_names(hooks_of(p))]
if opened != per_phase:
    bad(f"the run-level list opens tasks {opened}; the phases ensure {per_phase} — "
        f"a task is found by its title, so the two must be the same words")
milestones = [(h.get("with") or {}).get("name") for h in run_hooks
              if (h.get("with") or {}).get("kind") == "milestone"]
if milestones != names:
    bad(f"the run-level list opens milestones {milestones}; the phases are {names}")
for h in run_hooks + [x for p in phases for x in hooks_of(p)]:
    if (h.get("with") or {}).get("prefix") not in (None, "BASE"):
        bad(f"hook {h.get('id')} files its task under prefix {h['with']['prefix']}, not BASE")

# ── every contract a hook names exists, beside the blueprint ──────────────
for h in run_hooks + [x for p in phases for x in hooks_of(p)]:
    rel = (h.get("with") or {}).get("contract")
    if rel and not (root / rel).exists():
        bad(f"hook {h.get('id')} names contract {rel}, which does not exist")
    if rel and not rel.startswith(".baseline/tasks/"):
        bad(f"hook {h.get('id')} names contract {rel} outside .baseline/tasks/ — "
            f"`tasks/` is this repository's own work tree, where an unkeyed "
            f"contract is an error")
for p in phases:
    for h in hooks_of(p):
        argv = " ".join(h.get("run") or [])
        for ref in re.findall(r"\{\{ \.baseline\.dir \}\}/(\S+?)(?:\"|'|\s|$)", argv + " "):
            if not (root / ref).exists():
                bad(f"phase {p['name']} hook {h.get('id')} runs {ref}, which this "
                    f"repository does not have")

# ── every phase has a documentation page, and every page a phase ──────────
docs_dir = root / "docs" / "phases"
pages = {f.stem for f in docs_dir.glob("*.md")} - {"README"}
for n in names:
    if n not in pages:
        bad(f"phase {n} has no page at docs/phases/{n}.md")
for page in sorted(pages - set(names)):
    bad(f"docs/phases/{page}.md documents a phase repo-blueprint.yaml does not declare")

# ── narration: authored here, printed from state (Cirrus's rules) ─────────
META_AT = {
    "start": {"files", "expectedMinutes"},
    "await": {"files", "expectedMinutes"},
    "failed": {"files", "expectedMinutes"},
    "done": {"files", "expectedMinutes", "elapsed", "next"},
}
STATE_WORDS = {"done", "failed", "complete", "completed", "succeeded", "skipped"}
PHASE_KEYS = {"name", "title"}
input_keys = set((bp.get("inputs") or {}).keys())

ws_input = (bp.get("inputs") or {}).get("orunWorkspace") or {}
if ws_input.get("from") != "workspace":
    bad("inputs.orunWorkspace must declare `from: workspace` — a console build has no other way to say it")

def strip_expressions(line):
    return re.sub(r"\{\{.*?\}\}", "", line, flags=re.S)

def refs(line):
    found = []
    for expr in re.findall(r"\{\{(.*?)\}\}", line, re.S):
        found += re.findall(r"\.([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)", expr)
    return found

def check_line(where, line, slot, hook_ids):
    prose = strip_expressions(line).lower()
    for w in STATE_WORDS:
        if re.search(rf"\b{w}\b", prose):
            bad(f"{where} asserts {w!r} — `state` is the truth and narration is the "
                f"caption. Describe the world, not the run.")
    for ref in refs(line):
        parts = ref.split(".")
        head = parts[0]
        if head == "phase":
            if len(parts) != 2 or parts[1] not in PHASE_KEYS:
                bad(f"{where} names .{ref}; a phase carries {sorted(PHASE_KEYS)}")
        elif head == "inputs":
            if len(parts) != 2 or parts[1] not in input_keys:
                bad(f"{where} names .{ref}, which is not a declared input")
        elif head == "meta":
            allowed = META_AT.get(slot, META_AT["start"])
            if len(parts) != 2 or parts[1] not in allowed:
                bad(f"{where} names .{ref}; the {slot} event carries {sorted(allowed)}")
        elif head == "hooks":
            if len(parts) < 2 or parts[1] not in hook_ids:
                bad(f"{where} names .{ref}; this phase has no such hook")
        else:
            bad(f"{where} names .{ref}; narration may reference phase, inputs, meta and hooks")

for p in phases:
    n = p.get("narrate") or {}
    ids = {h.get("id") for h in hooks_of(p)}
    for slot in ("start", "await", "done", "failed"):
        line = n.get(slot)
        if not line:
            bad(f"phase {p['name']} declares no narrate.{slot}")
            continue
        check_line(f"phase {p['name']} narrate.{slot}", line, slot, ids)
    for h in ((p.get("hooks") or {}).get("await") or []):
        line = h.get("narrate")
        if not line:
            bad(f"phase {p['name']} await hook {h.get('id')} declares no narrate — a "
                f"wait with no words reads as a stalled build")
            continue
        check_line(f"phase {p['name']} hook {h.get('id')} narrate", line, "done", ids)
    for slot in ("pre", "post"):
        for h in ((p.get("hooks") or {}).get(slot) or []):
            if h.get("narrate"):
                check_line(f"phase {p['name']} hook {h.get('id')} narrate", h["narrate"], "start", ids)

# ── what a baseline of this shape never grows back ────────────────────────
if (root / "flows").exists():
    bad("flows/ exists — the bootstrap is the blueprint; every mechanism is a typed orun action")

if problems:
    print("FAIL: the blueprint's phases and the bootstrap disagree:", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)

placed_n = sum(len(p.get("modules") or []) for p in phases)
narrated = sum(len(p.get("narrate") or {}) for p in phases)
narrated += sum(1 for p in phases for h in hooks_of(p) if h.get("narrate"))
print(f"   {len(phases)} phases, {placed_n} modules (all in 01-product), {len(HOOK_ONLY)} hook-only — in execution order")
print(f"   the hook chain in order; 01-product awaits {sorted(published)} on stage and prod")
print(f"   {narrated} authored narration lines, every reference resolving")
PY

echo "phases.test.sh: ok"
