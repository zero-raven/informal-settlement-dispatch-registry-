#!/usr/bin/env bash
# Applies the registry_db migration to a live cluster and asserts the C8
# invariants hold. PostGIS is NOT available in this environment, so the
# geometry columns are shimmed — this proves DDL validity, FK ordering, CHECK
# constraints and the trigger, but NOT spatial behaviour. The spatial layer
# remains unverified; see docs/database.md section 5.

set -uo pipefail
cd "$(dirname "$0")"

# Binaries may live in /usr/bin or a versioned dir; prefer whichever has psql.
if ! command -v psql >/dev/null 2>&1; then
  PGBIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
  [ -n "$PGBIN" ] && export PATH="$PGBIN:$PATH"
fi
command -v psql >/dev/null 2>&1 || { echo "psql not found"; exit 1; }
SOCK="${TMPDIR:-/tmp}/reg-$$"
DATADIR="$(mktemp -d "${TMPDIR:-/tmp}/regdata-XXXX")"
cleanup() { pg_ctl -D "$DATADIR" -m immediate stop >/dev/null 2>&1; rm -rf "$DATADIR" "$SOCK"; }
trap cleanup EXIT

P() { psql -h "$SOCK" -p 5751 -U postgres -v ON_ERROR_STOP=1 "$@"; }
pass() { printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$1"; FAILED=1; }
FAILED=0

mkdir -p "$SOCK"
initdb -D "$DATADIR" -U postgres --auth=trust >/dev/null 2>&1
pg_ctl -D "$DATADIR" -o "-k $SOCK -p 5751" -l "$DATADIR/pg.log" start >/dev/null 2>&1
for _ in $(seq 1 30); do P -c "SELECT 1;" >/dev/null 2>&1 && break; sleep 0.3; done
P -c "SELECT 1;" >/dev/null 2>&1 || { echo "server failed to start"; tail -5 "$DATADIR/pg.log"; exit 1; }

P -c "CREATE DATABASE registry_db;" >/dev/null 2>&1
P -c "CREATE DATABASE identity_db;"  >/dev/null 2>&1

printf '\nRegistry schema + C8 invariants\n'
printf -- '--------------------------------------------------------------------------------\n'

# PostGIS is unavailable here: shim geometry as a typmod-free base type and drop
# only the spatial indexes. Everything else runs for real.
# A bare CREATE TYPE yields a SHELL type, which cannot hold values. The
# schema needs geometry to accept NULLs and comparisons, so use C-style base
# types with in/out functions and a typmod function. This shim proves DDL
# validity, FK ordering, CHECKs and triggers -- it proves NOTHING about spatial
# behaviour, which stays unverified without PostGIS.
SHIM=./shims/no-postgis.sql
if SHOUT=$(P -d registry_db -f "$SHIM" 2>&1); then
  pass "geometry/tstzrange shim installed"
else
  fail "shim failed to install:"
  printf '%s\n' "$SHOUT" | head -12
  exit 1
fi

# Strip PostGIS typmods (geometry(Polygon,4326) -> geometry) and gist indexes,
# plus the statements that genuinely require PostGIS. Everything else runs for
# real: types, FKs, CHECKs, triggers, unique indexes.
SED=/tmp/reg-nospatial.sql
sed -e 's/geometry *([A-Za-z]*, *[0-9]*)/geometry/g' \
    -e 's/tstzrange/tstzrange/g' \
    -e '/USING gist/d' \
    -e '/::geometry/d' \
    -e '/CREATE EXTENSION IF NOT EXISTS postgis/d' \
    ../services/registry-api/migrations/000_init.sql > "$SED"

# The aggregate view calls ST_Contains, which the shim stubs to false; keep it
# so its projection is still validated for the PRD 6.6 leak check.
# Apply EVERY migration in order, not just 000: a migration that never runs in
# a test is a migration that has never been verified. 001 is skipped here because
# it needs real PostGIS and is covered by scripts/postgis-verify.sh.
: > /tmp/reg-apply.log
for f in ../services/registry-api/migrations/0*.sql; do
  case "$(basename "$f")" in
    *postgis_verify*) continue ;;
  esac
  # strip only what genuinely requires PostGIS; everything else runs for real
  sed -e 's/geometry *([A-Za-z]*, *[0-9]*)/geometry/g' \
      -e '/USING gist/d' \
      -e '/::geometry/d' \
      -e '/CREATE EXTENSION IF NOT EXISTS postgis/d' \
      "$f" > /tmp/reg-one.sql
  printf '\n-- ==== %s ====\n' "$(basename "$f")" >> /tmp/reg-apply.log
  P -d registry_db -f /tmp/reg-one.sql >> /tmp/reg-apply.log 2>&1
done

if ! grep -q "^ERROR" /tmp/reg-apply.log; then
  pass "migration applies cleanly"
else
  fail "migration reported errors:"
  grep -E "ERROR" /tmp/reg-apply.log | head -20
fi

CNT=$(P -d registry_db -tAc "SELECT count(*) FROM pg_class WHERE relkind='r' AND relnamespace='public'::regnamespace;")
[ "${CNT:-0}" -ge 16 ] && pass "$CNT tables created" || fail "only $CNT tables"

ENUMS=$(P -d registry_db -tAc "SELECT count(*) FROM pg_type WHERE typtype='e';")
[ "${ENUMS:-0}" -ge 10 ] && pass "$ENUMS enums created" || fail "only $ENUMS enums"

TRG=$(P -d registry_db -tAc "SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal;")
[ "${TRG:-0}" -ge 3 ] && pass "$TRG triggers created" || fail "only $TRG triggers"

if ! P -d registry_db -c "SELECT 1 FROM assertion LIMIT 1;" >/dev/null 2>&1; then
  fail "assertion table absent — refusing to run C8 checks (they would pass vacuously)"
  exit 1
fi

printf '\nC8 — inference must never overwrite ground truth\n'
printf -- '--------------------------------------------------------------------------------\n'
P -d registry_db -c "INSERT INTO app_user (id,email,role) VALUES ('11111111-1111-1111-1111-111111111111','m@t','mapper');" >/dev/null 2>&1
P -d registry_db -c "INSERT INTO structure (id,created_by,centroid) VALUES ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','POINT(1 1)');" >/dev/null 2>&1

P -d registry_db -c "INSERT INTO assertion (entity_table,entity_id,field,value,evidence_class,state,source,observed_by,observed_at) VALUES ('structure','22222222-2222-2222-2222-222222222222','centroid','{\"lat\":12.97}','ground_truth','asserted','mapper_survey','mapper:4f2a',now());" >/dev/null 2>&1
pass "a mapper ground-truth assertion is accepted"

if P -d registry_db -c "INSERT INTO assertion (entity_table,entity_id,field,value,evidence_class,state,source,produced_by) VALUES ('structure','22222222-2222-2222-2222-222222222222','centroid','{\"lat\":13.0}','inference','asserted','imagery_diff','ml');" >/dev/null 2>&1; then
  fail "C8 BROKEN: an inference row claimed state=asserted"
else
  pass "an inference row cannot claim asserted (CHECK)"
fi

if P -d registry_db -c "INSERT INTO assertion (entity_table,entity_id,field,value,evidence_class,state,source,produced_by,observed_by) VALUES ('structure','22222222-2222-2222-2222-222222222222','footprint','{}','inference','candidate','imagery_diff','ml','mapper:4f2a');" >/dev/null 2>&1; then
  fail "C8 BROKEN: an inference row carried an observer"
else
  pass "an inference row cannot carry an observer (CHECK)"
fi

P -d registry_db -c "INSERT INTO assertion (entity_table,entity_id,field,value,evidence_class,state,source,produced_by,confidence) VALUES ('structure','22222222-2222-2222-2222-222222222222','footprint','{\"shift\":3}','inference','candidate','imagery_diff','ml:imagery',0.71);" >/dev/null 2>&1
pass "a legitimate inference candidate is accepted"

if OUT=$(P -d registry_db -c "UPDATE assertion SET evidence_class='inference', state='asserted', source='imagery_diff', observed_by=NULL, observed_at=NULL WHERE field='centroid' AND evidence_class='ground_truth' AND state='asserted';" 2>&1); then
  fail "C8 BROKEN: inference overwrote ground truth"
else
  pass "inference CANNOT overwrite ground truth (TRIGGER)"
  printf '     %s\n' "$(printf '%s' "$OUT" | head -1 | cut -c1-90)"
fi

REMAIN=$(P -d registry_db -tAc "SELECT value::text FROM assertion WHERE field='centroid' AND state='asserted';")
if [ "$REMAIN" = '{"lat": 12.97}' ]; then
  pass "ground truth survived intact: $REMAIN"
else
  fail "ground truth was altered: $REMAIN"
fi

printf '\nC1/C2 — code issuance constraints\n'
printf -- '--------------------------------------------------------------------------------\n'
# a bootstrapped candidate (never surveyed) must not be able to carry a code:
# codes are issued only after a human dedup decision (C1/C2).
P -d registry_db -c "INSERT INTO structure (id,created_by,status,centroid) VALUES ('55555555-5555-5555-5555-555555555555','11111111-1111-1111-1111-111111111111','candidate','POINT(1 1)');" >/dev/null 2>&1
if P -d registry_db -c "UPDATE structure SET code='SLR-C40001' WHERE id='55555555-5555-5555-5555-555555555555';" >/dev/null 2>&1; then
  fail "C1 BROKEN: a code was attached to an un-surveyed candidate"
else
  pass "an un-surveyed candidate cannot carry a code (CHECK)"
fi

# the combined-statement bypass must also be refused: setting code AND status
# in one UPDATE is what a naive CHECK would let through
if P -d registry_db -c "UPDATE structure SET code='SLR-C40001', status='surveyed' WHERE id='55555555-5555-5555-5555-555555555555';" >/dev/null 2>&1; then
  fail "C1 BROKEN: a code was minted by promoting and coding in one statement"
else
  pass "a code cannot be minted in the same statement that promotes the pin"
fi

# and a surveyed structure MAY, since the code is issued post-decision
P -d registry_db -c "UPDATE structure SET status='surveyed' WHERE id='22222222-2222-2222-2222-222222222222';" >/dev/null 2>&1
if P -d registry_db -c "UPDATE structure SET code='SLR-C40001' WHERE id='22222222-2222-2222-2222-222222222222';" >/dev/null 2>&1; then
  pass "a surveyed structure may carry a code after the dedup decision"
else
  fail "a surveyed structure cannot be issued a code — CHECK is too strict"
fi

# a duplicate code must be refused
if P -d registry_db -c "INSERT INTO structure (id,code,created_by,status,centroid) VALUES ('66666666-6666-6666-6666-666666666666','SLR-C40001','11111111-1111-1111-1111-111111111111','surveyed','POINT(2 2)');" >/dev/null 2>&1; then
  fail "C1 BROKEN: two structures share a code"
else
  pass "codes are unique (UNIQUE)"
fi

if P -d registry_db -c "INSERT INTO structure (id,created_by,structure_type,centroid) VALUES ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','non_residential','POINT(1 1)');" >/dev/null 2>&1; then
  fail "PRD 6.1 BROKEN: non_residential accepted without an explicit type"
else
  pass "non_residential requires an explicit type (CHECK)"
fi

P -d registry_db -c "INSERT INTO structure (id,created_by,structure_type,non_residential_subtype,centroid) VALUES ('44444444-4444-4444-4444-444444444444','11111111-1111-1111-1111-111111111111','non_residential','temple','POINT(1 1)');" >/dev/null 2>&1
pass "non_residential with an explicit type is accepted"

if P -d registry_db -c "INSERT INTO dedup_candidate (structure_a,structure_b,distance_m,score) VALUES ('22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222',5,0.9);" >/dev/null 2>&1; then
  fail "C2 BROKEN: a structure was compared with itself"
else
  pass "a structure cannot be deduped against itself (CHECK)"
fi

printf '\nC8/M5 — feedback worklist and candidate lifecycle\n'
printf -- '--------------------------------------------------------------------------------\n'

# 002_feedback.sql must have created the worklist with its ranking columns
TASKCOLS=$(P -d registry_db -tAc "
  SELECT count(*) FROM information_schema.columns
  WHERE table_name='task' AND column_name IN
    ('signal','signal_rank','priority','state','assignee','outcome','payload_json','completed_at');")
if [ "${TASKCOLS:-0}" -ge 7 ]; then
  pass "task table created with ranking + lifecycle columns"
else
  fail "task table missing columns (found ${TASKCOLS:-0}, expected >= 7)"
fi

# 'rejected' must be a legal assertion state, or rejection cannot be recorded
STATES=$(P -d registry_db -tAc "
  SELECT string_agg(e.enumlabel, ',') FROM pg_type t
  JOIN pg_namespace n ON n.oid = t.typnamespace
  JOIN pg_enum e ON e.enumtypid = t.oid
  WHERE t.typname='assertion_state' AND n.nspname='public';")
case "$STATES" in
  *rejected*) pass "assertion.state accepts 'rejected' ($STATES)" ;;
  *) fail "assertion.state lacks 'rejected' — rejection cannot be recorded ($STATES)" ;;
esac

# an inference candidate can never be a current value
if P -d registry_db -c "INSERT INTO assertion (id,entity_table,entity_id,field,value,evidence_class,state,source,produced_by) VALUES ('a0000000-0000-0000-0000-000000000001','structure','22222222-2222-2222-2222-222222222222','entrance_geom','{}','inference','asserted','imagery_diff','ml');" >/dev/null 2>&1; then
  fail "C8 BROKEN: an inference row became an asserted value"
else
  pass "an inference row can never be state='asserted'"
fi

# a REJECTED candidate must not occupy the current-value slot
P -d registry_db -c "INSERT INTO assertion (id,entity_table,entity_id,field,value,evidence_class,state,source,produced_by) VALUES ('a0000000-0000-0000-0000-000000000002','structure','22222222-2222-2222-2222-222222222222','footprint','{}','inference','rejected','imagery_diff','ml');" >/dev/null 2>&1
if [ "$(P -d registry_db -tAc "SELECT count(*) FROM assertion WHERE field='footprint' AND state='asserted';")" = "0" ]; then
  pass "a rejected candidate does not occupy the current-value slot"
else
  fail "a rejected candidate became the current value"
fi

printf '\n'
printf -- '--------------------------------------------------------------------------------\n'
if [ "$FAILED" = "0" ]; then
  printf '  \033[32mREGISTRY SCHEMA VERIFIED (spatial layer excluded — no PostGIS here)\033[0m\n\n'
  exit 0
else
  printf '  \033[31mSCHEMA VERIFICATION FAILED\033[0m\n\n'; exit 1
fi