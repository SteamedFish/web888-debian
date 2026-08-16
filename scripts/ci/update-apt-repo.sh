#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# update-apt-repo.sh <DEBS_DIR> <REPO_DIR>
#
# Update the flat gh-pages APT repository (Option A layout — debs at the repo
# root; see docs/dev/github-ci-apt-repo-research.md §1.5/§1.6, Clippy recipe):
#
#   1. copy DEBS_DIR/*.deb into REPO_DIR
#   2. prune per package name to KEEP_VERSIONS newest (dpkg --compare-versions;
#      package name = field before the first "_" in the filename)
#   3. regenerate Packages / Packages.gz (dpkg-scanpackages --multiversion)
#   4. regenerate Release (apt-ftparchive)
#   5. sign: Release.gpg (detached armor) + InRelease (clearsign)
#   6. export pubkey.asc if missing; touch .nojekyll
#
# No git operations — the calling workflow does add/commit/push.
#
# Env:
#   APT_GPG_KEY_ID   (required) key used to sign Release / InRelease
#   KEEP_VERSIONS    (optional, default 4) versions kept per package

set -euo pipefail

log() { echo "==> $*"; }
die() { echo "Error: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <DEBS_DIR> <REPO_DIR>"
DEBS_DIR=$1
REPO_DIR=$2
KEEP_VERSIONS=${KEEP_VERSIONS:-4}

[[ -n ${APT_GPG_KEY_ID:-} ]] || die "APT_GPG_KEY_ID is not set"
[[ -d $DEBS_DIR ]] || die "not a directory: $DEBS_DIR"
[[ -d $REPO_DIR ]] || die "not a directory: $REPO_DIR"
[[ $KEEP_VERSIONS =~ ^[0-9]+$ && $KEEP_VERSIONS -ge 1 ]] \
    || die "KEEP_VERSIONS must be a positive integer (got '$KEEP_VERSIONS')"

for cmd in dpkg-scanpackages apt-ftparchive gpg gzip dpkg; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "$cmd required (apt: dpkg-dev apt-utils gnupg)"
done

shopt -s nullglob
new_debs=("$DEBS_DIR"/*.deb)
((${#new_debs[@]})) || die "no .deb files in $DEBS_DIR"

log "copying ${#new_debs[@]} deb(s) into $REPO_DIR"
cp -f "${new_debs[@]}" "$REPO_DIR/"

cd "$REPO_DIR"

# --- prune to KEEP_VERSIONS newest per package -----------------------------
# package name = field before the first "_" in the filename; version = field
# between the first and second "_". Insertion-sorted newest-first with
# dpkg --compare-versions (sort -V is NOT dpkg semantics).
all_debs=(*.deb)
((${#all_debs[@]})) || die "no .deb files in $REPO_DIR after copy"

declare -A pkg_seen=()
for f in "${all_debs[@]}"; do
    pkg_seen[${f%%_*}]=1
done

for pkg in "${!pkg_seen[@]}"; do
    files=("$pkg"_*.deb)
    sorted=()
    for f in "${files[@]}"; do
        v=${f#*_}; v=${v%_*}
        i=0
        while (( i < ${#sorted[@]} )); do
            sv=${sorted[i]#*_}; sv=${sv%_*}
            dpkg --compare-versions "$v" gt "$sv" && break
            (( ++i ))
        done
        sorted=("${sorted[@]:0:i}" "$f" "${sorted[@]:i}")
    done
    for old in "${sorted[@]:KEEP_VERSIONS}"; do
        log "prune: $old (keeping $KEEP_VERSIONS newest of $pkg)"
        rm -f "$old"
    done
done

# --- index ------------------------------------------------------------------
log "generating Packages / Packages.gz"
dpkg-scanpackages --multiversion . /dev/null > Packages
gzip -9k Packages

log "generating Release"
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=web888 \
    -o APT::FTPArchive::Release::Label=web888 \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Architectures=armhf \
    -o APT::FTPArchive::Release::Components=main \
    release . > Release

# --- sign ---------------------------------------------------------------------
log "signing Release (key $APT_GPG_KEY_ID)"
gpg --batch --yes -u "$APT_GPG_KEY_ID" --detach-sign --armor -o Release.gpg Release
gpg --batch --yes -u "$APT_GPG_KEY_ID" --clearsign -o InRelease Release

if [[ ! -f pubkey.asc ]]; then
    log "exporting pubkey.asc"
    gpg --armor --export "$APT_GPG_KEY_ID" > pubkey.asc
fi

touch .nojekyll
log "done: $(ls ./*.deb | wc -l) deb(s), $(ls ./*.deb | cut -d_ -f1 | sort -u | wc -l) package(s) in $REPO_DIR"
