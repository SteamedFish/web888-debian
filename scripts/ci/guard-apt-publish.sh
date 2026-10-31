#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# guard-apt-publish.sh — collision guard for the flat gh-pages APT repo.
#
# The image-carrying packages version every upload via +ci<N>, so a same-name
# overwrite never arises there. The optional maintainer packages (web888d,
# web888-ng bitstream) can be rebuilt for an unchanged upstream version —
# e.g. a workflow_dispatch re-run, or an upstream tag force-push — and must
# NEVER silently replace a published deb of the same filename with different
# content: users would have no way to tell two different payloads apart
# under one version string, and rollback evidence (version-dates.txt,
# provenance) would become a lie.
#
# For every .deb in DEBS_DIR:
#   same filename already in REPO_DIR/SUBDIR:
#     identical sha256  -> drop it from DEBS_DIR (already published; a
#                          re-run of the identical build is a no-op)
#     different sha256  -> DIE. Same version, different content: bump the
#                          Debian revision (or the upstream pin) instead of
#                          overwriting.
#   otherwise           -> keep it for update-apt-repo.sh
#
# Usage: guard-apt-publish.sh <DEBS_DIR> <REPO_DIR> [SUBDIR]
#
# Output on $GITHUB_OUTPUT (when set):
#   result=publish   at least one new deb remains in DEBS_DIR
#   result=noop      every incoming deb was byte-identical already
# Skipped (duplicate) debs are listed on stderr.
#
# Exit codes: 0 ok (publish or noop), 1 collision (message on stderr), 2 usage.

set -euo pipefail

log() { echo "[guard-apt-publish] $*" >&2; }

[[ $# -ge 2 && $# -le 3 ]] || {
    echo "usage: $0 <DEBS_DIR> <REPO_DIR> [SUBDIR]" >&2
    exit 2
}
DEBS_DIR=$1
REPO_DIR=$2
SUBDIR=${3:-apt}

[[ -d $DEBS_DIR ]] || { log "not a directory: $DEBS_DIR"; exit 2; }
[[ -d $REPO_DIR/$SUBDIR || ! -e $REPO_DIR/$SUBDIR ]] \
    || { log "not a directory: $REPO_DIR/$SUBDIR"; exit 2; }
mkdir -p "$REPO_DIR/$SUBDIR"

shopt -s nullglob
incoming=("$DEBS_DIR"/*.deb)
if ((${#incoming[@]} == 0)); then
    log "no .deb files in $DEBS_DIR"
    exit 2
fi

result=publish
for deb in "${incoming[@]}"; do
    base=$(basename "$deb")
    target="$REPO_DIR/$SUBDIR/$base"
    [[ -f $target ]] || continue
    old_sum=$(sha256sum "$target" | cut -d' ' -f1)
    new_sum=$(sha256sum "$deb" | cut -d' ' -f1)
    if [[ $old_sum == "$new_sum" ]]; then
        log "skip: $base already published byte-identical"
        rm -f "$deb"
        continue
    fi
    log "COLLISION: $base exists in the APT repo with DIFFERENT content"
    log "  published: $old_sum"
    log "  incoming:  $new_sum"
    log "Refusing to overwrite a same-version deb — bump the Debian revision"
    log "or the upstream pin so both payloads stay distinguishable."
    exit 1
done

remaining=("$DEBS_DIR"/*.deb)
if ((${#remaining[@]} == 0)); then
    result=noop
    log "nothing new to publish (all incoming debs were duplicates)"
fi

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    echo "result=$result" >> "$GITHUB_OUTPUT"
fi
exit 0
