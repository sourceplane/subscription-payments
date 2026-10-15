#!/usr/bin/env node
// Worker SECRETS from a wiring document (zero-dependency).
//
// render.mjs and live.mjs put a wiring document's PUBLIC values into a
// wrangler config as `vars`. Some values in the same document are secrets —
// the Supabase service-role key — and must reach the Worker as a Worker
// secret: never a var, never a wrangler file, never a bundle. This reads them
// out of WIRING_<COMPONENT>_<ENV> (the JSON document the infra component
// lease-publishes, in the job env) and hands them to `wrangler secret bulk`
// as JSON over stdin, so no value is ever on a command line or in a log.
//
//   node secrets.mjs --component supabase --env stage \
//     --secret SUPABASE_SERVICE_ROLE_KEY=supabase_service_role_key \
//     --worker <worker-name> [--config wrangler.jsonc]
//
// Only a job that can deploy holds a Cloudflare credential (the composition's
// deploy profile binds CLOUDFLARE_API_TOKEN; its verify profiles bind
// nothing), so without one this says so and exits 0: a verify lane renders
// and builds exactly what the deploy lane does, and pushes nothing.
//
//   --dev-vars <file>   write the same secrets as KEY=value lines instead
//                       (wrangler dev reads .dev.vars as the Worker's secrets)
//   --map <file>        read the document from a fixture map
//                       ({"<component>/<env>": {...}}) instead of the env
//
// Fails loudly on a missing document or key: a deploy must never ship a
// Worker without a secret its code reads.
import * as fs from "node:fs";
import { spawnSync } from "node:child_process";

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}
function args(name) {
  const out = [];
  process.argv.forEach((a, i) => {
    if (a === `--${name}` && process.argv[i + 1] !== undefined) out.push(process.argv[i + 1]);
  });
  return out;
}

const component = arg("component");
const env = arg("env");
const worker = arg("worker");
const config = arg("config");
const devVars = arg("dev-vars");
const map = arg("map");
const pairs = args("secret");
if (!component || !env || pairs.length === 0 || (!worker && !devVars)) {
  console.error(
    "usage: secrets.mjs --component <c> --env <e> --secret NAME=key [--secret …] (--worker <name> [--config <file>] | --dev-vars <file>) [--map <file>]",
  );
  process.exit(2);
}

const variable = `WIRING_${component.toUpperCase().replace(/-/g, "_")}_${env.toUpperCase()}`;
let doc;
try {
  doc = map
    ? JSON.parse(fs.readFileSync(map, "utf8"))[`${component}/${env}`]
    : JSON.parse(process.env[variable] ?? "null");
} catch (e) {
  console.error(`secrets: ${map ?? variable} is not a JSON document: ${e.message}`);
  process.exit(1);
}
if (!doc || typeof doc !== "object") {
  console.error(`secrets: no wiring document for ${component}/${env} (${map ? `${map}` : `${variable} is not set`})`);
  process.exit(1);
}

const secrets = {};
const missing = [];
for (const pair of pairs) {
  const [name, key] = pair.split("=");
  if (!name || !key || !/^[A-Z][A-Z0-9_]*$/.test(name)) {
    console.error(`secrets: --secret ${pair} is not NAME=key`);
    process.exit(2);
  }
  const value = doc[key];
  if (typeof value !== "string" || value.length === 0) missing.push(`${name} (${component}/${env}:${key})`);
  else secrets[name] = value;
}
if (missing.length > 0) {
  console.error("secrets: the wiring document lacks:");
  for (const m of missing) console.error(`  ${m}`);
  process.exit(1);
}
const names = Object.keys(secrets).join(", ");

if (devVars) {
  // KEY=value, one per line, double-quoted (dotenv's syntax, which wrangler
  // reads): a JSON string is a valid dotenv double-quoted value.
  const body = Object.entries(secrets)
    .map(([k, v]) => `${k}=${JSON.stringify(v)}`)
    .join("\n");
  fs.writeFileSync(devVars, `${body}\n`, { mode: 0o600 });
  console.log(`secrets: wrote ${names} to ${devVars}`);
  process.exit(0);
}

if (!process.env.CLOUDFLARE_API_TOKEN) {
  console.log(
    `secrets: no Cloudflare credential in this job (a verify lane) — ${names} reach ${worker} from the deploy lane`,
  );
  process.exit(0);
}

const result = spawnSync(
  "pnpm",
  ["exec", "wrangler", "secret", "bulk", "--name", worker, ...(config ? ["--config", config] : [])],
  { input: JSON.stringify(secrets), stdio: ["pipe", "inherit", "inherit"] },
);
if (result.status !== 0) {
  console.error(`secrets: wrangler secret bulk failed for ${worker}`);
  process.exit(result.status ?? 1);
}
console.log(`secrets: ${names} set on ${worker}`);
