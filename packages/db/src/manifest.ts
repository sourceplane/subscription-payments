import type { MigrationManifest } from "./types.js";

// Every migration the runner applies, in order, with the sha256 of its file.
// `pnpm --filter @saas/db run manifest:check` verifies the checksums;
// `manifest:fix` rewrites them after a migration file changes (only ever
// before that migration has been applied anywhere — an applied migration's
// checksum is immutable).
export const manifest: MigrationManifest = {
  version: 1,
  migrations: [
    {
      id: "000_control_baseline",
      context: "control",
      path: "000_control/up.sql",
      checksum:
        "2a5d7f30684c99e3ff441ca8a2c38038dedd1bab4db4a40e92cd36bb22be297f",
      description:
        "Baseline control migration — creates the migration tracking schema",
    },
    {
      id: "010_subscriptions_init",
      context: "app",
      path: "010_subscriptions_init/up.sql",
      checksum:
        "56d729613cb7575cd8520e76a5ee8c8a4fda48407257c22a2db7579708291f15",
      description:
        "The template's schema (supabase/migrations/20230530034630_init.sql, verbatim): users, customers, products, prices, subscriptions, the auth.users trigger, RLS policies and the realtime publication",
    },
  ],
};
