import { describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";

// apps/web's wrangler.jsonc is COMMITTED: the composition checks that it
// exists before the build, in a fresh checkout, so it cannot be a file a build
// generates. It is the render of wrangler.template.jsonc from
// wiring.fixture.json, and the stage and prod deploy lanes re-render it from
// their live wiring document (apps/web/component.yaml's buildCommand) — the
// PUBLIC half of WIRING_SUPABASE. The secret half, the service-role key,
// reaches the Worker as a Worker secret (tooling/wire/secrets.mjs) and never a
// wrangler file. These hold all of that.
const app = path.resolve(__dirname, "../../../apps/web");
const wire = path.resolve(__dirname, "../../../tooling/wire");
const fixture = JSON.parse(readFileSync(path.join(app, "wiring.fixture.json"), "utf8"));

function inTmp<T>(run: (dir: string) => T): T {
  const dir = mkdtempSync(path.join(tmpdir(), "wire-"));
  try {
    return run(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function renderFixture(env: string): string {
  return inTmp((dir) => {
    const out = path.join(dir, "wrangler.jsonc");
    execFileSync(process.execPath, [
      path.join(wire, "render.mjs"),
      "--template", path.join(app, "wrangler.template.jsonc"),
      "--out", out,
      "--map", path.join(app, "wiring.fixture.json"),
      "--env", env,
    ]);
    return readFileSync(out, "utf8");
  });
}

describe("apps/web wrangler config", () => {
  it("is committed as the fixture render of the template (pnpm run wire:fixture)", () => {
    expect(readFileSync(path.join(app, "wrangler.jsonc"), "utf8")).toBe(renderFixture("stage"));
  });

  it("carries the public half of the wiring document as vars, and never the service-role key", () => {
    const template = readFileSync(path.join(app, "wrangler.template.jsonc"), "utf8");
    expect(template).toContain('"NEXT_PUBLIC_SUPABASE_URL": "@@wiring(supabase/__ENV__:supabase_url)@@"');
    expect(template).toContain('"NEXT_PUBLIC_SUPABASE_ANON_KEY": "@@wiring(supabase/__ENV__:supabase_anon_key)@@"');
    expect(template).toMatch(/"NEXT_PUBLIC_SITE_URL": "https:\/\/[a-z0-9-]+-web-__ENV__\.[a-z0-9-]+\.workers\.dev"/);
    expect(template).not.toContain("supabase_service_role_key");
    expect(template).not.toMatch(/"SUPABASE_SERVICE_ROLE_KEY"\s*:/);
    for (const env of ["stage", "prod"]) {
      expect(renderFixture(env)).not.toContain(fixture[`supabase/${env}`].supabase_service_role_key);
    }
  });

  it("renders a deploy lane its own environment from the live wiring document", () => {
    inTmp((dir) => {
      const out = path.join(dir, "wrangler.jsonc");
      execFileSync(
        process.execPath,
        [
          path.join(wire, "live.mjs"),
          "--template", path.join(app, "wrangler.template.jsonc"),
          "--out", out,
          "--components", "supabase",
          "--env", "prod",
        ],
        {
          env: {
            ...process.env,
            WIRING_SUPABASE_PROD: JSON.stringify({
              supabase_url: "https://abcdefghijklmnop.supabase.co",
              supabase_anon_key: "eyJ.anon.prod",
              supabase_service_role_key: "eyJ.service.prod",
            }),
          },
        },
      );
      const rendered = readFileSync(out, "utf8");
      expect(rendered).toContain('"NEXT_PUBLIC_SUPABASE_URL": "https://abcdefghijklmnop.supabase.co"');
      expect(rendered).toContain('"NEXT_PUBLIC_SUPABASE_ANON_KEY": "eyJ.anon.prod"');
      expect(rendered).toMatch(/"NEXT_PUBLIC_SITE_URL": "https:\/\/[a-z0-9-]+-web-prod\./);
      expect(rendered).not.toContain("eyJ.service.prod");
      expect(rendered).not.toContain("__ENV__");
    });
  });

  it("refuses a deploy render with no wiring document", () => {
    const env = { ...process.env };
    delete env.WIRING_SUPABASE_STAGE;
    expect(() =>
      execFileSync(
        process.execPath,
        [
          path.join(wire, "live.mjs"),
          "--template", path.join(app, "wrangler.template.jsonc"),
          "--out", path.join(tmpdir(), "never-written.jsonc"),
          "--components", "supabase",
          "--env", "stage",
        ],
        { env, stdio: "pipe" },
      ),
    ).toThrow();
  });

  it("is what `next build` inlines: the vars of the render beside next.config.mjs", async () => {
    const { publicBuildEnv } = await import("@/next.config.mjs");
    const env = publicBuildEnv({}, path.join(app, "wrangler.jsonc"));
    expect(env).toEqual({
      NEXT_PUBLIC_SUPABASE_URL: fixture["supabase/stage"].supabase_url,
      NEXT_PUBLIC_SUPABASE_ANON_KEY: fixture["supabase/stage"].supabase_anon_key,
      NEXT_PUBLIC_SITE_URL: expect.stringMatching(/-web-stage\./),
    });
    // A value already in the environment (.env.local) wins.
    expect(publicBuildEnv({ NEXT_PUBLIC_SUPABASE_URL: "http://127.0.0.1:54321" }, path.join(app, "wrangler.jsonc")))
      .toMatchObject({ NEXT_PUBLIC_SUPABASE_URL: "http://127.0.0.1:54321" });
  });
});

describe("the service-role key, as a Worker secret (tooling/wire/secrets.mjs)", () => {
  const secrets = path.join(wire, "secrets.mjs");
  const live = { supabase_url: "https://x.supabase.co", supabase_anon_key: "anon", supabase_service_role_key: "eyJ.service.stage" };
  const argv = (...extra: string[]) => [
    secrets,
    "--component", "supabase",
    "--env", "stage",
    "--secret", "SUPABASE_SERVICE_ROLE_KEY=supabase_service_role_key",
    ...extra,
  ];

  it("pushes it with `wrangler secret bulk`, the value over stdin and never on the command line", () => {
    inTmp((dir) => {
      // A stand-in `pnpm` that records how it was called.
      const bin = path.join(dir, "bin");
      execFileSync("mkdir", ["-p", bin]);
      writeFileSync(
        path.join(bin, "pnpm"),
        `#!/bin/sh\nprintf '%s\\n' "$@" > "${dir}/argv"\ncat > "${dir}/stdin"\n`,
      );
      chmodSync(path.join(bin, "pnpm"), 0o755);
      const out = execFileSync(process.execPath, argv("--worker", "acme-web-stage", "--config", "wrangler.jsonc"), {
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH}`,
          CLOUDFLARE_API_TOKEN: "cf-token",
          WIRING_SUPABASE_STAGE: JSON.stringify(live),
        },
        encoding: "utf8",
      });
      const called = readFileSync(path.join(dir, "argv"), "utf8").trim().split("\n");
      expect(called).toEqual(["exec", "wrangler", "secret", "bulk", "--name", "acme-web-stage", "--config", "wrangler.jsonc"]);
      expect(JSON.parse(readFileSync(path.join(dir, "stdin"), "utf8"))).toEqual({
        SUPABASE_SERVICE_ROLE_KEY: "eyJ.service.stage",
      });
      expect(out).not.toContain("eyJ.service.stage");
      expect(out).toContain("SUPABASE_SERVICE_ROLE_KEY set on acme-web-stage");
    });
  });

  it("pushes nothing from a lane with no Cloudflare credential (a verify lane)", () => {
    const env: NodeJS.ProcessEnv = { ...process.env, WIRING_SUPABASE_STAGE: JSON.stringify(live) };
    delete env.CLOUDFLARE_API_TOKEN;
    const out = execFileSync(process.execPath, argv("--worker", "acme-web-stage"), { env, encoding: "utf8" });
    expect(out).toMatch(/no Cloudflare credential in this job/);
  });

  it("refuses a document without the key: a Worker never ships without it", () => {
    const env: NodeJS.ProcessEnv = { ...process.env, WIRING_SUPABASE_STAGE: JSON.stringify({ supabase_url: "https://x" }) };
    delete env.CLOUDFLARE_API_TOKEN;
    expect(() => execFileSync(process.execPath, argv("--worker", "w"), { env, stdio: "pipe" })).toThrow();
  });

  it("writes .dev.vars for wrangler dev from the same document", () => {
    inTmp((dir) => {
      const file = path.join(dir, ".dev.vars");
      execFileSync(process.execPath, argv("--dev-vars", file, "--map", path.join(app, "wiring.fixture.json")));
      expect(readFileSync(file, "utf8")).toBe(
        `SUPABASE_SERVICE_ROLE_KEY=${JSON.stringify(fixture["supabase/stage"].supabase_service_role_key)}\n`,
      );
    });
  });

  it("is what the deploy lane runs, after the build, for its own Worker", () => {
    const component = readFileSync(path.join(app, "component.yaml"), "utf8");
    const build = /buildCommand: (.*)/.exec(component)![1]!;
    const order = ["tooling/wire/live.mjs", "turbo run build", "tooling/wire/secrets.mjs"].map((s) => build.indexOf(s));
    expect(order.every((i) => i >= 0)).toBe(true);
    expect(order).toEqual([...order].sort((a, b) => a - b));
    expect(build).toContain("--secret SUPABASE_SERVICE_ROLE_KEY=supabase_service_role_key");
    expect(build).toMatch(/--worker "[a-z0-9-]+-web-\$\{ORUN_ENVIRONMENT\}"/);
  });
});
