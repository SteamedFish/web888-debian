#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# stamp-changelog.sh <path-to-debian-dir> <new-version>
#
# Rewrite ONLY the version in the first changelog line:
#   pkg (OLD) unstable; urgency=...   ->   pkg (NEW) unstable; urgency=...
# (the distribution field — unstable / UNRELEASED / whatever — is preserved
# verbatim). Validates the changelog format before and after the rewrite and
# fails loudly on anything malformed.
#
# CI-only helper: the workflows stamp a "+ci${GITHUB_RUN_NUMBER}" suffix into
# the CI checkout so each run publishes a strictly newer version to the APT
# repo. The stamped changelog is NEVER committed back.

set -euo pipefail

log() { echo "==> $*"; }
die() { echo "Error: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <path-to-debian-dir> <new-version>"
DEBIAN_DIR=$1
NEWVER=$2
CHANGELOG=$DEBIAN_DIR/changelog

[[ -d $DEBIAN_DIR ]]    || die "not a directory: $DEBIAN_DIR"
[[ -f $CHANGELOG ]]     || die "missing $CHANGELOG"
[[ -n $NEWVER ]]        || die "empty new version"
# Debian version charset: epoch? upstream [-revision]; allow alnum . + - ~ :
[[ $NEWVER =~ ^[0-9A-Za-z.+~:-]+$ ]] || die "invalid Debian version: $NEWVER"

command -v dpkg-parsechangelog >/dev/null 2>&1 \
    || die "dpkg-parsechangelog required (apt: dpkg-dev)"

# --- validate the changelog before touching it ----------------------------
first=$(head -n 1 "$CHANGELOG")
# first line: "pkg (version) distribution; urgency=<level>"
[[ $first =~ ^[a-z0-9][a-z0-9+.-]*\ \([0-9A-Za-z.+~:-]+\)\ [A-Za-z-]+\;\ urgency=(low|medium|high|emergency|critical)$ ]] \
    || die "malformed first changelog line: $first"
dpkg-parsechangelog -l "$CHANGELOG" >/dev/null 2>&1 \
    || die "changelog failed dpkg-parsechangelog validation: $CHANGELOG"

OLDVER=$(dpkg-parsechangelog -l "$CHANGELOG" -S Version 2>/dev/null) \
    || die "cannot read current version from $CHANGELOG"
[[ $OLDVER == "$NEWVER" ]] && { log "version already $NEWVER — nothing to do"; exit 0; }

# --- rewrite only the version on the first line ---------------------------
awk -v newver="$NEWVER" '
    NR == 1 { sub(/\([^()]*\)/, "(" newver ")") }
    { print }
' "$CHANGELOG" > "$CHANGELOG.stamped"
mv "$CHANGELOG.stamped" "$CHANGELOG"

# --- verify the rewrite ----------------------------------------------------
dpkg-parsechangelog -l "$CHANGELOG" >/dev/null 2>&1 \
    || die "stamped changelog is malformed: $CHANGELOG"
got=$(dpkg-parsechangelog -l "$CHANGELOG" -S Version 2>/dev/null)
[[ $got == "$NEWVER" ]] || die "post-stamp version mismatch: got $got, want $NEWVER"

log "stamped $CHANGELOG: $OLDVER -> $NEWVER"
