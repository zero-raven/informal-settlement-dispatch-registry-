#!/usr/bin/env bash
# Run migrations/001_postgis_verify.sql against a real PostGIS instance.
#
# This closes the gap recorded in docs/database.md 5: the spatial layer
# (typmods, gist indexes, ST_Contains zone containment, tstzrange supply hours)
# was previously unverified because PostGIS could not be installed on the
# authoring machine. scripts/setup-postgis.sh installs it unprivileged.
#
#   ./scripts/setup-postgis.sh --verify     # recommended
#   ./scripts/postgis-verify.sh              # if already installed

set -uo pipefail
cd "$(dirname "$0")/.."

PREFIX="${POSTGIS_PREFIX:-$PWD/.pgroot}"
SHARE="$PREFIX/share"
SOCK="${TMPDIR:-/tmp}/pgis-$$"
DATADIR="$(mktemp -d "${TMPDIR:-/tmp}/pgisdata-XXXX")"

BOLD=$'\033[1m'; GRN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
pass() { printf '  %s✓%s %s\n' "$GRN" "$RST" "$1"; }
fail() { printf '  %s✗%s %s\n' "$RED" "$RST" "$1"; FAILED=1; }
FAILED=0

cleanup() { pg_ctl -D "$DATADIR" -m immediate stop >/dev/null 2>&1; rm -rf "$DATADIR" "$SOCK"; }
trap cleanup EXIT

# ensure the server binaries are on PATH (Arch keeps them in /usr/bin, but a
# versioned layout is common elsewhere)
if ! command -v psql >/dev/null 2>&1; then
  PGBIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
  [ -n "$PGBIN" ] && export PATH="$PGBIN:$PATH"
fi
command -v psql >/dev/null 2>&1 || { echo "psql not found"; exit 1; }
[ -f "$PREFIX/usr/lib/postgresql/postgis-3.so" ] || {
  echo "PostGIS not installed at $PREFIX — run ./scripts/setup-postgis.sh"; exit 1; }

say() { printf '\n%s\n' "$*"; }

printf '\n%sPostGIS spatial verification%s\n' "$BOLD" "$RST"
printf '%s────────────────────────────────────────────────────────────────────────%s\n' "$DIM" "$RST"

# ---- cluster ---------------------------------------------------------------
mkdir -p "$SOCK"
initdb -D "$DATADIR" -U postgres --auth=trust >/dev/null 2>&1 || { echo "initdb failed"; exit 1; }
# The socket dir must be OUTSIDE the data dir, and the two config lines below
# must be written before start.
# unix-socket only: never binds a TCP port, so this cannot collide with a real
# cluster or a stray server left behind by another run
cat "$PREFIX/postgis.conf" >> "$DATADIR/postgresql.conf"
printf "listen_addresses = ''\n" >> "$DATADIR/postgresql.conf"
pg_ctl -D "$DATADIR" -o "-k $SOCK -p 5770" -l "$DATADIR/pg.log" start >/dev/null 2>&1
for _ in $(seq 1 30); do psql -h "$SOCK" -p 5770 -U postgres -c "SELECT 1;" >/dev/null 2>&1 && break; sleep 0.3; done
# A dead server makes every negative check pass vacuously. Refuse to continue.
psql -h "$SOCK" -p 5770 -U postgres -c "SELECT 1;" >/dev/null 2>&1 || {
  echo "server failed to start:"; tail -8 "$DATADIR/pg.log"; exit 1; }

P() { psql -h "$SOCK" -p 5770 -U postgres -v ON_ERROR_STOP=1 "$@"; }

say "${BOLD}1. PostGIS is real and loadable${RST}"
# The functions only exist once the extension is installed in the database, so
# create it BEFORE asking for its version.
if P -c "CREATE EXTENSION IF NOT EXISTS postgis;" >/tmp/pgis-ext.log 2>&1; then
  pass "CREATE EXTENSION postgis succeeded (no shim, no root)"
else
  fail "postgis extension could not be created:"; head -4 /tmp/pgis-ext.log | sed 's/^/      /'; exit 1
fi
VER=$(P -tAc "SELECT postgis_version();" 2>/dev/null | head -1)
if [ -n "$VER" ]; then pass "postgis_version: $VER"; else fail "postgis_version unavailable"; exit 1; fi
GEOS=$(P -tAc "SELECT postgis_geos_version();" 2>/dev/null | head -1)
[ -n "$GEOS" ] && pass "GEOS: $GEOS" || info "GEOS version not reported (optional)"

P -c "CREATE DATABASE registry_db;" >/dev/null 2>&1
P -d registry_db -c "CREATE EXTENSION IF NOT EXISTS postgis;" >/dev/null 2>&1

say "${BOLD}2. The migration applies with REAL PostGIS types${RST}"
if OUT=$(P -d registry_db -f services/registry-api/migrations/000_init.sql 2>&1); then
  pass "000_init.sql applies cleanly — no shim, no typmod stripping"
else
  fail "migration failed:"; printf '%s\n' "$OUT" | grep ERROR | head -10 | sed 's/^/      /'
fi

CNT=$(P -d registry_db -tAc "SELECT count(*) FROM pg_class WHERE relkind='r' AND relnamespace='public'::regnamespace;")
[ "${CNT:-0}" -ge 16 ] && pass "$CNT tables created" || fail "only $CNT tables"

say "${BOLD}3. Spatial types, indexes and functions${RST}"
# geometry typmods survived (this is what the text-domain shim could NOT prove)
# counted from the catalogue, so a spatial column added later cannot slip past
TYPMODS=$(P -d registry_db -tAc "
  SELECT count(*) FROM information_schema.columns
  WHERE table_schema='public' AND udt_name='geometry';")
[ "${TYPMODS:-0}" -ge 9 ] && pass "$TYPMODS spatial columns are real PostGIS geometry" \
                           || fail "only $TYPMODS geometry columns found (expected >= 9)"

GIST=$(P -d registry_db -tAc "SELECT count(*) FROM pg_indexes WHERE indexdef ILIKE '%USING gist%';")
[ "${GIST:-0}" -ge 6 ] && pass "$GIST gist spatial indexes created" || fail "only $GIST gist indexes"

RANGE=$(P -d registry_db -tAc "
  SELECT t.typname FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_type t ON t.oid = a.atttypid
  WHERE c.relname='structure_service' AND a.attname='supply_hours';")
[ "${RANGE:-}" = "tstzrange" ] && pass "supply_hours is a real tstzrange" || fail "supply_hours is ${RANGE:-missing}"

say "${BOLD}4. The spatial verification migration${RST}"
if OUT=$(P -d registry_db -f services/registry-api/migrations/001_postgis_verify.sql 2>&1); then
  pass "001_postgis_verify.sql passed"
  printf '%s\n' "$OUT" | grep -o 'NOTICE:  POSTGIS VERIFICATION PASSED[^\n]*' | sed 's/^/      /'
else
  fail "spatial verification FAILED:"
  printf '%s\n' "$OUT" | grep -E 'ERROR|NOTICE' | head -8 | sed 's/^/      /'
fi

say "${BOLD}5. C7 — zone containment gates dispatch${RST}"
Z=$(P -d registry_db -tAc "SELECT id FROM zone WHERE code='C4';")
P -d registry_db -c "
  UPDATE zone SET boundary = ST_Multi(ST_MakePolygon(ST_MakeLine(ARRAY[
    ST_MakePoint(-100,-100), ST_MakePoint(200,-100), ST_MakePoint(200,260),
    ST_MakePoint(-100,260), ST_MakePoint(-100,-100)]))) WHERE id=$Z;" >/dev/null 2>&1
INS=$(P -d registry_db -tAc "SELECT ST_Contains((SELECT boundary FROM zone WHERE id=$Z), ST_SetSRID(ST_MakePoint(50,100),4326));")
OUT=$(P -d registry_db -tAc "SELECT ST_Contains((SELECT boundary FROM zone WHERE id=$Z), ST_SetSRID(ST_MakePoint(999,999),4326));")
[ "$INS" = "t" ] && pass "a structure inside the pilot zone is contained" || fail "interior point not contained (got '$INS')"
[ "$OUT" = "f" ] && pass "a structure outside the pilot zone is NOT contained (dispatch blocked)" \
                || fail "exterior point contained — C7 BROKEN (got '$OUT')"

say "${BOLD}6. C8 — inference still cannot overwrite ground truth${RST}"
P -d registry_db -c "INSERT INTO app_user (id,email,role) VALUES ('11111111-1111-1111-1111-111111111111','m@t','mapper');" >/dev/null 2>&1
P -d registry_db -c "INSERT INTO structure (id,created_by,centroid) VALUES ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111', ST_SetSRID(ST_MakePoint(12.97,77.59),4326));" >/dev/null 2>&1
P -d registry_db -c "INSERT INTO assertion (entity_table,entity_id,field,value,evidence_class,state,source,observed_by,observed_at) VALUES ('structure','22222222-2222-2222-2222-222222222222','centroid','{\"lat\":12.97}','ground_truth','asserted','mapper_survey','mapper:4f2a',now());" >/dev/null 2>&1
[ "$(P -d registry_db -tAc "SELECT count(*) FROM assertion WHERE state='asserted';" 2>/dev/null)" = "1" ] \
  && pass "a mapper ground-truth assertion is accepted" || fail "could not create ground truth"

if P -d registry_db -c "UPDATE assertion SET evidence_class='inference', state='asserted', source='imagery_diff', observed_by=NULL, observed_at=NULL WHERE field='centroid';" >/dev/null 2>&1; then
  fail "C8 BROKEN: inference overwrote ground truth"
else
  pass "inference CANNOT overwrite ground truth (TRIGGER)"
fi
REMAIN=$(P -d registry_db -tAc "SELECT value::text FROM assertion WHERE field='centroid' AND state='asserted';")
[ "$REMAIN" = '{"lat": 12.97}' ] && pass "ground truth intact: $REMAIN" || fail "ground truth altered: $REMAIN"

say "${BOLD}7. PRD 6.6 — the aggregate view exposes no per-structure column${RST}"
LEAK=$(P -d registry_db -tAc "
  SELECT count(*) FROM information_schema.columns
  WHERE table_name='v_zone_service_stats'
    AND column_name IN ('structure_id','code','centroid','geom','id');")
[ "${LEAK:-0}" = "0" ] && pass "no per-structure column is projected" || fail "REPORTING LEAK: $LEAK column(s)"
ROWS=$(P -d registry_db -tAc "SELECT count(*) FROM v_zone_service_stats;" 2>/dev/null || echo 0)
pass "aggregate view executes against real PostGIS ($ROWS row(s) on empty data)"

say "${BOLD}8. A real geometry round-trips through the schema${RST}"
P -d registry_db -c "UPDATE structure SET footprint = ST_GeomFromText('POLYGON((77.59 12.97, 77.60 12.97, 77.60 12.98, 77.59 12.98, 77.59 12.97))',4326) WHERE id='22222222-2222-2222-2222-222222222222';" >/dev/null 2>&1
AREA=$(P -d registry_db -tAc "SELECT round(ST_Area(footprint)::numeric,8) FROM structure WHERE id='22222222-2222-2222-2222-222222222222';" 2>/dev/null)
[ -n "$AREA" ] && pass "polygon stored and measured by PostGIS (area=$AREA deg²)" || fail "footprint geometry unusable"
GIX=$(P -d registry_db -tAc "SELECT ST_Intersects(footprint, ST_SetSRID(ST_MakePoint(77.595,12.975),4326)) FROM structure WHERE id='22222222-2222-2222-2222-222222222222';" 2>/dev/null)
[ "$GIX" = "t" ] && pass "spatial predicate works against a stored footprint" || fail "ST_Intersects returned '$GIX'"

printf '\n%s────────────────────────────────────────────────────────────────────────%s\n' "$DIM" "$RST"
if [ "$FAILED" = "0" ]; then
  printf '  %sSPATIAL LAYER VERIFIED — docs/database.md 5 blocker is closed%s\n\n' "$GRN" "$RST"
  exit 0
else
  printf '  %sSPATIAL VERIFICATION FAILED — blocker remains open%s\n\n' "$RED" "$RST"
  exit 1
fi