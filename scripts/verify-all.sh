#!/usr/bin/env bash
# Run every automated check in the repository.
#
#   ./scripts/verify-all.sh
#
# Each section is a constraint test, not a smoke test: it asserts something the
# PRD requires, and it fails if the implementation drifts from it.
# Requires node. The Python, Postgres, PostGIS and Flutter sections run when
# those tools are present and are skipped (not failed) otherwise.

set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=0
BOLD=$'\033[1m'; GRN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'

section() { printf '\n%s▌ %s%s\n' "$BOLD" "$1" "$RST"; }
ok()      { printf '  %s✓%s %s\n' "$GRN" "$RST" "$1"; }
bad()     { printf '  %s✗%s %s\n' "$RED" "$RST" "$1"; FAILED=1; }
skip()    { printf '  %s—%s %s\n' "$DIM" "$RST" "$1"; }
# "tests 113 pass 112" from node --test output
node_summary() { printf '%s' "$1" | grep -oE '(tests|pass|fail) [0-9]+' | tr '\n' ' '; }

# Python venv: first one found (README "Setup" creates .venv).
PY=""
for p in "${PYTHON:-}" .venv/bin/python .venv/Scripts/python.exe .venv-spike/bin/python; do
  if [ -n "$p" ] && [ -x "$p" ]; then PY="$p"; break; fi
done
# Postgres binaries may live in a versioned dir.
if ! command -v initdb >/dev/null 2>&1; then
  PGBIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
  [ -n "$PGBIN" ] && export PATH="$PGBIN:$PATH"
fi
HAS_PG=0
command -v initdb >/dev/null 2>&1 && command -v psql >/dev/null 2>&1 && HAS_PG=1
# Flutter on PATH, or the repo-local SDK from scripts/setup-flutter.sh.
[ -d .cache/flutter/bin ] && export PATH="$PWD/.cache/flutter/bin:$PATH"
HAS_FLUTTER=0
command -v flutter >/dev/null 2>&1 && HAS_FLUTTER=1
TIMEOUT=""
command -v timeout >/dev/null 2>&1 && TIMEOUT="timeout 300"

printf '%s\n' "${BOLD}Informal Settlement Registry — verification${RST}"
printf '%s\n' "${DIM}C1 identity · C3 isolation · C8 evidence · offline operation${RST}"

# ---------------------------------------------------------------- sync-core
section "M1 sync-core constraint tests"
if out=$(cd packages/sync-core && node --test test/*.test.js 2>&1); then
  ok "$(node_summary "$out")"
else
  bad "sync-core tests failed"
  printf '%s\n' "$out" | grep -E '✖|not ok' | head -10 | sed 's/^/      /'
fi

# ------------------------------------------------------------ registry schema
section "M1 registry schema + C8/C1 invariants"
if [ "$HAS_PG" = 0 ]; then
  skip "Postgres (initdb/psql) absent"
elif out=$(./scripts/registry-schema-test.sh 2>&1); then
  ok "$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -c '✓' | xargs -I{} echo '{} assertions passed')"
else
  bad "registry schema verification failed"
  printf '%s\n' "$out" | grep -E '✗' | head -12 | sed 's/^/      /'
fi

# --------------------------------------------------------------- C3 isolation
section "M1 identity isolation (C3)"
if [ "$HAS_PG" = 0 ]; then
  skip "Postgres (initdb/psql) absent"
elif out=$(./scripts/c3-isolation-test.sh 2>&1); then
  ok "$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -c '✓' | xargs -I{} echo '{} assertions passed')"
else
  bad "C3 isolation FAILED — identity is reachable from the registry"
  printf '%s\n' "$out" | grep -E '✗' | head -12 | sed 's/^/      /'
fi

# -------------------------------------------------------------- M2 registry
section "M2 registry, sync, dedup, QR"
if out=$(cd services/registry-api && node --test test/*.test.js 2>&1); then
  ok "$(node_summary "$out")"
else
  bad "registry-api tests failed"
  printf '%s\n' "$out" | grep -E '✖' | head -10 | sed 's/^/      /'
fi

# ---------------------------------------------------------------- M3 graph
section "M3 path graph (M0 hybrid) + routing"
if [ -n "$PY" ]; then
  if out=$("$PY" -m pytest services/graph-service/test/ -q 2>&1); then
    ok "$(printf '%s' "$out" | tail -1 | sed 's/^/hybrid + routing + cross-service dispatch E2E: /')"
  else
    bad "M3 graph tests failed"
    printf '%s\n' "$out" | grep -E 'FAILED|Error' | head -8 | sed 's/^/      /'
  fi
else
  skip "Python venv absent; see README Setup"
fi

# --------------------------------------------------------------- PostGIS layer
section "M1 spatial layer (PostGIS)"
if [ -f "$PWD/.pgroot/postgis.conf" ]; then
  if out=$(./scripts/postgis-verify.sh 2>&1); then
    ok "$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -c '✓' | xargs -I{} echo '{} spatial assertions on real PostGIS')"
  else
    bad "PostGIS verification failed"
    printf '%s\n' "$out" | grep '✗' | head -10 | sed 's/^/      /'
  fi
else
  skip "PostGIS absent; run: ./scripts/setup-postgis.sh"
fi

# ------------------------------------------------------- M5 feedback engine
section "M5 feedback / re-verification engine"
if out=$(cd services/registry-api && node --test test/feedback.test.js 2>&1); then
  ok "$(node_summary "$out")"
else
  bad "feedback engine tests failed"
  printf '%s\n' "$out" | grep -E '✖' | head -8 | sed 's/^/      /'
fi

# ------------------------------------------------- M6 disclosure + consent
section "M6 service-data disclosure (6.6)"
if out=$(cd services/registry-api && node --test test/disclosure.test.js 2>&1); then
  ok "$(node_summary "$out")"
else
  bad "disclosure tests failed"
  printf '%s\n' "$out" | grep -E '✖' | head -8 | sed 's/^/      /'
fi

section "M6 consent vault (6.3) + occupant bridge"
if out=$(cd services/consent-api && node --test test/*.test.js 2>&1); then
  ok "$(node_summary "$out")"
else
  bad "consent tests failed"
  printf '%s\n' "$out" | grep -E '✖' | head -8 | sed 's/^/      /'
fi

# ----------------------------------------------- unified app (mapper + dispatcher)
section "Unified app (offline capture + dispatch)"
if [ "$HAS_FLUTTER" = 1 ]; then
  if out=$(cd apps/dispatcher && $TIMEOUT flutter test --reporter compact 2>&1); then
    ok "$(printf '%s' "$out" | tr '\r' '\n' | grep -oE '\+[0-9]+(: All tests passed!)?' | tail -1 | sed 's/^/tests /')"
  else
    bad "unified app tests failed"
    printf '%s\n' "$out" | tail -12 | sed 's/^/      /'
  fi
else
  skip "Flutter SDK absent; run: ./scripts/setup-flutter.sh"
fi

# ------------------------------------------------------------------- M0 spike
section "M0 path-graph spike regression"
if [ -n "$PY" ]; then
  if out=$(cd spike && "../$PY" m0_multiseed.py 2>&1); then
    ok "4 approaches re-scored over 6 seeds"
  else
    bad "M0 spike failed"
  fi
else
  skip "Python venv absent; see README Setup"
fi

# ---------------------------------------------------------- demo loop (E2E)
section "Demo loop: map -> sync -> code -> lookup -> route -> feedback"
if [ -n "$PY" ]; then
  if out=$(PYTHON="$PY" bash scripts/demo.sh selftest 2>&1); then
    ok "$(printf '%s' "$out" | tail -1)"
  else
    bad "demo selftest failed"
    printf '%s\n' "$out" | grep -E 'FAIL' | head -5 | sed 's/^/      /'
  fi
else
  skip "Python venv absent; see README Setup"
fi

# ------------------------------------------------------------------- summary
printf '\n%s────────────────────────────────────────%s\n' "$DIM" "$RST"
if [ "$FAILED" = "0" ]; then
  printf '%s  ALL CHECKS PASSED%s\n\n' "$GRN" "$RST"
else
  printf '%s  FAILURES ABOVE — do not present as verified%s\n\n' "$RED" "$RST"
fi
exit "$FAILED"
