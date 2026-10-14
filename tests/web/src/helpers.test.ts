import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  calculateTrialEndUnixTimestamp,
  getErrorRedirect,
  getStatusRedirect,
  getURL,
  toDateTime,
} from "@/utils/helpers";

// utils/helpers.ts is the template's pure logic: where the site lives
// (Stripe success/cancel URLs, auth email redirects), how trials are
// computed, and how a server action tells the Toaster what to say.

describe("getURL (utils/helpers.ts)", () => {
  const env = { ...process.env };
  afterEach(() => {
    process.env = { ...env };
  });

  it("prefers NEXT_PUBLIC_SITE_URL, trims the trailing slash and joins the path", () => {
    process.env.NEXT_PUBLIC_SITE_URL = "https://subscription-payments-web-stage.acme.workers.dev/";
    delete process.env.NEXT_PUBLIC_VERCEL_URL;
    expect(getURL()).toBe("https://subscription-payments-web-stage.acme.workers.dev");
    expect(getURL("/account")).toBe("https://subscription-payments-web-stage.acme.workers.dev/account");
    expect(getURL("auth/callback")).toBe("https://subscription-payments-web-stage.acme.workers.dev/auth/callback");
  });

  it("falls back to NEXT_PUBLIC_VERCEL_URL and adds https when the scheme is missing", () => {
    process.env.NEXT_PUBLIC_SITE_URL = "";
    process.env.NEXT_PUBLIC_VERCEL_URL = "my-app.vercel.app";
    expect(getURL("/")).toBe("https://my-app.vercel.app");
  });

  it("defaults to localhost when neither is set", () => {
    delete process.env.NEXT_PUBLIC_SITE_URL;
    delete process.env.NEXT_PUBLIC_VERCEL_URL;
    expect(getURL()).toBe("http://localhost:3000");
    expect(getURL("/account")).toBe("http://localhost:3000/account");
  });
});

describe("calculateTrialEndUnixTimestamp (utils/helpers.ts)", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-15T00:00:00Z"));
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("returns undefined for no trial or a trial shorter than two days", () => {
    expect(calculateTrialEndUnixTimestamp(null)).toBeUndefined();
    expect(calculateTrialEndUnixTimestamp(undefined)).toBeUndefined();
    expect(calculateTrialEndUnixTimestamp(0)).toBeUndefined();
    expect(calculateTrialEndUnixTimestamp(1)).toBeUndefined();
  });

  it("ends the trial (days + 1) from now, in unix seconds", () => {
    const now = Math.floor(Date.now() / 1000);
    expect(calculateTrialEndUnixTimestamp(7)).toBe(now + 8 * 24 * 60 * 60);
  });
});

describe("toDateTime (utils/helpers.ts)", () => {
  it("turns Stripe's unix seconds into a Date", () => {
    expect(toDateTime(1_700_000_000).toISOString()).toBe("2023-11-14T22:13:20.000Z");
  });
});

describe("the toast redirects (utils/helpers.ts)", () => {
  it("getStatusRedirect encodes the status and its description", () => {
    expect(getStatusRedirect("/account", "Success!", "Your name has been updated.")).toBe(
      "/account?status=Success!&status_description=Your%20name%20has%20been%20updated.",
    );
  });

  it("getErrorRedirect encodes the error and can disable the button and carry extra params", () => {
    expect(getErrorRedirect("/signin/signup", "Sign up failed.", "Passwords do not match.", true, "foo=bar")).toBe(
      "/signin/signup?error=Sign%20up%20failed.&error_description=Passwords%20do%20not%20match.&disable_button=true&foo=bar",
    );
  });

  it("omits the description when there is none", () => {
    expect(getErrorRedirect("/", "Hmm... Something went wrong.")).toBe(
      "/?error=Hmm...%20Something%20went%20wrong.",
    );
  });
});
