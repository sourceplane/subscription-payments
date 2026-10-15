#!/usr/bin/env bash
# THE REBRAND WRITES EACH VALUE ONCE, AND WHAT IT WROTE STAYS WRITTEN.
#
# Drives the real tooling/rebrand/rebrand.mjs over one-file trees and compares
# the file. Each case is a shape this baseline's identity actually takes in the
# tree — the name seam, the worker name, the Worker's own origin, the
# placeholder domain, a secret ref, the `repo` the Supabase project is named
# after — and each runs through as many passes as a bootstrap might make, so a
# value written once must survive every later pass unchanged. Two things must
# NOT be renamed although they spell the slug: the upstream template's own
# identity (its repository is `nextjs-<this baseline's slug>`, its demo site
# `<slug>.vercel.app`), and a migration (its checksum is in the manifest and
# in every database it was applied to).
#
# The identity is PINNED (fixtures/baseline-identity.subscription-payments.json) rather
# than read from .baseline/identity.json: what this tests is the engine, and
# its fixtures spell the identity out literally.
#
# Needs: node, git. No network.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
rebrand="$here/../tooling/rebrand/rebrand.mjs"
identity="$here/fixtures/baseline-identity.subscription-payments.json"

fail=0
# check NAME VALUES-JSON FILE CONTENT WANT [PASSES]
check() {
  local name="$1" values="$2" file="$3" content="$4" want="$5" passes="${6:-1}"
  local tmp got out i
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  mkdir -p "$tmp/$(dirname "$file")" "$tmp/.rebrand"
  printf '%s\n' "$content" > "$tmp/$file"
  printf '%s\n' "$values" > "$tmp/.rebrand/values.json"
  for ((i = 1; i <= passes; i++)); do
    git -C "$tmp" add -A
    if ! out="$(cd "$tmp" && node "$rebrand" --baseline-identity "$identity" --values .rebrand/values.json --allow-dirty 2>&1)"; then
      echo "   ✕  $name: rebrand pass $i failed:" >&2
      printf '%s\n' "$out" | sed 's/^/        /' >&2
      fail=1
      rm -rf "$tmp"
      return
    fi
  done
  got="$(cat "$tmp/$file")"
  rm -rf "$tmp"
  if [ "$got" = "$want" ]; then
    echo "   ok  $name"
  else
    echo "   ✕  $name:" >&2
    echo "        got:  $got" >&2
    echo "        want: $want" >&2
    fail=1
  fi
}

acme='{"reponame":"acme-pay","productname":"Acme Cloud","productdomain":"acme.dev","githuborg":"acme-inc","subdomain":"acme","orunWorkspace":"ws_79BDXAZQ"}'

echo "── rebrand: the product's own identity"
check "the name seam takes the product's name" \
  "$acme" apps/web/utils/site.ts 'export const SITE_NAME = "ACME"' \
  'export const SITE_NAME = "Acme Cloud"'
check "…and stays a valid string for a name with an apostrophe and an ampersand" \
  '{"reponame":"sams-seats","productname":"Sam'"'"'s Seats & Billing","productdomain":"sam.dev"}' \
  apps/web/utils/site.ts 'export const SITE_NAME = "ACME"' \
  'export const SITE_NAME = "Sam'"'"'s Seats & Billing"'
check "the display name elsewhere is content, and is left alone" \
  "$acme" apps/web/app/x.tsx '<p>Welcome to ACME.</p>' \
  '<p>Welcome to ACME.</p>'
check "the worker name is re-prefixed, the environment suffix kept" \
  "$acme" apps/web/component.yaml 'workerName: subscription-payments-web' \
  'workerName: acme-pay-web'
check "the Worker the deploy pushes its secret to, per environment" \
  "$acme" apps/web/component.yaml '--worker "subscription-payments-web-${ORUN_ENVIRONMENT}"' \
  '--worker "acme-pay-web-${ORUN_ENVIRONMENT}"'
check "the Worker's own origin (NEXT_PUBLIC_SITE_URL): worker name and subdomain" \
  "$acme" apps/web/wrangler.template.jsonc \
  '"NEXT_PUBLIC_SITE_URL": "https://subscription-payments-web-__ENV__.your-workers-subdomain.workers.dev"' \
  '"NEXT_PUBLIC_SITE_URL": "https://acme-pay-web-__ENV__.acme.workers.dev"'
check "the placeholder domain is the product's domain, not a renamed slug" \
  "$acme" intent.yaml '      BASE_DOMAIN: subscription-payments.example.com' \
  '      BASE_DOMAIN: acme.dev'
check "the repo slug" \
  "$acme" package.json '  "name": "subscription-payments",' \
  '  "name": "acme-pay",'
check "the repo Terraform names the Supabase project after" \
  "$acme" intent.yaml '        repo: subscription-payments' \
  '        repo: acme-pay'
check "…and the Auth Site URL's subdomain beside it" \
  "$acme" infra/terraform/supabase/component.yaml '    workersDevSubdomain: your-workers-subdomain' \
  '    workersDevSubdomain: acme'
check "a secret ref names the product's workspace and project" \
  "$acme" infra/db-migrate/component.yaml \
  '    SUPABASE_ACCESS_TOKEN: "secret://subscription-payments/subscription-payments/{{ .environment }}/SUPABASE_ACCESS_TOKEN"' \
  '    SUPABASE_ACCESS_TOKEN: "secret://ws_79BDXAZQ/acme-pay/{{ .environment }}/SUPABASE_ACCESS_TOKEN"'
check "this repository's source link names the product's owner and repository" \
  "$acme" README.md 'See https://github.com/sourceplane/subscription-payments.' \
  'See https://github.com/acme-inc/acme-pay.'
check "org-owned identity is not renamed" \
  "$acme" intent.yaml 'apiVersion: sourceplane.io/v1 # mail ops@sourceplane.ai' \
  'apiVersion: sourceplane.io/v1 # mail ops@sourceplane.ai'

echo "── rebrand: what spells the slug and is not this baseline's"
check "the upstream template's repository is upstream's" \
  "$acme" apps/web/components/ui/Footer/Footer.tsx 'href="https://github.com/vercel/nextjs-subscription-payments"' \
  'href="https://github.com/vercel/nextjs-subscription-payments"'
check "…and so is its demo site" \
  "$acme" apps/web/README.md '- https://subscription-payments.vercel.app/' \
  '- https://subscription-payments.vercel.app/'
check "…and its Supabase CLI project id" \
  "$acme" apps/web/supabase/config.toml 'project_id = "nextjs-subscription-payments"' \
  'project_id = "nextjs-subscription-payments"'
check "…and its URL-encoded form in the Deploy button" \
  "$acme" apps/web/README.md 'repository-url=https%3A%2F%2Fgithub.com%2Fvercel%2Fnextjs-subscription-payments&project-name=nextjs-subscription-payments' \
  'repository-url=https%3A%2F%2Fgithub.com%2Fvercel%2Fnextjs-subscription-payments&project-name=nextjs-subscription-payments'
check "a migration is never rewritten (its checksum is in the manifest)" \
  "$acme" packages/db/src/migrations/030_x/up.sql '-- subscription-payments: a comment the checksum covers' \
  '-- subscription-payments: a comment the checksum covers'
check "nor is the Supabase CLI's copy" \
  "$acme" apps/web/supabase/migrations/20230530034630_init.sql '-- subscription-payments: a comment' \
  '-- subscription-payments: a comment'

echo "── rebrand: a written value is not rewritten, in any later pass"
contains='{"reponame":"subscription-payments-2","productname":"ACME 2","productdomain":"subscription-payments.example.com.au","githuborg":"sourceplane","subdomain":"your-workers-subdomain-2"}'
check "a repo slug containing the baseline's slug survives three passes" \
  "$contains" package.json '  "name": "subscription-payments",' \
  '  "name": "subscription-payments-2",' 3
check "a worker name built on it survives three passes" \
  "$contains" apps/web/component.yaml 'workerName: subscription-payments-web' \
  'workerName: subscription-payments-2-web' 3
check "a domain containing the baseline's domain survives three passes" \
  "$contains" intent.yaml 'BASE_DOMAIN: subscription-payments.example.com' \
  'BASE_DOMAIN: subscription-payments.example.com.au' 3
check "a subdomain containing the placeholder survives three passes" \
  "$contains" apps/web/component.yaml 'workersDevSubdomain: your-workers-subdomain' \
  'workersDevSubdomain: your-workers-subdomain-2' 3
check "a name containing the baseline's name survives three passes" \
  "$contains" apps/web/utils/site.ts 'export const SITE_NAME = "ACME"' \
  'export const SITE_NAME = "ACME 2"' 3

# --verify runs after every rebrand. Without the product's values it cannot
# tell the product's own identity from a leftover; with them it can. A real
# leftover must fail it either way.
verify() { # NAME VALUES FILE CONTENT WANT(pass|fail) [--values]
  local name="$1" values="$2" file="$3" content="$4" want="$5" withvalues="${6:-}" tmp got
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  mkdir -p "$tmp/$(dirname "$file")" "$tmp/.rebrand"
  printf '%s\n' "$content" > "$tmp/$file"
  printf '%s\n' "$values" > "$tmp/.rebrand/values.json"
  git -C "$tmp" add -A
  if (cd "$tmp" && node "$rebrand" --baseline-identity "$identity" --verify ${withvalues:+--values .rebrand/values.json} >/dev/null 2>&1); then got=pass; else got=fail; fi
  rm -rf "$tmp"
  if [ "$got" = "$want" ]; then echo "   ok  $name"; else echo "   ✕  $name: --verify ${got}ed, want $want" >&2; fail=1; fi
}
echo "── rebrand --verify: the product's own identity is not residue"
verify "given the values, a slug containing the baseline's passes" \
  "$contains" package.json '"name": "subscription-payments-2"' pass --values
verify "without them it cannot know, and fails" \
  "$contains" package.json '"name": "subscription-payments-2"' fail
verify "given the values, a real leftover still fails" \
  "$acme" package.json '"name": "subscription-payments"' fail --values
verify "a leftover worker name fails" \
  "$acme" apps/web/component.yaml 'workerName: subscription-payments-web' fail --values
verify "a leftover code identifier fails (no rule renames it — so nothing may spell it)" \
  "$acme" apps/web/app/x.ts 'export class SubscriptionPayments {}' fail --values
verify "the upstream template's links are not residue" \
  "$acme" apps/web/utils/stripe/config.ts "url: 'https://github.com/vercel/nextjs-subscription-payments'" pass --values
verify "a clean product passes" \
  "$acme" package.json '"name": "acme-pay"' pass --values

echo "── rebrand: a residue it cannot rename fails the rebrand itself"
tmp="$(mktemp -d)"; git -C "$tmp" init -q; mkdir -p "$tmp/.rebrand" "$tmp/apps/web"
printf '%s\n' "$acme" > "$tmp/.rebrand/values.json"
printf 'const x = "SUBSCRIPTION_PAYMENTS_TOKEN"\n' > "$tmp/apps/web/x.ts"
git -C "$tmp" add -A
if (cd "$tmp" && node "$rebrand" --baseline-identity "$identity" --values .rebrand/values.json --allow-dirty >/dev/null 2>&1); then
  echo "   ✕  an unrenamable env-var prefix passed the rebrand" >&2; fail=1
else
  echo "   ok  an unrenamable env-var prefix fails the rebrand, naming the file"
fi
rm -rf "$tmp"

[ "$fail" -eq 0 ] || exit 1
echo "rebrand.test.sh: ok"
