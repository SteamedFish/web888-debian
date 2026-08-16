#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# check-deps.sh <pkg-key|ALL> — print the current trixie armhf versions of
# the runtime libraries tracked in packaging/deps-snapshot.conf.
#
# Output:
#   - single pkg-key: one `<lib>=<version>` line per tracked library
#   - ALL: one `<pkg-key>: <lib>=<version> ...` line per package that has
#     tracked libraries (exactly the packaging/deps-snapshot.txt format, so
#     `check-deps.sh ALL > packaging/deps-snapshot.txt` refreshes the state
#     file); packages with no tracked libraries are omitted.
#
# The trixie Packages indices (main contrib non-free) are fetched from
# $DEBIAN_MIRROR (default https://deb.debian.org/debian) and cached for the
# day under ${XDG_CACHE_HOME:-$HOME/.cache}/web888. No sudo required.
#
# Exit 1 (loud) when a tracked library is not found in the archive — that
# means a soname bump renamed it and packaging/deps-snapshot.conf needs a
# manual update.

set -euo pipefail

log() { echo "==> $*" >&2; }
die() { echo "Error: $*" >&2; exit 1; }

REPO=$(cd "$(dirname "$0")/../.." && pwd)
CONF=$REPO/packaging/deps-snapshot.conf
SUITE=${DEPS_SUITE:-trixie}
ARCH=armhf
COMPONENTS=${DEPS_COMPONENTS:-"main contrib non-free"}
MIRROR=${DEBIAN_MIRROR:-https://deb.debian.org/debian}

(($# == 1)) || die "usage: $0 <pkg-key|ALL>"
[[ -f $CONF ]] || die "$CONF not found"

# --- parse the watch list -------------------------------------------------

declare -A libs=()
order=()
while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    [[ $line == *:* ]] || continue
    key=${line%%:*}
    key=${key//[[:space:]]/}
    [[ -n $key ]] || continue
    read -ra parts <<< "${line#*:}"
    libs[$key]="${parts[*]:-}"
    order+=("$key")
done < "$CONF"
((${#order[@]})) || die "no package keys parsed from $CONF"

# --- fetch + reduce the Packages indices (daily cache) ---------------------

cache=${XDG_CACHE_HOME:-$HOME/.cache}/web888
mkdir -p "$cache"
index=$cache/$SUITE-$ARCH-packages.$(date +%F).txt
if [[ ! -s $index ]]; then
    log "fetching $SUITE $ARCH Packages indices ($COMPONENTS) from $MIRROR"
    tmp=$(mktemp)
    trap 'rm -f "$tmp" "$index.new"' EXIT
    : > "$tmp"
    for comp in $COMPONENTS; do
        curl -fsSL --retry 3 --connect-timeout 20 \
            "$MIRROR/dists/$SUITE/$comp/binary-$ARCH/Packages.xz" | xz -dc >> "$tmp"
    done
    awk '$1 == "Package:" { pkg = $2 }
         $1 == "Version:" && pkg != "" { print pkg " " $2; pkg = "" }' \
        "$tmp" > "$index.new"
    mv "$index.new" "$index"
    rm -f "$tmp"
    trap - EXIT
    find "$cache" -name "$SUITE-$ARCH-packages.*.txt" ! -name "$(basename "$index")" -delete
fi

declare -A ver=()
while read -r name version; do
    ver[$name]=$version
done < "$index"
((${#ver[@]})) || die "no packages parsed from index $index"

# --- resolve and print ------------------------------------------------------

collect() { # <pkg-key> -> space-separated lib=version pairs on stdout
    local key=$1 lib out=()
    [[ -v "libs[$key]" ]] || die "unknown package key '$key' (not in $CONF)"
    [[ -n ${libs[$key]} ]] || return 0
    for lib in ${libs[$key]}; do
        [[ -v "ver[$lib]" ]] || die "library '$lib' (tracked for $key) not found in the $SUITE $ARCH archive — soname bump? Update packaging/deps-snapshot.conf"
        out+=("$lib=${ver[$lib]}")
    done
    echo "${out[*]}"
}

if [[ $1 == ALL ]]; then
    for key in "${order[@]}"; do
        pairs=$(collect "$key")
        [[ -n $pairs ]] && echo "$key: $pairs"
    done
else
    pairs=$(collect "$1")
    if [[ -n $pairs ]]; then
        read -ra arr <<< "$pairs"
        printf '%s\n' "${arr[@]}"
    fi
fi
