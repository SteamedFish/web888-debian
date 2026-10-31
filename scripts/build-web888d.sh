#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# build-web888d.sh — fetch pinned web888-ng v0.6.0 sources and build the
# web888d daemon (static armv7-unknown-linux-musleabihf) plus the web UI
# into work/web888d-build/ (input for scripts/build-web888d-deb.sh).
#
# Inputs:
#   config/web888-ng/pins.env   pinned URLs + SHA256 (refusing to build from
#                               anything else)
#   network                     crates.io / npm registry (via cross's Rust
#                               container and pnpm, both using host caches)
#
# Output:
#   work/web888d-build/bin/web888d      static armhf daemon (from source)
#   work/web888d-build/ui/              built web UI (tsc + esbuild + wasm)
#   work/web888d-build/VERSION          e.g. "0.6.0"
#
# Idempotent: sources are re-verified and re-extracted every run; cargo and
# pnpm caches make rebuilds incremental. Upstream release binaries are never
# used as release inputs (integration plan 2A); the hashes here are the
# source tarball's, not the CI binary's.

set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=../config/web888-ng/pins.env
. config/web888-ng/pins.env

DL=work/web888-ng/downloads
SRC=work/web888-ng/src
OUT=work/web888d-build
TARBALL=$DL/$WEB888_NG_TARBALL
TREE=$SRC/web888-ng-$WEB888_NG_VERSION

fetch() {  # fetch URL DEST
  mkdir -p "$(dirname "$2")"
  if [[ -f $2 ]]; then
    echo "==> have $(basename "$2")"
  else
    echo "==> downloading $1"
    curl -fsSL --retry 3 -o "$2" "$1"
  fi
}

check() {  # check SHA256 FILE
  echo "$1  $2" | sha256sum -c -
}

echo "==> fetching pinned web888-ng v$WEB888_NG_VERSION (commit $WEB888_NG_COMMIT)"
fetch "$WEB888_NG_TARBALL_URL" "$TARBALL"
check "$WEB888_NG_SHA256" "$TARBALL"

echo "==> extracting (fresh every run)"
rm -rf "$SRC"
mkdir -p "$SRC"
tar -xzf "$TARBALL" -C "$SRC"

echo "==> building daemon: cross build armv7-unknown-linux-musleabihf"
command -v cross >/dev/null || { echo "error: cross not installed (cargo install cross)"; exit 1; }
command -v podman >/dev/null || { echo "error: podman not installed"; exit 1; }
(
  cd "$TREE"
  CROSS_CONTAINER_ENGINE=${CROSS_CONTAINER_ENGINE:-podman} \
    cross build --release --target armv7-unknown-linux-musleabihf -p web888d
)
BIN=$TREE/target/armv7-unknown-linux-musleabihf/release/web888d
[[ -x $BIN ]] || { echo "error: build produced no binary at $BIN"; exit 1; }
file "$BIN" | grep -q "ARM.*statically linked" \
  || { echo "error: $BIN is not a static ARM binary:"; file "$BIN"; exit 1; }

echo "==> building the JTTY WebAssembly (ui/wasm/jtty.wasm)"
if ! rustup target list --installed | grep -q '^wasm32-unknown-unknown$'; then
  rustup target add wasm32-unknown-unknown
fi
(
  cd "$TREE"
  cargo build --release --target wasm32-unknown-unknown -p web888-jtty-wasm
  mkdir -p ui/wasm
  cp target/wasm32-unknown-unknown/release/web888_jtty_wasm.wasm ui/wasm/jtty.wasm
)

echo "==> building the web UI"
(
  cd "$TREE/ui"
  pnpm install --frozen-lockfile
  pnpm run build
)
[[ -f $TREE/ui/dist/index.html && -f $TREE/ui/dist/app.js ]] \
  || { echo "error: ui/dist incomplete"; exit 1; }

echo "==> staging $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/ui"
cp "$BIN" "$OUT/bin/web888d"
cp -a "$TREE/ui/dist/." "$OUT/ui/"
echo "$WEB888_NG_VERSION" > "$OUT/VERSION"

echo "==> artifact sentinels"
sha256sum "$OUT/bin/web888d"
find "$OUT/ui" -maxdepth 1 -type f | sort
echo "build-web888d.sh OK"
