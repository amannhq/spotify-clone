#!/usr/bin/env bash
# Starts the services every session of this environment needs:
#   * PostgreSQL              (127.0.0.1:54322)
#   * GoTrue auth server      (127.0.0.1:9999)
#   * PostgREST               (127.0.0.1:54330)
#   * Supabase gateway + storage (127.0.0.1:54321)
#   * Next.js dev server      (127.0.0.1:3000)
#
# Every service is started in the background with its output in a log file, and
# the script exits 0. Re-running it is safe: a service that is already running
# is left alone.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${HOME}/.local/share/spotify-clone"
BIN="${RUNTIME}/bin"
PGDATA="${RUNTIME}/pgdata"
STORAGE="${RUNTIME}/storage"
LOGS="${RUNTIME}/logs"
PG_PORT=54322
PGBIN="$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)"

mkdir -p "${LOGS}"

if [ ! -s "${RUNTIME}/env" ]; then
    echo "Missing ${RUNTIME}/env - run the install steps first" >&2
    exit 1
fi
# shellcheck disable=SC1091
set -a
. "${RUNTIME}/env"
set +a

JWT_SECRET="$(cat "${RUNTIME}/jwt-secret")"

is_running() {
    local pidfile="$1"
    [ -f "${pidfile}" ] && kill -0 "$(cat "${pidfile}")" 2>/dev/null
}

start_service() {
    local name="$1"
    shift
    local pidfile="${LOGS}/${name}.pid"
    if is_running "${pidfile}"; then
        echo "${name} already running"
        return 0
    fi
    "$@" >>"${LOGS}/${name}.log" 2>&1 &
    echo $! >"${pidfile}"
    echo "started ${name} (pid $(cat "${pidfile}"))"
}

echo "==> PostgreSQL"
if ! "${PGBIN}/pg_ctl" -D "${PGDATA}" status >/dev/null 2>&1; then
    "${PGBIN}/pg_ctl" -D "${PGDATA}" -l "${LOGS}/postgres.log" \
        -o "-p ${PG_PORT} -k /tmp -c listen_addresses=127.0.0.1" -w start >/dev/null
    echo "started postgres"
else
    echo "postgres already running"
fi

echo "==> GoTrue (auth)"
start_service auth env \
    DATABASE_URL="postgres://postgres@127.0.0.1:${PG_PORT}/postgres" \
    GOTRUE_DB_DRIVER=postgres \
    GOTRUE_DB_MIGRATIONS_PATH="${BIN}/migrations" \
    GOTRUE_SITE_URL=http://127.0.0.1:3000 \
    GOTRUE_URI_ALLOW_LIST='*' \
    GOTRUE_DISABLE_SIGNUP=false \
    GOTRUE_EXTERNAL_EMAIL_ENABLED=true \
    GOTRUE_MAILER_AUTOCONFIRM=true \
    GOTRUE_PASSWORD_MIN_LENGTH=6 \
    GOTRUE_JWT_SECRET="${JWT_SECRET}" \
    GOTRUE_JWT_ADMIN_ROLES=service_role \
    GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated \
    GOTRUE_JWT_EXP=3600 \
    GOTRUE_LOG_LEVEL=info \
    API_HOST=127.0.0.1 \
    API_PORT=9999 \
    PORT=9999 \
    API_EXTERNAL_URL=http://127.0.0.1:54321/auth/v1 \
    "${BIN}/auth" serve

echo "==> PostgREST"
start_service postgrest env \
    PGRST_DB_URI="postgres://authenticator@127.0.0.1:${PG_PORT}/postgres" \
    PGRST_DB_SCHEMA=public \
    PGRST_DB_SCHEMAS=public \
    PGRST_DB_ANON_ROLE=anon \
    PGRST_DB_POOL=5 \
    PGRST_JWT_SECRET="${JWT_SECRET}" \
    PGRST_SERVER_HOST=127.0.0.1 \
    PGRST_SERVER_PORT=54330 \
    PGRST_LOG_LEVEL=warn \
    "${BIN}/postgrest"

echo "==> Supabase gateway and storage"
start_service gateway env STORAGE_ROOT="${STORAGE}" SUPABASE_GATEWAY_PORT=54321 \
    node "${ROOT}/.alan/local-supabase/gateway.mjs"

echo "==> Next.js"
start_service next env \
    NEXT_PUBLIC_SUPABASE_URL="${NEXT_PUBLIC_SUPABASE_URL}" \
    NEXT_PUBLIC_SUPABASE_ANON_KEY="${NEXT_PUBLIC_SUPABASE_ANON_KEY}" \
    SUPABASE_SERVICE_ROLE_KEY="${SUPABASE_SERVICE_ROLE_KEY}" \
    NEXT_PUBLIC_SITE_URL="${NEXT_PUBLIC_SITE_URL}" \
    NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY="${NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY}" \
    STRIPE_SECRET_KEY="${STRIPE_SECRET_KEY}" \
    STRIPE_WEBHOOK_SECRET="${STRIPE_WEBHOOK_SECRET}" \
    npm --prefix "${ROOT}" run dev -- --port 3000

echo "==> All services launched"