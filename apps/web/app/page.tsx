import Pricing from '@/components/ui/Pricing/Pricing';
import { createClient } from '@/utils/supabase/server';
import {
  getProducts,
  getSubscription,
  getUser
} from '@/utils/supabase/queries';
import {
  isCheckoutEnabled,
  stripePublishableKey
} from '@/utils/stripe/config';
import { SAMPLE_PLANS } from '@/utils/stripe/sample-plans';

export default async function PricingPage() {
  const supabase = await createClient();
  const [user, products, subscription] = await Promise.all([
    getUser(supabase),
    getProducts(supabase),
    getSubscription(supabase)
  ]);

  // Without Stripe the page still shows plans — what the database holds, or,
  // on a fresh deployment whose webhook has synced nothing, the template's
  // sample plans — with checkout off and a notice saying why
  // (utils/stripe/config.ts). With Stripe connected it is upstream's page.
  const checkoutEnabled = isCheckoutEnabled();
  const synced = products ?? [];
  const sample = !checkoutEnabled && synced.length === 0;

  return (
    <Pricing
      user={user}
      products={sample ? SAMPLE_PLANS : synced}
      subscription={subscription}
      checkout={{
        enabled: checkoutEnabled,
        publishableKey: checkoutEnabled ? stripePublishableKey() : undefined,
        samplePlans: sample
      }}
    />
  );
}
