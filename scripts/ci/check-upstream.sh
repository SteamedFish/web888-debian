#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# check-upstream.sh — print the latest upstream version tag of a
# third-party package to stdout (e.g. "v1.7.0"). Exit 0 on success,
# exit 1 on fetch/parse failure. Runs unprivileged (no sudo).
#
# Usage: check-upstream.sh <libacars|dumphfdl|frpc|noip-duc>
#
# Environment:
#   GITHUB_TOKEN  optional, used for GitHub API rate limits.

set -euo pipefail

log() { echo "[check-upstream] $*" >&2; }

name=${1:-}

github_latest() { # github_latest <owner/repo>
    local repo=$1
    local tag=""
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        tag=$(curl -fsSL --max-time 60 -H "Authorization: Bearer $GITHUB_TOKEN" \
            "https://api.github.com/repos/$repo/releases/latest" \
            | jq -r '.tag_name // empty') || tag=""
        if [ -z "$tag" ]; then
            log "authenticated query failed for $repo; retrying unauthenticated"
        fi
    fi
    if [ -z "$tag" ]; then
        if ! tag=$(curl -fsSL --max-time 60 \
                "https://api.github.com/repos/$repo/releases/latest" \
                | jq -r '.tag_name // empty'); then
            log "failed to query GitHub API for $repo"
            exit 1
        fi
    fi
    if [ -z "$tag" ]; then
        log "empty tag_name for $repo"
        exit 1
    fi
    echo "$tag"
}

case "$name" in
    libacars) github_latest szpajder/libacars ;;
    dumphfdl) github_latest szpajder/dumphfdl ;;
    frpc)     github_latest fatedier/frp ;;
    noip-duc)
        page=$(curl -fsSL --max-time 60 'https://www.noip.com/download?page=linux') || {
            log "failed to fetch noip download page"
            exit 1
        }
        ver=$(grep -oE 'noip-duc_[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' <<<"$page" \
            | sed -E 's/^noip-duc_//; s/\.tar\.gz$//' \
            | sort -Vu | tail -n1) || true
        if [ -z "$ver" ]; then
            log "no noip-duc_X.Y.Z.tar.gz found on the download page"
            exit 1
        fi
        echo "$ver"
        ;;
    *)
        echo "usage: $0 <libacars|dumphfdl|frpc|noip-duc>" >&2
        exit 2
        ;;
esac
