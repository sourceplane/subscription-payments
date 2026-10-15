import type { Tables } from '@/types_db';

type Product = Tables<'products'>;
type Price = Tables<'prices'>;
export interface ProductWithPrices extends Product {
  prices: Price[];
}

// What the pricing page shows before Stripe is connected: the template's own
// two plans, as `fixtures/stripe-fixtures.json` creates them in Stripe (`pnpm
// stripe:fixtures`) — Hobby and Freelancer, monthly and yearly. Upstream reads
// plans only from the `products` and `prices` tables, which Stripe's webhook
// fills, so a fresh deployment had nothing to show. These are never written
// to the database and nothing can be bought with them: their ids are not
// Stripe's, and checkout stays off until the owner adds the keys. Once Stripe
// is connected the page shows what the webhook synced, as upstream does.
//
// tests/web holds this list to the fixture file, so the two cannot drift.
const product = (
  key: string,
  name: string,
  description: string,
  index: number,
  monthly: number,
  yearly: number
): ProductWithPrices => {
  const id = `sample_prod_${key}`;
  const price = (interval: 'month' | 'year', unit_amount: number): Price => ({
    id: `sample_price_${key}_${interval}`,
    product_id: id,
    active: true,
    unit_amount,
    currency: 'usd',
    type: 'recurring',
    interval,
    interval_count: 1,
    trial_period_days: null
  });
  return {
    id,
    active: true,
    name,
    description,
    image: null,
    metadata: { index },
    prices: [price('month', monthly), price('year', yearly)]
  };
};

export const SAMPLE_PLANS: ProductWithPrices[] = [
  product('hobby', 'Hobby', 'Hobby product description', 0, 1000, 10000),
  product('freelancer', 'Freelancer', 'Freelancer product description', 1, 2000, 20000)
];
