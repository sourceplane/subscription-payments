import { createClient } from '@supabase/supabase-js';

// Not upstream's: the deploy's smoke check and the bootstrap's probe read
// this. A pricing page that renders proves the Worker deployed; this proves
// what that page does not — the Worker reaches its environment's Supabase
// project with the URL and anon key it was built with, the schema db-migrate
// applies is there (the `products` table, which the anon key may read), and
// the service-role key the deploy pushed as a Worker secret is the project's
// own (only a service-role key may list Auth's users). The Stripe webhook's
// sync and the customer mapping use that key; nothing else here needs it.
export const dynamic = 'force-dynamic';

type Health = {
  ok: boolean;
  supabase: 'reachable' | 'unreachable' | 'unconfigured';
  schema?: 'migrated' | 'missing' | 'unknown';
  serviceRole?: 'valid' | 'invalid' | 'missing';
};

const options = {
  auth: { persistSession: false, autoRefreshToken: false }
} as const;

function answer(health: Health) {
  return Response.json(health, {
    status: health.ok ? 200 : 503,
    headers: { 'cache-control': 'no-store' }
  });
}

export async function GET() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !anonKey) {
    return answer({ ok: false, supabase: 'unconfigured' });
  }

  try {
    const anon = createClient(url, anonKey, options);
    const { error, status } = await anon.from('products').select('id').limit(1);
    if (error && status === 0) {
      console.error('health: Supabase unreachable', error.message);
      return answer({ ok: false, supabase: 'unreachable' });
    }
    // PostgREST answers 404 (PGRST205, or 42P01 from Postgres) for a table
    // its schema cache does not have: the migrations have not run.
    const schema = !error
      ? 'migrated'
      : status === 404 || error.code === 'PGRST205' || error.code === '42P01'
        ? 'missing'
        : 'unknown';
    if (error) console.error('health: products query failed', status, error.message);

    let serviceRole: Health['serviceRole'] = 'missing';
    if (serviceRoleKey) {
      const admin = createClient(url, serviceRoleKey, options);
      const { error: adminError } = await admin.auth.admin.listUsers({
        page: 1,
        perPage: 1
      });
      serviceRole = adminError ? 'invalid' : 'valid';
      if (adminError) console.error('health: service-role check failed', adminError.message);
    }

    return answer({
      ok: schema === 'migrated' && serviceRole === 'valid',
      supabase: 'reachable',
      schema,
      serviceRole
    });
  } catch (error) {
    console.error('health: Supabase check failed', error);
    return answer({ ok: false, supabase: 'unreachable' });
  }
}
