// apps/web/next.config.mjs is JavaScript (as the template ships it); these are
// the two exports wrangler-config.test.ts reads.
declare module "@/next.config.mjs" {
  export const PUBLIC_VARS: string[];
  export function publicBuildEnv(
    env?: Record<string, string | undefined>,
    wranglerConfig?: string,
  ): Record<string, string>;
}
