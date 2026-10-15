import { readFileSync } from "node:fs";
import * as path from "node:path";
import { beforeEach, describe, expect, it, vi } from "vitest";

// A deployment starts with no Stripe key: Stripe is a third party no platform
// brokers, and its owner adds the keys (README, "Connect Stripe"). Until then
// nothing may fail on it — utils/stripe/config.ts never builds the client,
// the pricing page shows the plans with checkout off and says why, checkout
// and the customer portal answer with that notice, and the webhook answers
// 503. No network: with no key, nothing reaches Stripe or Supabase.

const STRIPE_KEYS = [
  "STRIPE_SECRET_KEY",
  "STRIPE_SECRET_KEY_LIVE",
  "STRIPE_WEBHOOK_SECRET",
  "STRIPE_PUBLISHABLE_KEY",
  "NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY",
  "NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY_LIVE",
];

const price = {
  id: "price_1",
  product_id: "prod_1",
  active: true,
  currency: "usd",
  interval: "month",
  interval_count: 1,
  trial_period_days: null,
  type: "recurring",
  unit_amount: 1000,
} as const;

describe("Stripe, not connected (utils/stripe/config.ts)", () => {
  beforeEach(() => {
    vi.resetModules();
    for (const key of STRIPE_KEYS) delete process.env[key];
  });

  it("reports itself unconnected and refuses to build a client", async () => {
    const config = await import("@/utils/stripe/config");
    expect(config.isStripeConnected()).toBe(false);
    expect(config.isCheckoutEnabled()).toBe(false);
    expect(() => config.getStripe()).toThrow(/Stripe is not connected/);
  });

  it("treats an empty key — a blank line in .dev.vars — as no key", async () => {
    process.env.STRIPE_SECRET_KEY = "";
    const config = await import("@/utils/stripe/config");
    expect(config.isStripeConnected()).toBe(false);
  });

  it("enables checkout only with both halves, and builds one client per key", async () => {
    process.env.STRIPE_SECRET_KEY = "sk_test_not_a_real_key";
    const config = await import("@/utils/stripe/config");
    expect(config.isStripeConnected()).toBe(true);
    expect(config.isCheckoutEnabled()).toBe(false);
    process.env.STRIPE_PUBLISHABLE_KEY = "pk_test_not_a_real_key";
    expect(config.isCheckoutEnabled()).toBe(true);
    expect(config.stripePublishableKey()).toBe("pk_test_not_a_real_key");
    expect(config.getStripe()).toBe(config.getStripe());
  });

  it("answers the webhook with 503, never a 500 or a 400", async () => {
    const { POST } = await import("@/app/api/webhooks/route");
    const res = await POST(
      new Request("https://app.example.com/api/webhooks", {
        method: "POST",
        body: '{"id":"evt_1"}',
        headers: { "stripe-signature": "t=1,v1=x" },
      }),
    );
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "Stripe is not connected." });
  });

  it("answers checkout with the notice, through the toast redirect", async () => {
    const { checkoutWithStripe } = await import("@/utils/stripe/server");
    const { errorRedirect, sessionId } = await checkoutWithStripe(price, "/");
    expect(sessionId).toBeUndefined();
    expect(errorRedirect).toMatch(/^\/\?error=Stripe%20is%20not%20connected\.&error_description=/);
  });

  it("answers the customer portal with the notice too", async () => {
    const { createStripePortal } = await import("@/utils/stripe/server");
    expect(await createStripePortal("/account")).toMatch(
      /^\/account\?error=Stripe%20is%20not%20connected\.&error_description=/,
    );
  });
});

describe("the sample plans (utils/stripe/sample-plans.ts)", () => {
  // fixtures/stripe-fixtures.json is what `pnpm stripe:fixtures` creates in
  // Stripe; the plans a fresh deployment shows must be the same plans.
  type Fixture = {
    name: string;
    path: string;
    params: { name?: string; description?: string; metadata?: { index: number }; product?: string; currency?: string; unit_amount?: number; recurring?: { interval: string } };
  };
  const fixtures: Fixture[] = JSON.parse(
    readFileSync(path.resolve(__dirname, "../../../apps/web/fixtures/stripe-fixtures.json"), "utf8"),
  ).fixtures;

  it("are the fixture's products and prices", async () => {
    const { SAMPLE_PLANS } = await import("@/utils/stripe/sample-plans");
    const want = fixtures
      .filter((f) => f.path === "/v1/products")
      .map((p) => ({
        name: p.params.name,
        description: p.params.description,
        index: p.params.metadata?.index,
        prices: fixtures
          .filter((f) => f.path === "/v1/prices" && f.params.product === `\${${p.name}:id}`)
          .map((f) => `${f.params.currency} ${f.params.unit_amount}/${f.params.recurring?.interval}`),
      }));
    const got = SAMPLE_PLANS.map((p) => ({
      name: p.name,
      description: p.description,
      index: (p.metadata as { index: number }).index,
      prices: p.prices.map((x) => `${x.currency} ${x.unit_amount}/${x.interval}`),
    }));
    expect(got).toEqual(want);
  });

  it("can never be bought: no id is Stripe's", async () => {
    const { SAMPLE_PLANS } = await import("@/utils/stripe/sample-plans");
    for (const plan of SAMPLE_PLANS) {
      expect(plan.id).toMatch(/^sample_prod_/);
      for (const p of plan.prices) expect(p.id).toMatch(/^sample_price_/);
    }
  });
});
