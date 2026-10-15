import { beforeAll, describe, expect, it } from "vitest";
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { manifest } from "@saas/db/manifest";

// Supabase's Data API (PostgREST) serves the `public` schema to anyone holding
// the project's anon key — and this app ships that key to every browser. So
// every table in `public` must have row-level security, and the policies must
// let the app's own flows through and nobody else's: a visitor reads the plans
// and their own user row and subscriptions, never another user's, and never
// the user→Stripe customer map. These run every migration db-migrate applies,
// in the manifest's order, on a real Postgres in process (PGlite: Postgres
// compiled to WASM), over the slice of Supabase's `auth` schema the migrations
// touch, and read the catalog — and the rows — they leave.
const migrationsDir = path.resolve(__dirname, "../../../packages/db/src/migrations");
const sqlOf = (rel: string) => readFileSync(path.join(migrationsDir, rel), "utf8");

// What a Supabase project has before the first migration: Auth's `users`
// table (010 references it and triggers on it), `auth.uid()` read from the
// request's JWT claims as PostgREST sets them, and the Data API's roles with
// the grants Supabase gives them on `public` — so a refusal below is
// row-level security's, not a missing grant's. `service_role` bypasses RLS,
// as it does on Supabase.
const SUPABASE = `
  create schema auth;
  create table auth.users (id uuid primary key, email text, raw_user_meta_data jsonb);
  create function auth.uid() returns uuid language sql stable as $$
    select (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
  $$;
  create role anon nologin;
  create role authenticated nologin;
  create role service_role nologin bypassrls;
  grant usage on schema public, auth to anon, authenticated, service_role;
  alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
`;

async function migrated(upTo?: string): Promise<PGlite> {
  const db = new PGlite();
  await db.exec(SUPABASE);
  for (const entry of manifest.migrations) {
    if (upTo && entry.id >= upTo) break;
    await db.exec(sqlOf(entry.path));
  }
  return db;
}

type Rel = { relname: string; relrowsecurity: boolean; relforcerowsecurity: boolean };
const PUBLIC_TABLES = `
  select c.relname, c.relrowsecurity, c.relforcerowsecurity
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p')
   order by c.relname`;

const ALICE = "00000000-0000-4000-8000-00000000a11c";
const BOB = "00000000-0000-4000-8000-000000000b0b";

async function as<T>(db: PGlite, role: string, sub: string | null, run: () => Promise<T>): Promise<T> {
  await db.exec(`set role ${role}`);
  await db.query("select set_config('request.jwt.claims', $1, false)", [
    sub ? JSON.stringify({ sub, role }) : "",
  ]);
  try {
    return await run();
  } finally {
    await db.exec("reset role");
    await db.query("select set_config('request.jwt.claims', '', false)");
  }
}
const count = async (db: PGlite, table: string) =>
  (await db.query<{ n: number }>(`select count(*)::int as n from ${table}`)).rows[0]!.n;

describe("row-level security on public (after every migration)", () => {
  let db: PGlite;
  beforeAll(async () => {
    db = await migrated();
    // Two users sign up (the 010 trigger copies each into public.users), the
    // webhook syncs a plan, and Alice subscribes — written as the tables'
    // owner, as the migrations and the service role would.
    await db.exec(`
      insert into auth.users (id, email, raw_user_meta_data) values
        ('${ALICE}', 'alice@example.invalid', '{"full_name":"Alice"}'),
        ('${BOB}', 'bob@example.invalid', '{"full_name":"Bob"}');
      insert into products (id, active, name, metadata) values ('prod_1', true, 'Hobby', '{"index":0}');
      insert into prices (id, product_id, active, currency, type, unit_amount, interval, interval_count)
        values ('price_1', 'prod_1', true, 'usd', 'recurring', 1000, 'month', 1);
      insert into customers (id, stripe_customer_id) values ('${ALICE}', 'cus_alice'), ('${BOB}', 'cus_bob');
      insert into subscriptions (id, user_id, status, price_id) values
        ('sub_alice', '${ALICE}', 'active', 'price_1'), ('sub_bob', '${BOB}', 'active', 'price_1');`);
  }, 60_000);

  it("leaves no table in public without row-level security", async () => {
    const { rows } = await db.query<Rel>(PUBLIC_TABLES);
    // Not vacuous: the template's five tables are all there.
    expect(rows.map((r) => r.relname)).toEqual(["customers", "prices", "products", "subscriptions", "users"]);
    expect(rows.filter((r) => !r.relrowsecurity).map((r) => r.relname)).toEqual([]);
    expect(rows.filter((r) => r.relforcerowsecurity).map((r) => r.relname)).toEqual([]);
  });

  it("keeps upstream's policies — and none on the customer map", async () => {
    const { rows } = await db.query<{ tablename: string; cmd: string }>(
      "select tablename, cmd from pg_policies where schemaname = 'public' order by tablename, cmd",
    );
    expect(rows.map((r) => `${r.tablename}:${r.cmd}`)).toEqual([
      "prices:SELECT",
      "products:SELECT",
      "subscriptions:SELECT",
      "users:SELECT",
      "users:UPDATE",
    ]);
  });

  it("gives the anon key the plans and nothing else", async () => {
    await as(db, "anon", null, async () => {
      expect(await count(db, "products")).toBe(1);
      expect(await count(db, "prices")).toBe(1);
      expect(await count(db, "users")).toBe(0);
      expect(await count(db, "customers")).toBe(0);
      expect(await count(db, "subscriptions")).toBe(0);
      await expect(db.exec("insert into products (id, name) values ('prod_x', 'Free')")).rejects.toThrow(
        /row-level security/,
      );
      await expect(db.exec("insert into customers (id, stripe_customer_id) values (gen_random_uuid(), 'cus_x')")).rejects.toThrow(
        /row-level security/,
      );
    });
  });

  it("gives a signed-in user their own row and subscriptions, never another's or the customer map", async () => {
    await as(db, "authenticated", ALICE, async () => {
      const users = await db.query<{ id: string; full_name: string }>("select id, full_name from users");
      expect(users.rows).toEqual([{ id: ALICE, full_name: "Alice" }]);
      const subs = await db.query<{ id: string }>("select id from subscriptions");
      expect(subs.rows).toEqual([{ id: "sub_alice" }]);
      expect(await count(db, "customers")).toBe(0);
      // Their own row is theirs to update (the account page's name, upstream's
      // policy); Bob's is invisible, so the update touches nothing.
      await db.exec("update users set full_name = 'Alice A.' where id = '" + ALICE + "'");
      await db.exec("update users set full_name = 'Mallory' where id = '" + BOB + "'");
    });
    const names = await db.query<{ full_name: string }>("select full_name from users order by full_name");
    expect(names.rows.map((r) => r.full_name)).toEqual(["Alice A.", "Bob"]);
  });

  it("lets the service role — the webhook's sync, the customer mapping — see everything", async () => {
    await as(db, "service_role", null, async () => {
      expect(await count(db, "customers")).toBe(2);
      expect(await count(db, "subscriptions")).toBe(2);
      await db.exec("insert into products (id, active, name) values ('prod_2', true, 'Freelancer')");
    });
    expect(await count(db, "products")).toBe(2);
  });
});

describe("migration 020's check", () => {
  it("refuses a table in public without row-level security, naming it", async () => {
    const db = await migrated("020");
    await db.exec("create table public.notes (id serial primary key, body text)");
    await expect(db.exec(sqlOf("020_row_level_security/up.sql"))).rejects.toThrow(
      /without row-level security.*notes/,
    );
  }, 60_000);

  it("passes on upstream's schema, and again on a second run", async () => {
    const db = await migrated("020");
    await db.exec(sqlOf("020_row_level_security/up.sql"));
    await db.exec(sqlOf("020_row_level_security/up.sql"));
    const { rows } = await db.query<Rel>(PUBLIC_TABLES);
    expect(rows.every((r) => r.relrowsecurity)).toBe(true);
  }, 60_000);
});
