#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# check-web888-ng-upstream.sh — release watcher for the pinned web888-ng pair:
#
#   web888d  <= jeskko/web888-ng      (daemon + UI source)
#   hw       <= jeskko/web888-ng-hw   (FPGA bitstreams released as assets)
#
# Unlike the third-party packages (check-upstream.sh, /releases/latest), EVERY
# upstream release so far is flagged prerelease on GitHub, so /releases/latest
# is permanently empty. This script therefore lists the full release stream,
# excludes drafts, validates semver tags and performs FORWARD-ONLY selection:
# the single newest release whose version is strictly greater than the pinned
# version. Anything older or equal is ignored (monotone pin progression; a
# skipped intermediate tag is not a regression).
#
# Pinned-pair semantics: web888d and hw are tracked as a pair. When only one
# side advances, the emitted update lines cover ONLY that side's keys — the
# caller merges them into the pin file and the other side's pins are retained
# verbatim (never independently floated to "latest").
#
# Pin file (READ ONLY here; owned by lane A, committed):
#   config/web888-ng/pins.env — shell-assignable lines, e.g.
#     WEB888_NG_VERSION=0.6.0          (tag without the leading 'v')
#     WEB888_NG_COMMIT=<full sha the tag points at>
#     WEB888_NG_TARBALL=web888-ng-v0.6.0.tar.gz
#     WEB888_NG_TARBALL_URL=https://codeload.github.com/jeskko/web888-ng/tar.gz/refs/tags/v0.6.0
#     WEB888_NG_SHA256=<sha256 of the source tarball; build scripts refuse
#                       to build on mismatch>
#     WEB888_NGHW_VERSION=0.3.0
#     WEB888_NGHW_COMMIT=<full sha>
#     ... tarball/url/sha256, RELEASE_API, and per-release-asset hashes
#     (WEB888_BITSTREAM_{HF,VHF}_SHA256 etc.) taken from the release's
#     SHA256SUMS asset.
#
# Usage: check-web888-ng-upstream.sh [--dry-run | --full-pin] [ng|hw|all]
#
# Output:
#   default (check) mode, stdout — machine lines ONLY for advanced side(s):
#     WEB888_NG_TAG=vX.Y.Z / WEB888_NG_COMMIT=<sha> (ng side)
#     WEB888_NGHW_TAG=vX.Y.Z / WEB888_NGHW_COMMIT=<sha> (hw side)
#   --full-pin (live network only): instead of TAG lines, emit the COMPLETE
#     lane-A key set for the advanced side(s) — tarball names/URLs recomputed
#     from the tag, source-tarball sha256 downloaded and hashed, hw asset
#     hashes taken from the release's SHA256SUMS. If any expected hw asset is
#     missing from SHA256SUMS the hw bump FAILS (return 1) so the caller
#     leaves the hw pin untouched for a human.
#   --dry-run: print the candidate table (drafts excluded) to stdout and
#     select nothing; exit 0. For manual prerelease/forward-only checks.
#   stderr: human-readable scan/selection log (always).
#
# Environment:
#   GITHUB_TOKEN                  optional (API rate limits)
#   CHECK_WEB888_NG_RELEASES_JSON test hook: path to a saved JSON object
#                                 {"jeskko/web888-ng": [...releases...],
#                                  "jeskko/web888-ng-hw": [...]}
#                                 used instead of the network; commit
#                                 resolution and hashing are skipped (COMMIT
#                                 lines become "unresolved-fixture",
#                                 --full-pin is rejected). Used by
#                                 test-check-web888-ng-upstream.sh.
#
# Exit codes: 0 scan completed (update found or not), 1 fetch/parse/hash
# failure, 2 usage error.

set -euo pipefail

log() { echo "[check-web888-ng] $*" >&2; }

DRY_RUN=0
FULL_PIN=0
SCOPE=all
for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        --full-pin) FULL_PIN=1 ;;
        ng|hw|all)  SCOPE=$arg ;;
        *)
            echo "usage: $0 [--dry-run | --full-pin] [ng|hw|all]" >&2
            exit 2
            ;;
    esac
done

if (( FULL_PIN )) && [[ -n ${CHECK_WEB888_NG_RELEASES_JSON:-} ]]; then
    log "--full-pin cannot run against fixtures (no download/hashing)"
    exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
PINFILE="$REPO_ROOT/config/web888-ng/pins.env"

# Pin values; empty when the pin file is absent (fresh bootstrap).
PIN_NG_TAG="" PIN_NG_COMMIT=""
PIN_HW_TAG="" PIN_HW_COMMIT=""
if [[ -f $PINFILE ]]; then
    # shellcheck disable=SC1090 # lane-A-owned, repo-committed env file
    source "$PINFILE"
    # Lane A pins record VERSION without the leading 'v'; normalize to the
    # raw tag form for semver comparisons.
    PIN_NG_TAG=${WEB888_NG_VERSION:+v${WEB888_NG_VERSION#v}}
    PIN_NG_COMMIT=${WEB888_NG_COMMIT:-}
    PIN_HW_TAG=${WEB888_NGHW_VERSION:+v${WEB888_NGHW_VERSION#v}}
    PIN_HW_COMMIT=${WEB888_NGHW_COMMIT:-}
else
    log "pin file $PINFILE not found — treating every release as new (bootstrap)"
fi

# ---------------------------------------------------------------- semver ----
# Semver tag form: optional leading 'v', MAJOR.MINOR.PATCH, optional
# -prerelease suffix (e.g. v0.7.0-rc1). Non-conforming tags (nightlies,
# vendor oddities) are excluded from selection entirely.
semver_parse() { # semver_parse <tag> -> "MAJOR MINOR PATCH PRERELEASE" or rc 1
    local tag=$1
    tag=${tag#v}
    if [[ ! $tag =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z.-]+))?$ ]]; then
        return 1
    fi
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]} ${BASH_REMATCH[5]:-}"
}

semver_cmp() { # semver_cmp <tagA> <tagB> -> -1|0|1 on stdout, rc 1 on parse error
    local a b
    a=$(semver_parse "$1") || return 1
    b=$(semver_parse "$2") || return 1
    read -r amaj amin apat apre <<<"$a"
    read -r bmaj bmin bpat bpre <<<"$b"
    if (( amaj != bmaj )); then (( amaj < bmaj )) && echo -1 || echo 1; return; fi
    if (( amin != bmin )); then (( amin < bmin )) && echo -1 || echo 1; return; fi
    if (( apat != bpat )); then (( apat < bpat )) && echo -1 || echo 1; return; fi
    # Equal numeric triple: a release outranks a prerelease of the same triple.
    if [[ -z $apre && -z $bpre ]]; then echo 0; return; fi
    [[ -z $apre ]] && { echo 1; return; }
    [[ -z $bpre ]] && { echo -1; return; }
    [[ $apre == "$bpre" ]] && { echo 0; return; }
    # Prerelease precedence: dot-separated identifiers, numeric identifiers
    # compare numerically (semver §11, common case).
    local IFS=.
    local -a aparts bparts
    read -ra aparts <<<"$apre"
    read -ra bparts <<<"$bpre"
    local i n=${#aparts[@]}
    if ((${#bparts[@]} > n)); then n=${#bparts[@]}; fi
    for ((i = 0; i < n; i++)); do
        local ai=${aparts[i]:-} bi=${bparts[i]:-}
        [[ -z $ai ]] && { echo -1; return; }
        [[ -z $bi ]] && { echo 1; return; }
        if [[ $ai =~ ^[0-9]+$ && $bi =~ ^[0-9]+$ ]]; then
            if (( ai != bi )); then (( ai < bi )) && echo -1 || echo 1; return; fi
        elif [[ $ai != "$bi" ]]; then
            [[ $ai < $bi ]] && echo -1 || echo 1; return
        fi
    done
    echo 0
}

# ------------------------------------------------------------- GitHub API ----

gh_curl() { # gh_curl <url> — authenticated GET to stdout
    local auth=()
    [[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL --max-time 120 --retry 3 "${auth[@]}" "$1"
}

gh_releases() { # gh_releases <owner/repo> -> releases JSON on stdout
    local repo=$1
    if [[ -n ${CHECK_WEB888_NG_RELEASES_JSON:-} ]]; then
        # Test hook: fixture object keyed by repo slug.
        jq -c --arg r "$repo" '.[$r] // []' "$CHECK_WEB888_NG_RELEASES_JSON"
        return
    fi
    # Authenticated listings CAN include drafts (repos you can push to) —
    # filter them out regardless below.
    gh_curl "https://api.github.com/repos/$repo/releases?per_page=100"
}

resolve_commit() { # resolve_commit <owner/repo> <tag> -> commit sha
    local repo=$1 tag=$2
    local ref_json sha rtype
    ref_json=$(gh_curl "https://api.github.com/repos/$repo/git/ref/tags/$tag")
    sha=$(jq -r '.object.sha' <<<"$ref_json")
    rtype=$(jq -r '.object.type' <<<"$ref_json")
    if [[ $rtype == tag ]]; then
        # Annotated tag: peel one level to the commit object.
        sha=$(gh_curl "https://api.github.com/repos/$repo/git/tags/$sha" | jq -r '.object.sha')
    fi
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || return 1
    echo "$sha"
}

sha256_of_url() { # sha256_of_url <url> -> hex sha256 of the downloaded body
    curl -fsSL --max-time 300 --retry 3 -o "$WORK/dl.bin" "$1" \
        || { log "download failed: $1"; return 1; }
    sha256sum "$WORK/dl.bin" | cut -d' ' -f1
}

WORK=""
if (( FULL_PIN )); then
    WORK=$(mktemp -d "/tmp/web888-ng-pin.XXXXXX")
    # shellcheck disable=SC2064 # expand now: WORK is fixed from here on
    trap "rm -rf '$WORK'" EXIT
fi

# ------------------------------------------------------- full-pin emission --

# Emit the complete lane-A key set for one advanced side. $releases (the
# release-list JSON) is available from scan_repo's caller scope.
emit_full_pin() { # emit_full_pin <ng|hw> <tag> <commit>
    local side=$1 tag=$2 commit=$3
    local repo ver tarball url
    case $side in
        ng)
            repo=jeskko/web888-ng
            ver=${tag#v}
            tarball="web888-ng-${tag}.tar.gz"
            url="https://codeload.github.com/jeskko/web888-ng/tar.gz/refs/tags/${tag}"
            log "hashing source tarball $tarball"
            local sum
            sum=$(sha256_of_url "$url") || return 1
            echo "WEB888_NG_VERSION=$ver"
            echo "WEB888_NG_COMMIT=$commit"
            echo "WEB888_NG_TARBALL=$tarball"
            echo "WEB888_NG_TARBALL_URL=$url"
            echo "WEB888_NG_SHA256=$sum"
            ;;
        hw)
            repo=jeskko/web888-ng-hw
            ver=${tag#v}
            tarball="web888-ng-hw-${tag}.tar.gz"
            url="https://codeload.github.com/jeskko/web888-ng-hw/tar.gz/refs/tags/${tag}"
            # Asset hashes come from the release's own SHA256SUMS file.
            local sums_url
            sums_url=$(jq -r --arg t "$tag" \
                '.[] | select(.tag_name == $t and .draft != true)
                     | .assets[] | select(.name == "SHA256SUMS") | .browser_download_url' \
                <<<"$releases" | head -n1)
            [[ -n $sums_url && $sums_url != null ]] \
                || { log "no SHA256SUMS asset on $repo $tag — cannot bump hw pin"; return 1; }
            log "fetching $repo $tag SHA256SUMS for asset hashes"
            local sums
            sums=$(curl -fsSL --max-time 60 --retry 3 -o "$WORK/SHA256SUMS" "$sums_url" \
                    && cat "$WORK/SHA256SUMS") \
                || { log "failed to download SHA256SUMS"; return 1; }
            asset_sha() { # asset_sha <filename> -> hash from SHA256SUMS, rc 1 if absent
                awk -v f="$1" '$NF == f { print $1; found=1 } END { exit !found }' \
                    <<<"$sums"
            }
            local hf vhf wns lic sums_sha src_sha
            hf=$(asset_sha websdr_hf.bit)  || { log "SHA256SUMS lacks websdr_hf.bit"; return 1; }
            vhf=$(asset_sha websdr_vhf.bit) || { log "SHA256SUMS lacks websdr_vhf.bit"; return 1; }
            wns=$(asset_sha wns.txt)      || { log "SHA256SUMS lacks wns.txt"; return 1; }
            lic=$(asset_sha licence.txt)  || { log "SHA256SUMS lacks licence.txt"; return 1; }
            sums_sha=$(sha256sum "$WORK/SHA256SUMS" | cut -d' ' -f1)
            log "hashing source tarball $tarball"
            src_sha=$(sha256_of_url "$url") || return 1
            echo "WEB888_NGHW_VERSION=$ver"
            echo "WEB888_NGHW_COMMIT=$commit"
            echo "WEB888_NGHW_TARBALL=$tarball"
            echo "WEB888_NGHW_TARBALL_URL=$url"
            echo "WEB888_NGHW_SHA256=$src_sha"
            echo "WEB888_NGHW_RELEASE_API=https://api.github.com/repos/jeskko/web888-ng-hw/releases/tags/${tag}"
            echo "WEB888_BITSTREAM_HF=websdr_hf.bit"
            echo "WEB888_BITSTREAM_HF_SHA256=$hf"
            echo "WEB888_BITSTREAM_VHF=websdr_vhf.bit"
            echo "WEB888_BITSTREAM_VHF_SHA256=$vhf"
            echo "WEB888_NGHW_SHA256SUMS=SHA256SUMS"
            echo "WEB888_NGHW_SHA256SUMS_SHA256=$sums_sha"
            echo "WEB888_NGHW_WNS=wns.txt"
            echo "WEB888_NGHW_WNS_SHA256=$wns"
            echo "WEB888_NGHW_LICENCE=licence.txt"
            echo "WEB888_NGHW_LICENCE_SHA256=$lic"
            ;;
    esac
}

# ------------------------------------------------------------ per-repo scan --

scan_repo() { # scan_repo <ng|hw>
    local side=$1
    local repo prefix pin_tag pin_commit
    case $side in
        ng)
            repo=jeskko/web888-ng
            prefix=WEB888_NG
            pin_tag=$PIN_NG_TAG
            pin_commit=$PIN_NG_COMMIT
            ;;
        hw)
            repo=jeskko/web888-ng-hw
            prefix=WEB888_NGHW
            pin_tag=$PIN_HW_TAG
            pin_commit=$PIN_HW_COMMIT
            ;;
    esac

    local releases
    if ! releases=$(gh_releases "$repo"); then
        log "failed to fetch releases for $repo"
        return 1
    fi
    if ! jq -e 'type == "array"' <<<"$releases" >/dev/null; then
        log "malformed releases JSON for $repo"
        return 1
    fi

    # Candidate table: published (non-draft) releases with semver tags,
    # newest-first by version (API order is by creation, not semver).
    local table=""
    while IFS=$'\t' read -r tag prerelease published_at; do
        [[ -n $tag ]] || continue
        if ! semver_parse "$tag" >/dev/null 2>&1; then
            log "$repo: skipping non-semver tag '$tag'"
            continue
        fi
        table+="$tag"$'\t'"$prerelease"$'\t'"$published_at"$'\n'
    done < <(jq -r '.[] | select(.draft != true) | [.tag_name, .prerelease, .published_at] | @tsv' <<<"$releases")
    # Drafts never reach the table; count them for the log line.
    local ndrafts
    ndrafts=$(jq '[.[] | select(.draft == true)] | length' <<<"$releases")
    if (( ndrafts )); then
        log "$repo: excluded $ndrafts draft release(s)"
    fi

    if [[ -z $table ]]; then
        log "$repo: no published semver releases found"
        return 0
    fi

    # Sort candidates newest-first by semver (prerelease suffix ranks below
    # its release of the same triple).
    local sorted=""
    while IFS= read -r line; do
        # here-strings yield a trailing empty read; skip it (tag would
        # otherwise be empty and sort to the tail as a phantom row)
        [[ -n $line ]] || continue
        local tag=${line%%$'\t'*}
        local rest=${line#*$'\t'}
        # insertion sort into `sorted`
        local inserted=0 out=""
        while IFS= read -r sline; do
            [[ -n $sline ]] || continue
            local stag=${sline%%$'\t'*}
            if (( ! inserted )) && [[ $(semver_cmp "$tag" "$stag") == 1 ]]; then
                out+="$tag"$'\t'"$rest"$'\n'
                inserted=1
            fi
            out+="$sline"$'\n'
        done <<<"$sorted"
        if (( ! inserted )); then
            out+="$tag"$'\t'"$rest"$'\n'
        fi
        sorted=$out
    done <<<"$table"

    if (( DRY_RUN )); then
        echo "== $repo (pinned: ${pin_tag:-none}) =="
        while IFS= read -r line; do
            [[ -n $line ]] || continue
            local tag=${line%%$'\t'*}
            local rest=${line#*$'\t'}
            local pre=${rest%%$'\t'*}
            local mark=""
            if [[ -n $pin_tag ]]; then
                local c
                c=$(semver_cmp "$tag" "$pin_tag")
                case $c in
                    1)  mark="newer-than-pin" ;;
                    0)  mark="== pin" ;;
                    -1) mark="older-than-pin" ;;
                esac
            else
                mark="newer-than-pin"
            fi
            echo "  $tag  prerelease=$pre  $mark"
        done <<<"$sorted"
    fi

    # Forward-only selection: walk newest-first, take the first strictly
    # newer than the pin. With no pin (bootstrap) take the newest.
    local selected=""
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        local tag=${line%%$'\t'*}
        if [[ -z $pin_tag ]] || [[ $(semver_cmp "$tag" "$pin_tag") == 1 ]]; then
            selected=$line
            break
        fi
    done <<<"$sorted"

    if [[ -z $selected ]]; then
        log "$repo: pin ${pin_tag:-none} is up to date"
        return 0
    fi

    local sel_tag=${selected%%$'\t'*}
    local sel_rest=${selected#*$'\t'}
    local sel_pre=${sel_rest%%$'\t'*}
    log "$repo: selected $sel_tag (prerelease=$sel_pre) over pin ${pin_tag:-none}"
    if [[ -n $pin_commit ]]; then
        log "$repo: previous pin commit was $pin_commit"
    fi

    (( DRY_RUN )) && return 0

    local commit="unresolved-fixture"
    if [[ -z ${CHECK_WEB888_NG_RELEASES_JSON:-} ]]; then
        if ! commit=$(resolve_commit "$repo" "$sel_tag"); then
            log "failed to resolve tag $sel_tag to a commit in $repo"
            return 1
        fi
    fi

    if (( FULL_PIN )); then
        # $releases is visible here (dynamic scope): full-pin emission needs
        # the release asset list for the hw side.
        # shellcheck disable=SC2031 # intentional: same-shell variable
        emit_full_pin "$side" "$sel_tag" "$commit"
    else
        echo "${prefix}_TAG=$sel_tag"
        echo "${prefix}_COMMIT=$commit"
    fi
    return 0
}

rc=0
for side in ng hw; do
    if [[ $SCOPE == all || $SCOPE == $side ]]; then
        scan_repo "$side" || rc=1
    fi
done
exit $rc
