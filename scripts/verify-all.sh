#!/usr/bin/env bash
# Run every automated check in the repository.
#
#   ./scripts/verify-all.sh
#
# Each section is a constraint test, not a smoke test: it asserts something the
# PRD requires, and it fails if the implementation drifts from it.
# Requires only node and postgres (no PostGIS, no Docker, no Flutter).

set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=0
BOLD=$'\033[1m'; GRN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'

section() { printf '\n%s▌ %s%s\n' "$BOLD" "$1" "$RST"; }
ok()      { printf '  %s✓%s %s\n' "$GRN" "$RST" "$1"; }
bad()     { printf '  %s✗%s %s\n' "$RED" "$RST" "$1"; FAILED=1; }

printf '%s\n' "${BOLD}Informal Settlement Registry — verification${RST}"
printf '%s\n' "${DIM}C1 identity · C3 isolation · C8 evidence · offline operation${RST}"

# ---------------------------------------------------------------- sync-core
section "M1 sync-core constraint tests"
if out=$(cd packages/sync-core && node --test test/*.test.js 2>&1); then
  ok "$(printf '%s' "$out" | grep -E '^. (pass|tests) ' | tr '\n' ' ')"
else
  bad "sync-core tests failed"
  printf '%s\n' "$out" | grep -E '✖|not ok' | head -10 | sed 's/^/      /'
fi

# ------------------------------------------------------------ registry schema
section "M1 registry schema + C8/C1 invariants"
if out=$(./scripts/registry-schema-test.sh 2>&1); then
  ok "$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -c '✓' | xargs -I{} echo '{} assertions passed')"
else
  bad "registry schema verification failed"
  printf '%s\n' "$out" | grep -E '✗' | head -12 | sed 's/^/      /'
fi

# --------------------------------------------------------------- C3 isolation
section "M1 identity isolation (C3)"
if out=$(./scripts/c3-isolation-test.sh 2>&1); then
  ok "$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -c '✓' | xargs -I{} echo '{} assertions passed')"
else
  bad "C3 isolation FAILED — identity is reachable from the registry"
  printf '%s\n' "$out" | grep -E '✗' | head -12 | sed 's/^/      /'
fi

# -------------------------------------------------------------- M2 registry
section "M2 registry, sync, dedup, QR"
if out=$(cd services/registry-api && node --test test/*.test.js 2>&1); then
  ok "$(printf '%s' "$out" | grep -E '^. (tests|pass) ' | tr '\n' ' ')"
else
  bad "registry-api tests failed"
  printf '%s\n' "$out" | grep -E '✖' | head -10 | sed 's/^/      /'
fi

# ---------------------------------------------------------------- M3 graph
section "M3 path graph (M0 hybrid) + routing"
if [ -x .venv-spike/bin/python ]; then
  if out=$(.venv-spike/bin/python -m pytest services/graph-service/test/ -q 2>&1); then
    ok "$(printf '%s' "$out" | tail -1 | sed 's/^/hybrid + routing + cross-service dispatch E2E: /')"
  else
    bad "M3 graph tests failed"
    printf '%s\n' "$out" | grep -E 'FAILED|Error' | head -8 | sed 's/^/      /'
  fi
else
  printf '  %s—%s spike venv absent; run: cd spike && ./run.sh setup\n' "$DIM" "$RST"
fi

# ------------------------------------------------------------- M4 dispatcher
section "M4 dispatcher app"
if [ -d .cache/flutter ]; then
  export PATH="$PWD/.cache/flutter/bin:$PATH"
  if out=$(cd apps/dispatcher && timeout 300 flutter test --reporter compact 2>&1); then
    ok "$(printf '%s' "$out" | tr '\r' '\n' | grep -oE '\+[0-9]+: All tests passed!' | tail -1 | sed 's/^/dispatcher UI /')"
  else
    bad "dispatcher tests failed"
    printf '%s\n' "$out" | tail -10 | sed 's/^/      /'
  fi
else
  printf '  %s—%s Flutter SDK absent\n' "$DIM" "$RST"
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
  printf '  %s—%s PostGIS absent; run: ./scripts/setup-postgis.sh\n' "$DIM" "$RST"
fi

# ------------------------------------------------------- M5 feedback engine
section "M5 feedback / re-verification engine"
if out=$(cd services/registry-api && node --test test/feedback.test.js 2>&1); then
  ok "$(printf '%s' "$out" | grep -E '^. (tests|pass) ' | tr '\n' ' ')"
else
  bad "feedback engine tests failed"
  printf '%s\n' "$out" | grep -E '✖' | head -8 | sed 's/^/      /'
fi

# ------------------------------------------------- M6 disclosure + consent
section "M6 service-data disclosure (6.6)"
if out=$(cd services/registry-api && node --test test/disclosure.test.js 2>&1); then
  ok "$(printf '%s' "$out" | grep -E '^. (tests|pass) ' | tr '\n' ' ')"
else
  bad "disclosure tests failed"
  printf '%s\n' "$out" | grep -E '✖' | head -8 | sed 's/^/      /'
fi

section "M6 consent vault (6.3) + occupant bridge"
if out=$(cd services/consent-api && node --test test/*.test.js 2>&1); then
  ok "$(printf '%s' "$out" | grep -E '^. (tests|pass) ' | tr '\n' ' ')"
else
  bad "consent tests failed"
  printf '%s\n' "$out" | grep -E '✖' | head -8 | sed 's/^/      /'
fi

# ----------------------------------------------------------------- unified app (mapper + dispatcher)
section "Unified app (offline capture + dispatch)"
if [ -d .cache/flutter ]; then
  export PATH="$PWD/.cache/flutter/bin:$PATH"
  if out=$(cd apps/dispatcher && timeout 300 flutter test --reporter compact 2>&1); then
    ok "$(printf '%s' "$out" | tr '\r' '\n' | grep -oE '\+[0-9]+(: All tests passed!)?' | tail -1 | sed 's/^/tests /')"
  else
    bad "unified app tests failed"
    printf '%s\n' "$out" | tail -12 | sed 's/^/      /'
  fi
else
  printf '  %s—%s Flutter SDK absent; run: ./scripts/setup-flutter.sh\n' "$DIM" "$RST"
fi

# ------------------------------------------------------------------- M0 spike
section "M0 path-graph spike regression"
if [ -x .venv-spike/bin/python ]; then
  if out=$(cd spike && ../.venv-spike/bin/python m0_multiseed.py 2>&1); then
    ok "4 approaches re-scored over 6 seeds"
  else
    bad "M0 spike failed"
  fi
else
  printf '  %s—%s spike venv absent; run: cd spike && ./run.sh setup\n' "$DIM" "$RST"
fi

# ------------------------------------------------------------------- summary
printf '\n%s────────────────────────────────────────%s\n' "$DIM" "$RST"
if [ "$FAILED" = "0" ]; then
  printf '%s  ALL CHECKS PASSED%s\n\n' "$GRN" "$RST"
else
  printf '%s  FAILURES ABOVE — do not present as verified%s\n\n' "$RED" "$RST"
fi
exit "$FAILED"