#!/usr/bin/env bash
# M0 presentation runner — one command, no arguments needed.
#
#   ./run.sh          full demo (~3 min): setup, verify, all sweeps, verdict
#   ./run.sh quick    ~40 s: verify + headline result only
#   ./run.sh verify   ~10 s: environment check only
#   ./run.sh setup    install dependencies into the local venv
#
# Designed to be run cold on an unfamiliar machine, including a projector.

set -euo pipefail
cd "$(dirname "$0")"

VENV="../.venv-spike"
PY="$VENV/bin/python"
MODE="${1:-full}"

BOLD=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; RST=$'\033[0m'
hr() { printf '%s\n' "────────────────────────────────────────────────────────────────────────"; }

banner() {
  echo
  printf '%s\n' "${BOLD}M0 — PATH-GRAPH FEASIBILITY SPIKE${RST}"
  printf '%s\n' "${DIM}Informal Settlement Address & Emergency Dispatch Registry${RST}"
  hr
}

setup() {
  if [ ! -x "$PY" ]; then
    echo "${DIM}Creating virtualenv…${RST}"
    uv venv "$VENV" --python 3.12 >/dev/null 2>&1 || {
      echo "${RED}uv not found. Install: curl -LsSf https://astral.sh/uv/install.sh | sh${RST}"
      exit 1
    }
  fi
  if ! "$PY" -c "import numpy, scipy, sklearn" >/dev/null 2>&1; then
    echo "${DIM}Installing numpy / scipy / scikit-learn…${RST}"
    uv pip install --python "$PY" numpy scipy scikit-learn >/dev/null
  fi
}

verify() {
  local ok=0 fail=0
  check() { if eval "$2" >/dev/null 2>&1; then echo "  ${GRN}✓${RST} $1"; ok=$((ok+1)); else echo "  ${RED}✗${RST} $1"; fail=$((fail+1)); fi; }
  echo "${BOLD}Environment${RST}"
  check "python ($("$PY" -V 2>&1 | cut -d' ' -f2))"   "[ -x '$PY' ]"
  check "numpy"                                      "$PY -c 'import numpy'"
  check "scipy"                                      "$PY -c 'import scipy'"
  check "scikit-learn"                               "$PY -c 'import sklearn'"
  check "m0 modules"                                 "$PY -c 'import m0_ground_truth,m0_algorithms,m0_evaluate,m0_multiseed'"
  echo "  ${DIM}$ok passed, $fail failed${RST}"
  [ "$fail" -eq 0 ]
}

run_quick() {
  echo; echo "${BOLD}Headline result — 6 seeds, ground truth vs 4 approaches${RST}"
  hr
  "$PY" m0_multiseed.py
}

run_full() {
  run_quick
  echo
  echo "${BOLD}GPS-noise sensitivity — does the verdict survive realistic error?${RST}"
  hr
  "$PY" m0_noise_sweep.py 2>&1 | tail -22
}

verdict() {
  echo
  echo "${BOLD}VERDICT${RST}"
  hr
  cat <<'EOF'
  PRD §6.2 proposed k-means + weighted Delaunay.        → FAILED THE GATE
     regressed destination reachability (0.78 vs 1.00) and routing (0.82 vs 1.00)

  PRD §6.2 excluded seed-and-spline map-matching.       → CONTRADICTED
     excluded for "no spurious-path suppression"; measured spurious-route rate
     0.313, the LOWEST of all four approaches. §6.2 confused edge count
     with spuriousness.

  ADOPTED: hybrid — map-matching backbone + Delaunay restricted to
  proximity-tested, length-capped gap bridging + adaptive density seeding.

  Robustness: same leader at every sigma from 1 m to 12 m. k-means never wins.

  HONEST LIMIT: synthetic traces only. Campus capture not yet in the dataset.
  No field accuracy is claimed. PRD §8's risk is narrowed, not retired.
EOF
}

case "$MODE" in
  setup)  banner; setup; echo "${GRN}Ready. Run: ./run.sh${RST}" ;;
  verify) banner; setup; verify || exit 1 ;;
  quick)  banner; setup; verify || exit 1; run_quick; verdict ;;
  *)      banner; setup; verify || exit 1; run_full; verdict ;;
esac
echo