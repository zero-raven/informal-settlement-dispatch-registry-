#!/usr/bin/env bash
# Install PostGIS into a local, unprivileged prefix — no root, no Docker.
#
# Why this exists: the authoring machine is Arch Linux with pacman but no
# passwordless sudo and no Docker, so PostGIS could not be installed and the
# spatial layer of the registry schema stayed unverified. This script resolves
# that by downloading the official Arch package and pointing the server at it
# via two supported configuration knobs:
#
#   dynamic_library_path   -> find postgis-3.so
#   extension_control_path -> find postgis.control and the versioned SQL
#
# Both are read-only paths; nothing is written outside this repo's cache dir.
#
#   ./scripts/setup-postgis.sh            # install into .pgroot
#   ./scripts/setup-postgis.sh --verify   # install, then run 001_postgis_verify.sql

set -uo pipefail
cd "$(dirname "$0")/.."

PREFIX="$PWD/.pgroot"
CACHE="$PWD/.cache/pkg"
# Binaries may be in a versioned dir or flat in /usr/bin (Arch splits only
# lib/ and pgxs/). Resolve from the binary itself rather than guessing.
if command -v pg_config >/dev/null 2>&1; then
  PGVER="$(pg_config --version 2>/dev/null | awk '{print $2}')"
fi
PGVER="${PGVER:-unknown}"

BOLD=$'\033[1m'; GRN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$1"; exit 1; }
info() { printf '  %s·%s %s\n' "$DIM" "$RST" "$1"; }

say ""
say "${BOLD}PostGIS setup (no root, no Docker)${RST}"
say "────────────────────────────────────────────────────────────────────────"

command -v psql >/dev/null 2>&1 || bad "psql not found — install postgresql first"
info "PostgreSQL $PGVER"

mkdir -p "$CACHE" "$PREFIX"

# ---- fetch the official Arch package --------------------------------------
if [ ! -f "$PREFIX/usr/lib/postgresql/postgis-3.so" ]; then
  if [ ! -f "$CACHE/postgis.pkg.tar.zst" ]; then
    URL="$(pacman -Sp postgis 2>/dev/null | head -1)"
    [ -n "$URL" ] || bad "cannot resolve postgis package URL (pacman -Sp failed)"
    info "downloading $(basename "$URL")"
    command -v curl >/dev/null 2>&1 || bad "curl required"
    curl -fsSL "$URL" -o "$CACHE/postgis.pkg.tar.zst" || bad "download failed"
  fi
  info "extracting into $PREFIX"
  tar --zstd -xf "$CACHE/postgis.pkg.tar.zst" -C "$PREFIX" 2>/dev/null \
    || zstd -dc "$CACHE/postgis.pkg.tar.zst" | tar -xf - -C "$PREFIX" \
    || bad "extract failed"
fi

[ -f "$PREFIX/usr/lib/postgresql/postgis-3.so" ] || bad "postgis-3.so missing after extract"
ok "postgis-3.so present"

# ---- build a private sharedir holding BOTH system and postgis extensions ---
#
# PostgreSQL resolves extension_control_path against the PARENT directory that
# contains extension subdirectories — pointing it at .../extension directly
# makes every extension undiscoverable. Hence $PREFIX/share holding extension/.
SHARE="$PREFIX/share"
mkdir -p "$SHARE/extension"
cp -r /usr/share/postgresql/extension/* "$SHARE/extension/" 2>/dev/null
cp -r "$PREFIX/usr/share/postgresql/extension/"* "$SHARE/extension/" 2>/dev/null
[ -f "$SHARE/extension/postgis.control" ] || bad "postgis.control missing from private sharedir"
ok "private sharedir: $(ls "$SHARE/extension"/*.control 2>/dev/null | wc -l) control files"

cat > "$PREFIX/postgis.conf" <<EOF
# Append to a cluster's postgresql.conf to enable this PostGIS build.
dynamic_library_path = '\$libdir:$PREFIX/usr/lib/postgresql'
extension_control_path = '$SHARE'
EOF
ok "config fragment: $PREFIX/postgis.conf"

if [ "${1:-}" = "--verify" ]; then
  say ""
  say "${BOLD}Running the spatial verification migration${RST}"
  POSTGIS_PREFIX="$PREFIX" ./scripts/postgis-verify.sh || exit 1
fi

say ""
say "${GRN}PostGIS available unprivileged.${RST} Add this to a cluster config:"
say "  ${DIM}cat \$PWD/.pgroot/postgis.conf >> \$PGDATA/postgresql.conf${RST}"
say ""