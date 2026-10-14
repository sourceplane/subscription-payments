import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// app/api/webhooks/route.ts: the Stripe webhook. Every path that answers 400
// is decided before any network call — a missing signature or secret, a
// signature that does not verify, an event type the handler does not sync.
// Stripe's client and the Supabase admin client are mocked; no network.

const constructEventAsync = vi.fn();
vi.mock("@/utils/stripe/config", () => ({
  stripe: { webhooks: { constructEventAsync } },
}));

const upsertProductRecord = vi.fn();
vi.mock("@/utils/supabase/admin", () => ({
  upsertProductRecord,
  upsertPriceRecord: vi.fn(),
  manageSubscriptionStatusChange: vi.fn(),
  deleteProductRecord: vi.fn(),
  deletePriceRecord: vi.fn(),
}));

function post(body: string, headers: Record<string, string> = {}) {
  return new Request("https://app.example.com/api/webhooks", { method: "POST", body, headers });
}

describe("POST /api/webhooks (app/api/webhooks/route.ts)", () => {
  const env = { ...process.env };
  beforeEach(() => {
    vi.resetModules();
    constructEventAsync.mockReset();
    upsertProductRecord.mockReset();
    vi.spyOn(console, "log").mockImplementation(() => {});
  });
  afterEach(() => {
    process.env = { ...env };
    vi.restoreAllMocks();
  });

  it("answers 400 'Webhook secret not found.' without a stripe-signature header", async () => {
    process.env.STRIPE_WEBHOOK_SECRET = "whsec_test";
    const { POST } = await import("@/app/api/webhooks/route");
    const res = await POST(post("{}"));
    expect(res.status).toBe(400);
    expect(await res.text()).toBe("Webhook secret not found.");
    expect(constructEventAsync).not.toHaveBeenCalled();
  });

  it("answers 400 'Webhook secret not found.' when STRIPE_WEBHOOK_SECRET is unset", async () => {
    delete process.env.STRIPE_WEBHOOK_SECRET;
    const { POST } = await import("@/app/api/webhooks/route");
    const res = await POST(post("{}", { "stripe-signature": "t=1,v1=abc" }));
    expect(res.status).toBe(400);
    expect(await res.text()).toBe("Webhook secret not found.");
  });

  it("answers 400 'Webhook Error: …' when the signature does not verify", async () => {
    process.env.STRIPE_WEBHOOK_SECRET = "whsec_test";
    constructEventAsync.mockRejectedValue(new Error("No signatures found matching the expected signature for payload."));
    const { POST } = await import("@/app/api/webhooks/route");
    const res = await POST(post("{}", { "stripe-signature": "t=1,v1=bad" }));
    expect(res.status).toBe(400);
    expect(await res.text()).toBe(
      "Webhook Error: No signatures found matching the expected signature for payload.",
    );
    // Verification is asynchronous on Workers (SubtleCrypto), with the secret the handler read.
    expect(constructEventAsync).toHaveBeenCalledWith("{}", "t=1,v1=bad", "whsec_test", undefined, expect.anything());
  });

  it("answers 400 'Unsupported event type' for an event it does not sync", async () => {
    process.env.STRIPE_WEBHOOK_SECRET = "whsec_test";
    constructEventAsync.mockResolvedValue({ type: "invoice.paid", data: { object: {} } });
    const { POST } = await import("@/app/api/webhooks/route");
    const res = await POST(post("{}", { "stripe-signature": "t=1,v1=ok" }));
    expect(res.status).toBe(400);
    expect(await res.text()).toBe("Unsupported event type: invoice.paid");
  });

  it("syncs a product.created event and acknowledges it", async () => {
    process.env.STRIPE_WEBHOOK_SECRET = "whsec_test";
    const product = { id: "prod_123", active: true, name: "Hobby" };
    constructEventAsync.mockResolvedValue({ type: "product.created", data: { object: product } });
    const { POST } = await import("@/app/api/webhooks/route");
    const res = await POST(post("{}", { "stripe-signature": "t=1,v1=ok" }));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ received: true });
    expect(upsertProductRecord).toHaveBeenCalledWith(product);
  });

  it("answers 400 when a handler throws", async () => {
    process.env.STRIPE_WEBHOOK_SECRET = "whsec_test";
    constructEventAsync.mockResolvedValue({ type: "product.created", data: { object: { id: "prod_123" } } });
    upsertProductRecord.mockRejectedValue(new Error("Product insert/update failed: boom"));
    const { POST } = await import("@/app/api/webhooks/route");
    const res = await POST(post("{}", { "stripe-signature": "t=1,v1=ok" }));
    expect(res.status).toBe(400);
    expect(await res.text()).toBe("Webhook handler failed. View your Next.js function logs.");
  });
});
