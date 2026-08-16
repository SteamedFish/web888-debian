#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# preflight-skip.sh <manifest-key> <input-path>...
#
# Decides whether a push-triggered CI build can be skipped. Hashes the git
# tree objects of the given input paths at HEAD and compares the result
# against apt/build-manifest.json on the gh-pages branch, where each publish
# job records the input hash of the build it actually published. A match
# means the APT repo already carries debs built from exactly these inputs —
# rebuilding would burn runner hours for functionally identical output.
#
# Outputs on $GITHUB_OUTPUT:  hash=<sha256>  skip=true|false
#
# Never skips when:
#   - the event is workflow_dispatch / workflow_call — upstream-watch rebuilds
#     triggered by trixie library refreshes change no repo file, so the input
#     hash is unchanged but the build MUST run;
#   - the manifest is missing/unreadable or has no entry for this key —
#     nothing was published yet and the repo still needs populating;
#   - any query fails (building is the safe side).
set -uo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: preflight-skip.sh <manifest-key> <input-path>..." >&2
    exit 2
fi
KEY=$1; shift

hash_inputs() {
    local p entries=""
    for p in "$@"; do
        # tree/blob hash of the path at HEAD; the MISSING marker keeps the
        # hash well-defined (and changing) if an input path disappears
        entries+="$(git rev-parse -q --verify "HEAD:$p" 2>/dev/null || echo "MISSING:$p")"$'\n'
    done
    printf '%s' "$entries" | sort | sha256sum | cut -d' ' -f1
}

HASH=$(hash_inputs "$@")
skip=false

if [[ ${GITHUB_EVENT_NAME:-} == push ]]; then
    manifest=$(curl -sf --max-time 20 \
        "https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/gh-pages/apt/build-manifest.json" \
        2>/dev/null || echo '{}')
    published=$(jq -r --arg k "$KEY" '.[$k] // ""' <<<"$manifest" 2>/dev/null || echo '')
    if [[ -z $published ]]; then
        echo "[preflight] $KEY: no published build recorded — building"
    elif [[ $published == "$HASH" ]]; then
        skip=true
        echo "[preflight] $KEY: inputs unchanged since last published build — skipping"
    else
        echo "[preflight] $KEY: inputs changed ($published -> $HASH) — building"
    fi
else
    echo "[preflight] event '${GITHUB_EVENT_NAME:-?}' — dispatch/call always builds"
fi

{
    echo "hash=$HASH"
    echo "skip=$skip"
} >> "$GITHUB_OUTPUT"
