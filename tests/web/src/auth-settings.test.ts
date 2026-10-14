import { describe, expect, it } from "vitest";
import {
  getAuthTypes,
  getDefaultSignInView,
  getRedirectMethod,
  getViewTypes,
} from "@/utils/auth-helpers/settings";

// utils/auth-helpers/settings.ts: the toggles that decide which sign-in
// views exist and which one `/signin` lands on. The template ships with
// OAuth, magic-link and password sign-in all on and client-side redirects.

describe("the auth settings (utils/auth-helpers/settings.ts)", () => {
  it("allows OAuth, email and password sign-in as shipped", () => {
    expect(getAuthTypes()).toEqual({ allowOauth: true, allowEmail: true, allowPassword: true });
  });

  it("lists every view the signin/[id] page can render", () => {
    expect(getViewTypes()).toEqual([
      "email_signin",
      "password_signin",
      "forgot_password",
      "update_password",
      "signup",
    ]);
  });

  it("defaults to password sign-in and honours a remembered valid view", () => {
    expect(getDefaultSignInView(null)).toBe("password_signin");
    expect(getDefaultSignInView("email_signin")).toBe("email_signin");
    expect(getDefaultSignInView("not-a-view")).toBe("password_signin");
  });

  it("redirects on the client", () => {
    expect(getRedirectMethod()).toBe("client");
  });
});
