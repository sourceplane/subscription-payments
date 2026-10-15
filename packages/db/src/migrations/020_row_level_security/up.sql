-- Row-level security on every table in `public`, with upstream's policies.
--
-- Supabase's Data API (PostgREST) serves `public` to anyone holding the
-- project's anon key, which is public by design: this app ships it to every
-- browser. So no table here may be without row-level security. The app itself
-- reads and writes through that API — supabase-js with the visitor's session
-- (`anon`, `authenticated`) and, for the Stripe webhook's sync and the
-- customer mapping, the service-role key, which bypasses RLS — so the tables
-- keep the policies upstream's schema (010, init.sql verbatim) wrote:
--
--   users          own row: select, update        (auth.uid() = id)
--   customers      no policy — private, service role only
--   products       public read
--   prices         public read
--   subscriptions  own rows: select               (auth.uid() = user_id)
--
-- 010 already enabled RLS on all five; this states the rule as its own
-- migration (each ENABLE is a no-op on an enabled table) and then CHECKS it:
-- if any table in `public` is still without row-level security, it stops
-- here, before the app that would serve it deploys. tests/db runs the same
-- check after every migration, and the e2e asks the real Data API.
--
-- Idempotent, as every migration here must be: the Supabase Management API
-- adapter sends each statement in autocommit mode.

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  open_tables text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO open_tables
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity;
  IF open_tables IS NOT NULL THEN
    RAISE EXCEPTION 'tables in public without row-level security, which the Data API would serve to the anon key: %', open_tables;
  END IF;
END
$$;
