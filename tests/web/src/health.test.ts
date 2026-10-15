import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// app/api/health/route.ts: what the deploy's smoke and the bootstrap's probe
// read. It answers 200 only when the Worker reaches its Supabase project with
// the URL and anon key it was built with, the schema is migrated, and the
// service-role key it was handed is the project's own. supabase-js is mocked;
// no network.

type Result = { error: { message: string; code?: string } | null; status: number };
let products: Result;
let listUsers: { error: { message: string } | null };
const created: string[] = [];

vi.mock("@supabase/supabase-js", () => ({
  createClient: (_url: string, key: string) => {
    created.push(key);
    return {
      from: () => ({ select: () => ({ limit: async () => products }) }),
      auth: { admin: { listUsers: async () => listUsers } },
    };
  },
}));

describe("GET /api/health (app/api/health/route.ts)", () => {
  const env = { ...process.env };
  beforeEach(() => {
    vi.resetModules();
    created.length = 0;
    products = { error: null, status: 200 };
    listUsers = { error: null };
    process.env.NEXT_PUBLIC_SUPABASE_URL = "https://ref.supabase.co";
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = "anon";
    process.env.SUPABASE_SERVICE_ROLE_KEY = "service";
    vi.spyOn(console, "error").mockImplementation(() => {});
  });
  afterEach(() => {
    process.env = { ...env };
    vi.restoreAllMocks();
  });

  const get = async () => {
    const { GET } = await import("@/app/api/health/route");
    const res = await GET();
    return { status: res.status, body: await res.json(), cache: res.headers.get("cache-control") };
  };

  it("answers 200 when the project answers, the schema is there and the service role is valid", async () => {
    expect(await get()).toEqual({
      status: 200,
      body: { ok: true, supabase: "reachable", schema: "migrated", serviceRole: "valid" },
      cache: "no-store",
    });
    // The schema through the anon key, the admin API through the service role.
    expect(created).toEqual(["anon", "service"]);
  });

  it("answers 503 before db-migrate has run", async () => {
    products = { error: { message: "Could not find the table 'public.products'", code: "PGRST205" }, status: 404 };
    const { status, body } = await get();
    expect(status).toBe(503);
    expect(body).toMatchObject({ ok: false, supabase: "reachable", schema: "missing" });
  });

  it("answers 503 when the project does not answer", async () => {
    products = { error: { message: "TypeError: fetch failed" }, status: 0 };
    expect((await get()).body).toEqual({ ok: false, supabase: "unreachable" });
  });

  it("answers 503 when the Worker has no service-role secret, or the wrong one", async () => {
    delete process.env.SUPABASE_SERVICE_ROLE_KEY;
    expect((await get()).body).toMatchObject({ ok: false, serviceRole: "missing" });
    vi.resetModules();
    process.env.SUPABASE_SERVICE_ROLE_KEY = "anon";
    listUsers = { error: { message: "User not allowed" } };
    expect((await get()).body).toMatchObject({ ok: false, serviceRole: "invalid" });
  });

  it("answers 503 on a build that was never given a project", async () => {
    delete process.env.NEXT_PUBLIC_SUPABASE_URL;
    const { status, body } = await get();
    expect(status).toBe(503);
    expect(body).toEqual({ ok: false, supabase: "unconfigured" });
  });
});
