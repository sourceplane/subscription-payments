#!/usr/bin/env bash
# A Supabase project's API on this machine — Auth and the Data API, the real
# binaries — over the throwaway Postgres testing/lib/local-postgres.sh starts.
# Sourced, after local-postgres.sh.
#
#   sb_fetch <cache-dir>              download (once) and verify the pinned
#                                     GoTrue and PostgREST releases; prints the
#                                     directory holding `auth` and `postgrest`
#   sb_roles <pg-admin-url>           what Supabase has before any migration:
#                                     service_role (BYPASSRLS), authenticator
#                                     (the Data API's login), supabase_auth_admin
#                                     and the `auth` schema it owns
#   sb_auth_up <bin> <pg-port> <auth-port> <gateway-url> <site-url> <secret> <log>
#                                     start Auth: its own migrations, then serve.
#                                     Sign-up signs the user straight in, as the
#                                     supabase root configures a project with no
#                                     SMTP of its own (mailer_autoconfirm)
#   sb_auth_grants <pg-admin-url>     what Supabase grants `postgres` on Auth's
#                                     tables, which the app's migration 010
#                                     references and triggers on
#   sb_rest_up <bin> <pg-port> <rest-port> <secret> <log>
#                                     start the Data API over `public` (after the
#                                     migrations, so its schema cache has them)
#   sb_jwt <secret> <role>            an API key: an HS256 JWT for anon or
#                                     service_role, signed as Supabase signs them
#
# The gateway that puts both behind one origin with the `apikey` check is
# testing/lib/supabase-gateway.py. Every server is the caller's to stop (run
# each under setsid and stop its process group).
#
# The releases are pinned by version AND sha256: what is tested is the same
# bytes every run. GoTrue is supabase/auth's own release; PostgREST is the
# Data API Supabase runs.
#
# Needs: curl, tar (xz), sha256sum, psql, python3.

SB_AUTH_VERSION=2.180.0
SB_AUTH_SHA256=3fe064281f5cf7bda94251a3bd9e87a690d081381d9ea93b1491163735209e2e
SB_REST_VERSION=12.2.12
SB_REST_SHA256=5de4092f1719da3353c40bf96c8dec6913f2254a7cd0b61cc05f233153b557d5

sb_fetch() {
  local cache="$1" dir
  dir="$cache/auth-$SB_AUTH_VERSION-postgrest-$SB_REST_VERSION"
  if [ -x "$dir/auth" ] && [ -x "$dir/postgrest" ] && [ -d "$dir/migrations" ]; then echo "$dir"; return 0; fi
  mkdir -p "$dir"
  local auth_tgz="$dir/auth.tgz" rest_txz="$dir/postgrest.txz"
  curl -fsSL --retry 3 -o "$auth_tgz" \
    "https://github.com/supabase/auth/releases/download/v$SB_AUTH_VERSION/auth-v$SB_AUTH_VERSION-x86.tar.gz" \
    || { echo "sb_fetch: could not download supabase/auth v$SB_AUTH_VERSION" >&2; return 1; }
  curl -fsSL --retry 3 -o "$rest_txz" \
    "https://github.com/PostgREST/postgrest/releases/download/v$SB_REST_VERSION/postgrest-v$SB_REST_VERSION-linux-static-x86-64.tar.xz" \
    || { echo "sb_fetch: could not download PostgREST v$SB_REST_VERSION" >&2; return 1; }
  echo "$SB_AUTH_SHA256  $auth_tgz" | sha256sum -c --quiet - >&2 \
    && echo "$SB_REST_SHA256  $rest_txz" | sha256sum -c --quiet - >&2 \
    || { echo "sb_fetch: a release does not match its pinned sha256" >&2; rm -rf "$dir"; return 1; }
  tar xzf "$auth_tgz" -C "$dir" && tar xJf "$rest_txz" -C "$dir" && rm -f "$auth_tgz" "$rest_txz" \
    || { echo "sb_fetch: could not unpack the releases" >&2; rm -rf "$dir"; return 1; }
  echo "$dir"
}

sb_roles() {
  psql "$1" -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
CREATE ROLE authenticator LOGIN NOINHERIT;
GRANT anon, authenticated, service_role TO authenticator;
GRANT service_role TO postgres;
GRANT USAGE ON SCHEMA public TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
CREATE ROLE supabase_auth_admin LOGIN NOINHERIT CREATEROLE;
CREATE SCHEMA auth AUTHORIZATION supabase_auth_admin;
GRANT CREATE ON DATABASE postgres TO supabase_auth_admin;
ALTER ROLE supabase_auth_admin SET search_path = auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role, postgres;
SQL
}

sb_auth_up() {
  local bin="$1" pgport="$2" port="$3" gateway="$4" site="$5" secret="$6" log="$7"
  # Auth reads its migrations from ./migrations; the release unpacks them
  # beside the binary. The settings are a hosted project's: tokens signed with
  # the project's JWT secret, a signed-in user's carrying the `authenticated`
  # role the Data API switches to (GOTRUE_JWT_DEFAULT_GROUP_NAME, which Auth
  # logs as deprecated and Supabase still sets), the service role its admin.
  (
    cd "$bin" || exit 1
    export GOTRUE_API_HOST=127.0.0.1 PORT="$port" API_EXTERNAL_URL="$gateway/auth/v1" \
      GOTRUE_DB_DRIVER=postgres \
      DATABASE_URL="postgres://supabase_auth_admin@127.0.0.1:$pgport/postgres?sslmode=disable" \
      GOTRUE_DB_NAMESPACE=auth GOTRUE_SITE_URL="$site" GOTRUE_URI_ALLOW_LIST="$site/**" \
      GOTRUE_JWT_SECRET="$secret" GOTRUE_JWT_EXP=3600 GOTRUE_JWT_AUD=authenticated \
      GOTRUE_JWT_ADMIN_ROLES=service_role GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated \
      GOTRUE_DISABLE_SIGNUP=false GOTRUE_EXTERNAL_EMAIL_ENABLED=true GOTRUE_MAILER_AUTOCONFIRM=true \
      GOTRUE_RATE_LIMIT_EMAIL_SENT=1000 GOTRUE_LOG_LEVEL=info
    ./auth migrate || exit 1
    exec setsid ./auth serve
  ) > "$log" 2>&1 < /dev/null &
  SB_AUTH_PID=$!
  local _
  for _ in $(seq 1 60); do
    curl -sf -o /dev/null "http://127.0.0.1:$port/health" && return 0
    kill -0 "$SB_AUTH_PID" 2>/dev/null || { echo "sb_auth_up: Auth exited" >&2; tail -20 "$log" >&2; return 1; }
    sleep 0.5
  done
  echo "sb_auth_up: Auth never answered /health" >&2; tail -20 "$log" >&2; return 1
}

sb_auth_grants() {
  psql "$1" -X -q -v ON_ERROR_STOP=1 <<'SQL'
GRANT ALL ON ALL TABLES IN SCHEMA auth TO postgres;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO anon, authenticated, service_role, postgres;
SQL
}

sb_rest_up() {
  local bin="$1" pgport="$2" port="$3" secret="$4" log="$5"
  (
    export PGRST_DB_URI="postgres://authenticator@127.0.0.1:$pgport/postgres" \
      PGRST_DB_SCHEMAS=public PGRST_DB_ANON_ROLE=anon PGRST_JWT_SECRET="$secret" \
      PGRST_SERVER_HOST=127.0.0.1 PGRST_SERVER_PORT="$port" PGRST_DB_USE_LEGACY_GUCS=false
    exec setsid "$bin/postgrest"
  ) > "$log" 2>&1 < /dev/null &
  SB_REST_PID=$!
  local _
  for _ in $(seq 1 60); do
    curl -sf -o /dev/null "http://127.0.0.1:$port/" && return 0
    kill -0 "$SB_REST_PID" 2>/dev/null || { echo "sb_rest_up: PostgREST exited" >&2; tail -20 "$log" >&2; return 1; }
    sleep 0.5
  done
  echo "sb_rest_up: PostgREST never answered" >&2; tail -20 "$log" >&2; return 1
}

sb_jwt() {
  python3 - "$1" "$2" <<'PY'
import base64, hashlib, hmac, json, sys, time
secret, role = sys.argv[1], sys.argv[2]
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
body = b64(json.dumps({"iss": "supabase", "ref": "localproject", "role": role,
                       "iat": int(time.time()), "exp": int(time.time()) + 3600},
                      separators=(",", ":")).encode())
sig = b64(hmac.new(secret.encode(), f"{head}.{body}".encode(), hashlib.sha256).digest())
print(f"{head}.{body}.{sig}")
PY
}
