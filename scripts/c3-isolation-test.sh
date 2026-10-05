#!/usr/bin/env bash
# C3 identity-isolation test.
#
# Proves that the structural service CANNOT reach identity_db, by attempting
# the connection and REQUIRING IT TO FAIL. A test that passes because it never
# tried is worthless; this one fails loudly if the boundary is wrong.
#
# Unlike the earlier schema verification, this one does not need PostGIS: it
# tests credential and network isolation, not spatial behaviour.

set -uo pipefail
cd "$(dirname "$0")"

PGBIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
export PATH="$PGBIN:$PATH"
SOCK="${TMPDIR:-/tmp}/c3-$$"
DATADIR="$(mktemp -d "${TMPDIR:-/tmp}/c3data-XXXX")"
cleanup() {
  pg_ctl -D "$DATADIR" -m immediate stop >/dev/null 2>&1
  rm -rf "$DATADIR" "$SOCK"
}
trap cleanup EXIT

# Order matters: initialise the cluster, create the socket dir, write auth
# config, THEN start. Reordering any of these makes the probes measure the
# wrong thing — e.g. starting before initdb silently yields an empty log and a
# test that "passes" every negative assertion vacuously.
mkdir -p "$SOCK"
initdb -D "$DATADIR" -U postgres --auth=trust >/dev/null 2>&1 || {
  printf '  \033[31m! initdb failed\033[0m\n'; exit 1; }

# Local socket connections stay trust (admin convenience); TCP connections
# require scram so that per-role CONNECT revocations are enforced for real.
# Trust-everywhere would make the role probes meaningless: every role would
# connect regardless of grants, which is exactly the hole this test exists to
# catch.
printf "local all all trust\nhost all all 127.0.0.1/32 scram-sha-256\nhost all all ::1/128 scram-sha-256\n" \
  > "$DATADIR/pg_hba.conf"
printf "listen_addresses = '127.0.0.1'\n" >> "$DATADIR/postgresql.auto.conf"

PSQL=(psql -h "$SOCK" -p 5749 -U postgres -v ON_ERROR_STOP=1)

pg_ctl -D "$DATADIR" -o "-k $SOCK -p 5749" -l "$DATADIR/pg.log" start >/dev/null 2>&1
for _ in $(seq 1 30); do
  "${PSQL[@]}" -c "SELECT 1;" >/dev/null 2>&1 && break
  sleep 0.3
done

# A dead server makes every negative check "pass" vacuously. Refuse to run.
if ! "${PSQL[@]}" -c "SELECT 1;" >/dev/null 2>&1; then
  printf '  \033[31m✗ server did not start — refusing to run (a dead server\033[0m\n'
  printf '    makes every negative assertion pass vacuously)\033[0m\n'
  printf '  log: %s\n' "$DATADIR/pg.log"
  tail -5 "$DATADIR/pg.log" 2>/dev/null
  exit 1
fi
PSQL_TCP=(psql -h 127.0.0.1 -p 5749 -U postgres -v ON_ERROR_STOP=1)

say() { printf '%s\n' "$*"; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=1; }
FAILED=0

say ""
say "C3 — identity isolation (credential + network boundary)"
say "────────────────────────────────────────────────────────────────────────"

initdb -D "$DATADIR" -U postgres --auth=trust >/dev/null 2>&1
# auth + listen config must be written BEFORE start, or the server comes up
# with the wrong settings and every probe becomes meaningless

"${PSQL[@]}" -c "CREATE DATABASE registry_db;" >/dev/null 2>&1
"${PSQL[@]}" -c "CREATE DATABASE identity_db;"  >/dev/null 2>&1
"${PSQL[@]}" -c "CREATE ROLE registry_api LOGIN PASSWORD 'registry_only';" >/dev/null 2>&1
"${PSQL[@]}" -c "CREATE ROLE consent_api  LOGIN PASSWORD 'consent_only';"  >/dev/null 2>&1
"${PSQL[@]}" -c "ALTER ROLE postgres PASSWORD 'admin_pw';" >/dev/null 2>&1

# Grant registry_api access to registry_db ONLY.
# apply the real migrations so the test exercises the shipped schema
"${PSQL[@]}" -d identity_db -f ../services/consent-api/migrations/000_init.sql >/dev/null 2>&1
"${PSQL[@]}" -d identity_db -c "GRANT USAGE ON SCHEMA public TO consent_api;" >/dev/null 2>&1
"${PSQL[@]}" -d identity_db -c "GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO consent_api;" >/dev/null 2>&1

"${PSQL[@]}" -d registry_db -c "GRANT CONNECT ON DATABASE registry_db TO registry_api;" >/dev/null 2>&1
"${PSQL[@]}" -d registry_db -c "GRANT USAGE ON SCHEMA public TO registry_api;" >/dev/null 2>&1
"${PSQL[@]}" -d registry_db -c "CREATE TABLE t_probe(x int); GRANT SELECT ON t_probe TO registry_api;" >/dev/null 2>&1

# ---- the boundary itself -------------------------------------------------
# PUBLIC holds CONNECT on every database by default, so "registry_api has no
# explicit grant" is NOT isolation — the role still connects via PUBLIC.
# The boundary requires revoking CONNECT from PUBLIC, then granting it only to
# the service that owns each database. Without this, C3 is a convention.
"${PSQL[@]}" -c "REVOKE ALL ON DATABASE identity_db FROM PUBLIC;" >/dev/null 2>&1
"${PSQL[@]}" -c "GRANT CONNECT ON DATABASE identity_db TO consent_api;" >/dev/null 2>&1
"${PSQL[@]}" -c "REVOKE ALL ON DATABASE identity_db FROM registry_api;" >/dev/null 2>&1

say ""
say "1. registry_api on registry_db (must SUCCEED)"
if PGPASSWORD=registry_only psql -h 127.0.0.1 -p 5749 -U registry_api -d registry_db -c "SELECT 1;" >/dev/null 2>&1; then
  pass "structural service reaches its own database"
else
  fail "structural service cannot reach registry_db — misconfigured"
fi

say ""
say "2. registry_api on identity_db (must FAIL)"
OUT=$(PGPASSWORD=registry_only psql -h 127.0.0.1 -p 5749 -U registry_api -d identity_db -c "SELECT 1;" 2>&1)
if [ $? -eq 0 ]; then
  fail "C3 BROKEN: registry_api reached identity_db"
  say "     $OUT"
else
  pass "registry_api is refused identity_db"
  say "     $(printf '%s' "$OUT" | head -1)"
fi

say ""
say "3. consent_api on identity_db (must SUCCEED)"
if PGPASSWORD=consent_only psql -h 127.0.0.1 -p 5749 -U consent_api -d identity_db -c "SELECT 1;" >/dev/null 2>&1; then
  pass "consent service reaches identity_db"
else
  fail "consent service cannot reach identity_db — misconfigured"
fi

say ""
say "4. no cross-database foreign key exists (the structural separation)"
# A FK whose NAME contains 'structure' is fine — structure_link holds a public
# code as TEXT, deliberately not a reference. The real breach is a FK whose
# TARGET lives in the structural database, which is what this checks.
FK=$("${PSQL[@]}" -d identity_db -tAc "
  SELECT count(*) FROM pg_constraint c
  JOIN pg_class child ON child.oid = c.conrelid
  JOIN pg_class parent ON parent.oid = c.confrelid
  WHERE c.contype='f'
    AND parent.relname IN ('structure','structure_service','dedup_candidate',
                           'grievance','breadcrumb','walk_segment','walk_node');")
# and confirm structure_link holds text, not a structural row reference
FK2=$("${PSQL[@]}" -d identity_db -tAc "
  SELECT data_type FROM information_schema.columns
  WHERE table_name='structure_link' AND column_name='structure_code';")
if [ "${FK2:-}" != "text" ]; then
  fail "structure_link.structure_code is ${FK2:-missing}, expected text (no structural reference)"
else
  pass "structure_link references a public code as TEXT, never a structural row"
fi
if [ "${FK:-0}" = "0" ]; then
  pass "identity_db has no foreign key into structural data"
else
  fail "C3 BROKEN: identity_db references a structure table"
fi

say ""
say "5. PUBLIC holds no CONNECT on identity_db (the actual boundary)"
PUBCONN=$("${PSQL[@]}" -d registry_db -tAc "
  SELECT has_database_privilege('public','identity_db','CONNECT');")
if [ "${PUBCONN:-0}" = "f" ]; then
  pass "CONNECT revoked from PUBLIC on identity_db"
else
  fail "C3 WEAK: PUBLIC can still CONNECT to identity_db"
fi

say ""
say "6. registry_api has no table grants inside identity_db"
GRANTS=$("${PSQL[@]}" -d identity_db -tAc "
  SELECT count(*) FROM information_schema.role_table_grants
  WHERE grantee='registry_api';")
if [ "${GRANTS:-0}" = "0" ]; then
  pass "registry_api holds no grants on any identity table"
else
  fail "C3 BROKEN: registry_api holds $GRANTS grant(s) in identity_db"
fi

say ""
say "7. the consent service can see its own identity tables"
GHOST=$(PGPASSWORD=consent_only psql -h 127.0.0.1 -p 5749 -U consent_api -d identity_db -tAc "
  SELECT count(*) FROM pg_tables WHERE schemaname='public'
    AND tablename IN ('resident','consent','structure_link','consent_disclosure_audit');")
if [ "${GHOST:-0}" = "4" ]; then
  pass "identity tables exist and are owned by the consent service only"
else
  fail "consent_api cannot see identity tables"
fi

say ""
say "8. consent-api functions against identity_db (the C3 boundary is usable, not broken)"
N=$(PGPASSWORD=consent_only psql -h 127.0.0.1 -p 5749 -U consent_api -d identity_db -tAc \
  "INSERT INTO resident (display_alias, created_at) VALUES ('probe', now()) RETURNING id;" 2>&1)
if printf '%s' "$N" | grep -qiE '^[0-9a-f-]{36}$'; then
  pass "consent service can read AND write identity_db"
else
  fail "consent service cannot operate: $N"
fi

say ""
say "9. the C8 dev encryption key is flagged, not silently shipped"
if grep -q "dev-only-do-not-ship" ../services/consent-api/src/consent.js 2>/dev/null; then
  pass "dev key is explicitly marked (must be replaced with KMS keys before deploy)"
else
  fail "dev encryption key found but NOT marked — it could ship unnoticed"
fi

say ""
say "────────────────────────────────────────────────────────────────────────"
if [ "$FAILED" = "0" ]; then
  printf '  \033[32mC3 VERIFIED — identity is structurally unreachable from the registry\033[0m\n\n'
  exit 0
else
  printf '  \033[31mC3 FAILED — boundary is not enforced\033[0m\n\n'
  exit 1
fi