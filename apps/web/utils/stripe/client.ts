import { loadStripe, Stripe } from '@stripe/stripe-js';

let stripePromise: Promise<Stripe | null>;

// The publishable key comes from the server (utils/stripe/config.ts reads it
// per request), so connecting Stripe needs no rebuild; upstream's build-time
// NEXT_PUBLIC_* names remain the fallback for `next dev`.
export const getStripe = (publishableKey?: string) => {
  if (!stripePromise) {
    stripePromise = loadStripe(
      publishableKey ||
        process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY_LIVE ||
        process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY ||
        ''
    );
  }

  return stripePromise;
};
