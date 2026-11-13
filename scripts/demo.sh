#!/usr/bin/env bash
# Demo runner for the PRD 6.8 loop: map -> sync -> code -> lookup -> route -> feedback.
#
#   scripts/demo.sh start      start registry (:8090) + graph service (:8092)
#   scripts/demo.sh rebuild    rebuild the walk graph from synced breadcrumbs
#   scripts/demo.sh seed       no phone: load pre-recorded walks + rebuild (after start)
#   scripts/demo.sh selftest   run the whole loop on throwaway instances (:18090/:18092)
#   scripts/demo.sh stop       stop what `start` started
#
# Env: DB_PATH (default ./demo.db), ZONES_FILE (default config/zones.campus.json)

set -euo pipefail
cd "$(dirname "$0")/.."

ZONES_FILE="${ZONES_FILE:-config/zones.campus.json}"
PIDS=.demo.pids

python_bin() {
  for p in "${PYTHON:-}" .venv-spike/bin/python .venv/bin/python .venv/Scripts/python.exe; do
    if [ -n "$p" ] && [ -x "$p" ]; then echo "$p"; return; fi
  done
  echo "no Python venv with numpy/scipy/scikit-learn found; set PYTHON=" >&2
  exit 1
}

wait_for() {
  for _ in $(seq 1 60); do
    curl -sf "$1" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "timed out waiting for $1" >&2
  return 1
}

# start_services <registry port> <graph port> <db path> <pid file>
start_services() {
  local rport=$1 gport=$2 db=$3 pidf=$4 py
  py=$(python_bin)
  DB_PATH="$db" ZONES_FILE="$ZONES_FILE" GRAPH_URL="http://127.0.0.1:$gport" PORT="$rport" \
    node services/registry-api/src/server.js >"$pidf.registry.log" 2>&1 &
  echo $! >"$pidf"
  REGISTRY_URL="http://127.0.0.1:$rport" PORT="$gport" \
    "$py" services/graph-service/src/server.py >"$pidf.graph.log" 2>&1 &
  echo $! >>"$pidf"
  wait_for "http://127.0.0.1:$rport/v1/sync/health" || { cat "$pidf.registry.log"; stop_services "$pidf"; exit 1; }
  wait_for "http://127.0.0.1:$gport/v1/graph/health" || { cat "$pidf.graph.log"; stop_services "$pidf"; exit 1; }
}

stop_services() {
  local pidf=$1
  [ -f "$pidf" ] || return 0
  while read -r pid; do kill "$pid" 2>/dev/null || true; done <"$pidf"
  rm -f "$pidf" "$pidf.registry.log" "$pidf.graph.log"
}

case "${1:-}" in
  start)
    [ -f services/registry-api/node_modules/qrcode/package.json ] || (cd services/registry-api && npm install --no-audit --no-fund)
    start_services 8090 8092 "${DB_PATH:-./demo.db}" "$PIDS"
    echo "registry http://127.0.0.1:8090  graph http://127.0.0.1:8092"
    echo "App Settings -> Registry API Base URL: http://<this machine's LAN IP>:8090"
    ;;
  rebuild)
    curl -s -X POST http://127.0.0.1:8092/v1/graph/rebuild \
      -H 'Content-Type: application/json' -d '{"source":"registry"}'
    echo
    ;;
  seed)
    # No phone/GPS: load pre-recorded walks into the running demo and rebuild.
    REGISTRY=http://127.0.0.1:8090 GRAPH=http://127.0.0.1:8092 node scripts/demo-selftest.js "$ZONES_FILE" --seed
    ;;
  selftest)
    st=.demo-selftest.pids
    trap 'stop_services "$st"' EXIT
    start_services 18090 18092 ":memory:" "$st"
    REGISTRY=http://127.0.0.1:18090 GRAPH=http://127.0.0.1:18092 node scripts/demo-selftest.js "$ZONES_FILE"
    ;;
  stop)
    stop_services "$PIDS"
    ;;
  *)
    sed -n '2,10p' "$0"
    exit 1
    ;;
esac
