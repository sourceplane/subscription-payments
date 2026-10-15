import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PHASE_PRODUCTION_BUILD } from 'next/constants.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// The public values the template reads to reach its Supabase project and to
// build absolute links to itself (Stripe's return URLs, auth email links,
// metadataBase — `getURL()` in utils/helpers.ts). `next build` inlines
// NEXT_PUBLIC_* into the browser bundle and the server's, so the BUILD has to
// know them, not only the Worker.
export const PUBLIC_VARS = [
  'NEXT_PUBLIC_SUPABASE_URL',
  'NEXT_PUBLIC_SUPABASE_ANON_KEY',
  'NEXT_PUBLIC_SITE_URL'
];

// JSONC → JSON: comments out, trailing commas out, strings untouched.
function stripJsonc(text) {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== '"') j += text[j] === '\\' ? 2 : 1;
      out += text.slice(i, j + 1);
      i = j;
    } else if (c === '/' && text[i + 1] === '/') {
      while (i < text.length && text[i] !== '\n') i++;
      out += '\n';
    } else if (c === '/' && text[i + 1] === '*') {
      i = text.indexOf('*/', i + 2);
      if (i < 0) break;
      i++;
    } else {
      out += c;
    }
  }
  return out.replace(/,(\s*[}\]])/g, '$1');
}

/**
 * The values a production build is for: the `vars` of the wrangler.jsonc
 * beside this file. That file is committed as the render of
 * wrangler.template.jsonc from wiring.fixture.json, and the stage and prod
 * deploy lanes re-render it from their environment's wiring document before
 * they build (component.yaml) — so the browser bundle and the Worker talk to
 * the same project, from one place. A value already in the environment
 * (`.env.local`, or exported by hand) wins.
 */
export function publicBuildEnv(
  env = process.env,
  wranglerConfig = path.join(__dirname, 'wrangler.jsonc')
) {
  let vars = {};
  try {
    vars = JSON.parse(stripJsonc(fs.readFileSync(wranglerConfig, 'utf8'))).vars ?? {};
  } catch {
    vars = {};
  }
  const out = {};
  for (const key of PUBLIC_VARS) {
    const value = env[key] || vars[key];
    if (typeof value === 'string' && value.length > 0) out[key] = value;
  }
  return out;
}

/** @type {(phase: string) => import('next').NextConfig} */
export default function nextConfig(phase) {
  return {
    // Required by @opennextjs/cloudflare, which bundles `.next/standalone/**`
    // into the Worker. Trace from the monorepo root so workspace dependencies
    // resolve from the root node_modules.
    output: 'standalone',
    outputFileTracingRoot: path.join(__dirname, '../..'),
    // Only a production build reads the wrangler config: `next dev` keeps the
    // template's own behaviour, `.env.local`.
    env: phase === PHASE_PRODUCTION_BUILD ? publicBuildEnv() : {}
  };
}
