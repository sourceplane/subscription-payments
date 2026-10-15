import Stripe from 'stripe';

// Stripe is the one third party this app talks to, and nothing provisions it:
// a deployment has no Stripe key until its owner adds one (README, "Connect
// Stripe"). Until then the client is never built — the pricing page shows the
// plans with checkout off and a notice saying why, the checkout and portal
// actions answer with that notice, and the webhook answers 503 — while
// sign-up, sign-in and the account page work exactly as they do with Stripe
// connected. Upstream built the client at module load with an empty-string
// fallback; the keys are read per call because on Workers the environment is
// the request's.

export const STRIPE_NOT_CONNECTED = 'Stripe is not connected.';

// The template's names, read the way upstream reads them (`_LIVE` first for
// the secret key). An empty value — a blank line in .dev.vars — is no key.
export function stripeSecretKey(): string | undefined {
  return (
    process.env.STRIPE_SECRET_KEY_LIVE || process.env.STRIPE_SECRET_KEY || undefined
  );
}

export function stripeWebhookSecret(): string | undefined {
  return process.env.STRIPE_WEBHOOK_SECRET || undefined;
}

// The publishable key Stripe.js needs in the browser. Read on the server, per
// request, and handed to the pricing page, so an owner connects Stripe with
// Worker secrets alone and no rebuild (STRIPE_PUBLISHABLE_KEY). `next dev`
// keeps upstream's build-time NEXT_PUBLIC_* names.
export function stripePublishableKey(): string | undefined {
  return (
    process.env.STRIPE_PUBLISHABLE_KEY ||
    process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY_LIVE ||
    process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY ||
    undefined
  );
}

export function isStripeConnected(): boolean {
  return Boolean(stripeSecretKey());
}

// Checkout needs both halves: the secret key creates the session on the
// server, the publishable key redirects the browser to it.
export function isCheckoutEnabled(): boolean {
  return Boolean(stripeSecretKey() && stripePublishableKey());
}

let client: { key: string; stripe: Stripe } | undefined;

export function getStripe(): Stripe {
  const key = stripeSecretKey();
  if (!key) {
    throw new Error(`${STRIPE_NOT_CONNECTED} STRIPE_SECRET_KEY is not set.`);
  }
  if (client?.key !== key) {
    client = {
      key,
      stripe: new Stripe(key, {
        // https://github.com/stripe/stripe-node#configuration
        // https://stripe.com/docs/api/versioning
        // @ts-ignore
        apiVersion: null,
        // Register this as an official Stripe plugin.
        // https://stripe.com/docs/building-plugins#setappinfo
        appInfo: {
          name: 'Next.js Subscription Starter',
          version: '0.0.0',
          url: 'https://github.com/vercel/nextjs-subscription-payments'
        },
        // Cloudflare Workers: talk to Stripe over the platform's fetch rather
        // than Node's http client.
        httpClient: Stripe.createFetchHttpClient()
      })
    };
  }
  return client.stripe;
}
