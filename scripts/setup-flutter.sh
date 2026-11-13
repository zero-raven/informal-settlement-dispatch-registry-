#!/usr/bin/env bash
# Install the Flutter SDK into .cache/ — no root, no system install.
#
# Why: the authoring machine had no Flutter SDK, so the mapper app could not be
# built or tested. This fetches the official stable tarball into the repo cache.
#
#   ./scripts/setup-flutter.sh
#   FLUTTER_VERSION=3.27.1 ./scripts/setup-flutter.sh

set -uo pipefail
cd "$(dirname "$0")/.."

VERSION="${FLUTTER_VERSION:-3.50.0}"
CACHE="$PWD/.cache"
ROOT="$CACHE/flutter"

BOLD=$'\033[1m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'

printf '\n%sFlutter setup (no root)%s\n' "$BOLD" "$RST"
printf '%s────────────────────────────────────────────────────────────────────────%s\n' "$DIM" "$RST"

if [ -x "$ROOT/bin/flutter" ]; then
  printf '  %s✓%s already installed: %s\n' "$GRN" "$RST" "$("$ROOT/bin/flutter" --version 2>/dev/null | head -1)"
  exit 0
fi

mkdir -p "$CACHE"
TARBALL="$CACHE/flutter.tar.xz"
URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${VERSION}-stable.tar.xz"

if [ ! -f "$TARBALL" ]; then
  printf '  · downloading Flutter %s (~700 MB)\n' "$VERSION"
  curl -fsSL "$URL" -o "$TARBALL" || { echo "download failed"; exit 1; }
fi

printf '  · extracting\n'
tar -xf "$TARBALL" -C "$CACHE" || { echo "extract failed"; exit 1; }

# Flutter refuses to run against a directory git does not own.
git config --global --add safe.directory "$ROOT" 2>/dev/null

printf '  %s✓%s %s\n' "$GRN" "$RST" "$("$ROOT/bin/flutter" --version 2>/dev/null | head -1)"
printf '\n  add to PATH:  export PATH="%s/bin:$PATH"\n\n' "$ROOT"
