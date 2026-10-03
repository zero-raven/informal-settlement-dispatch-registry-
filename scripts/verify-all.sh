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
if out=$(cd packages/sync-core && node --test test/ 2>&1); then
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