#!/usr/bin/env bash
# fetch-upstream-src.sh — clone the pinned upstream source tree for the
# websdr (step 3) / redpitaya (step 4) component into work/<name>-src when
# it is missing.
#
# build-websdr-deb.sh / build-redpitaya.sh require a git checkout of the
# pinned upstream tree and refuse to run without it; they verify HEAD against
# config/<name>/upstream.pin themselves. This helper closes the from-scratch
# gap: build-all.sh calls it before those steps so a fresh checkout builds
# unattended. Idempotent — a tree already at the pinned commit is left
# untouched (a tree at a DIFFERENT commit is an error, not silently
# rewritten; resolve by hand).
#
# Clone strategy: shallow fetch of the pinned commit by SHA (GitHub allows
# fetching any reachable commit; same shallow pattern as the bootgen /
# linux-xlnx clones in build-all.sh) — full history is never needed for a
# build input. websdr additionally gets its pinned submodules (recorded as
# `submodule: <path> <sha>` lines in the pin file) initialised and verified.
#
# Usage: fetch-upstream-src.sh websdr|redpitaya
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    websdr|redpitaya) NAME=$1 ;;
    *) echo "usage: $0 websdr|redpitaya" >&2; exit 2 ;;
esac

PIN=config/$NAME/upstream.pin
SRC=work/$NAME-src

URL=$(awk '/^url: /{print $2; exit}' "$PIN")
COMMIT=$(awk '/^commit: /{print $2; exit}' "$PIN")
[[ -n $URL && -n $COMMIT ]] || { echo "error: $PIN lacks url:/commit:" >&2; exit 1; }

if [[ -d $SRC/.git ]]; then
    cur=$(git -C "$SRC" rev-parse HEAD)
    if [[ $cur == "$COMMIT" ]]; then
        echo "==> $SRC already at pinned commit ${COMMIT:0:12} — nothing to do"
        exit 0
    fi
    echo "error: $SRC exists but HEAD is $cur, pin says $COMMIT" >&2
    echo "       resolve manually — refusing to rewrite an existing tree" >&2
    exit 1
fi

echo "==> cloning pinned $NAME upstream: $URL @ ${COMMIT:0:12}"
mkdir --parents "$SRC"
git -C "$SRC" init -q
git -C "$SRC" remote add origin "$URL"
git -C "$SRC" fetch -q --depth 1 origin "$COMMIT"
git -C "$SRC" checkout -q FETCH_HEAD

# Shallow-by-SHA fetch and `submodule update --depth 1` both rely on the
# server allowing want-by-sha (GitHub does). dumphfdl is large; if a moved
# gitlink ever breaks the shallow fetch, drop --depth 1 or clone the
# submodule URL directly.

# Pinned submodules (websdr: externals/dumphfdl, pkgs/jsmn, pkgs/utf8).
# `submodule update` fetches the gitlink-recorded commit; verify each against
# the pin afterwards so upstream retargeting a gitlink is caught here rather
# than as a build error deep inside the chroot.
mapfile -t SUBS < <(awk '/^submodule: /{print $2, $3}' "$PIN")
if ((${#SUBS[@]})); then
    paths=()
    for s in "${SUBS[@]}"; do paths+=("${s%% *}"); done
    git -C "$SRC" submodule update --init --depth 1 -- "${paths[@]}"
    for s in "${SUBS[@]}"; do
        path=${s%% *} want=${s##* }
        got=$(git -C "$SRC/$path" rev-parse HEAD)
        [[ $got == "$want" ]] || {
            echo "error: submodule $path at $got, pin says $want" >&2; exit 1
        }
    done
    echo "    submodules verified: ${paths[*]}"
fi

echo "==> $SRC ready: $(git -C "$SRC" rev-parse HEAD)"
