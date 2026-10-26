#!/usr/bin/env bash
# Alan cloud environment install steps for the spotify-clone repository.
#
# Runs once per image build, in the builder (no Docker daemon, no TTY,
# passwordless sudo, network available). It bakes in everything the app needs to
# start from a clean image:
#   * the local Supabase-compatible stack (PostgreSQL + PostgREST + GoTrue)
#     that replaces the hosted Supabase project the app originally pointed at;
#   * the project's Node dependencies;
#   * a prepared database cluster, seeded songs and generated media.
#
# start.sh starts those services in every session.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${HOME}/.local/share/spotify-clone"
BIN="${RUNTIME}/bin"
PGDATA="${RUNTIME}/pgdata"
STORAGE="${RUNTIME}/storage"
LOGS="${RUNTIME}/logs"
PG_PORT=54322
PGBIN="$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)"

POSTGREST_VERSION="v16.5"
AUTH_VERSION="v2.197.0"

mkdir -p "${BIN}" "${STORAGE}" "${LOGS}"

echo "==> Installing tool binaries"
if [ ! -x "${BIN}/postgrest" ]; then
    curl -fsSL "https://github.com/PostgREST/postgrest/releases/download/${POSTGREST_VERSION}/postgrest-${POSTGREST_VERSION}-linux-static-x86-64.tar.xz" \
        | tar -xJ -C "${BIN}" postgrest
fi
if [ ! -x "${BIN}/auth" ]; then
    work="$(mktemp -d)"
    curl -fsSL "https://github.com/supabase/auth/releases/download/${AUTH_VERSION}/auth-${AUTH_VERSION}-amd64.tar.xz" \
        | tar -xJ -C "${work}"
    mv "${work}/auth" "${BIN}/auth"
    rm -rf "${BIN}/migrations"
    mv "${work}/migrations" "${BIN}/migrations"
    rm -rf "${work}"
fi

echo "==> Installing Node dependencies"
if [ -f "${ROOT}/package-lock.json" ]; then
    npm ci --no-audit --no-fund
else
    npm install --no-audit --no-fund
fi

echo "==> Preparing the database cluster"
if [ ! -s "${RUNTIME}/jwt-secret" ]; then
    head -c 48 /dev/urandom | base64 | tr -d '\n=' >"${RUNTIME}/jwt-secret"
    chmod 600 "${RUNTIME}/jwt-secret"
fi
JWT_SECRET="$(cat "${RUNTIME}/jwt-secret")"

if [ ! -s "${PGDATA}/PG_VERSION" ]; then
    "${PGBIN}/initdb" -D "${PGDATA}" -U alan --auth-local=trust --auth-host=trust -E UTF8 >/dev/null
fi

"${PGBIN}/pg_ctl" -D "${PGDATA}" -l "${LOGS}/postgres-setup.log" \
    -o "-p ${PG_PORT} -k /tmp -c listen_addresses=127.0.0.1" -w start >/dev/null

cleanup() {
    "${PGBIN}/pg_ctl" -D "${PGDATA}" -m fast -w stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Creating the database roles"
"${PGBIN}/psql" -h /tmp -p "${PG_PORT}" -U alan -d postgres -v ON_ERROR_STOP=1 -q \
    -f "${ROOT}/.alan/local-supabase/roles.sql"

echo "==> Applying the auth (GoTrue) migrations"
# shellcheck disable=SC1091
. "${ROOT}/.alan/local-supabase/gotrue.env"
(
    cd "${BIN}"
    DATABASE_URL="postgres://postgres@127.0.0.1:${PG_PORT}/postgres" \
        GOTRUE_DB_MIGRATIONS_PATH="${BIN}/migrations" \
        GOTRUE_JWT_SECRET="${JWT_SECRET}" \
        "${BIN}/auth" migrate
)

echo "==> Applying the application schema and seed data"
"${PGBIN}/psql" -h /tmp -p "${PG_PORT}" -U alan -d postgres -v ON_ERROR_STOP=1 -q \
    -f "${ROOT}/.alan/local-supabase/schema.sql"
"${PGBIN}/psql" -h /tmp -p "${PG_PORT}" -U alan -d postgres -v ON_ERROR_STOP=1 -q \
    -f "${ROOT}/.alan/local-supabase/seed.sql"

echo "==> Generating local storage media"
python3 "${ROOT}/.alan/local-supabase/make-media.py" "${STORAGE}"

echo "==> Writing the local stack environment"
ANON_KEY="$(node "${ROOT}/.alan/local-supabase/make-jwt.mjs" "${JWT_SECRET}" anon)"
SERVICE_KEY="$(node "${ROOT}/.alan/local-supabase/make-jwt.mjs" "${JWT_SECRET}" service_role)"

cat >"${RUNTIME}/env" <<ENV
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
NEXT_PUBLIC_SUPABASE_ANON_KEY=${ANON_KEY}
SUPABASE_SERVICE_ROLE_KEY=${SERVICE_KEY}
NEXT_PUBLIC_SITE_URL=http://127.0.0.1:3000
NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_test_local_placeholder
STRIPE_SECRET_KEY=sk_test_local_placeholder
STRIPE_WEBHOOK_SECRET=whsec_local_placeholder
ENV
chmod 600 "${RUNTIME}/env"

echo "==> Setup complete"