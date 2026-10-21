#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# update-apt-repo.sh <DEBS_DIR> <REPO_DIR> [SUBDIR]
#
# Update the flat gh-pages APT repository (Option A layout — debs under a
# subdirectory; see docs/dev/github-ci-apt-repo-research.md §1.5/§1.6,
# Clippy recipe). All repo files (debs, Packages, Release, InRelease,
# Release.gpg, pubkey.asc) live in REPO_DIR/SUBDIR (default "apt") so the
# gh-pages site ROOT stays free for a project homepage; nothing outside
# SUBDIR is touched except a root-level .nojekyll (needed so Pages serves
# the site as-is — harmless to the homepage).
#
#   1. copy DEBS_DIR/*.deb into REPO_DIR/SUBDIR
#   2. prune per package name (dpkg --compare-versions; package name = field
#      before the first "_" in the filename): keep the KEEP_VERSIONS newest
#      versions AND every version first published within the last KEEP_DAYS
#      days. First-seen dates are tracked in version-dates.txt inside SUBDIR
#      (committed alongside Packages by the caller): users can only be
#      running versions they could apt-install, i.e. recently published
#      ones — age is the available proxy for "has users" (GitHub Pages
#      serves no download statistics). Keep the old versions debuggable.
#   3. regenerate Packages / Packages.gz (dpkg-scanpackages --multiversion)
#   4. regenerate Release (apt-ftparchive)
#   5. sign: Release.gpg (detached armor) + InRelease (clearsign)
#   6. export pubkey.asc if missing; touch root .nojekyll
#
# No git operations — the calling workflow does add/commit/push.
#
# Env:
#   APT_GPG_KEY_ID   (required) key used to sign Release / InRelease
#   KEEP_VERSIONS    (optional, default 4) versions kept per package
#   KEEP_DAYS        (optional, default 90) first-published window in which
#                    versions are kept even beyond KEEP_VERSIONS

set -euo pipefail

log() { echo "==> $*"; }
die() { echo "Error: $*" >&2; exit 1; }

[[ $# -ge 2 && $# -le 3 ]] || die "usage: $0 <DEBS_DIR> <REPO_DIR> [SUBDIR]"
DEBS_DIR=$1
REPO_DIR=$2
SUBDIR=${3:-apt}
KEEP_VERSIONS=${KEEP_VERSIONS:-4}
KEEP_DAYS=${KEEP_DAYS:-90}

[[ -n ${APT_GPG_KEY_ID:-} ]] || die "APT_GPG_KEY_ID is not set"
[[ -d $DEBS_DIR ]] || die "not a directory: $DEBS_DIR"
[[ -d $REPO_DIR ]] || die "not a directory: $REPO_DIR"
[[ $SUBDIR != */* && $SUBDIR != .* && -n $SUBDIR ]] \
    || die "SUBDIR must be a plain directory name (got '$SUBDIR')"
# Canonicalize to an absolute path: we cd into $SUBDIR for the index work
# below, and root-level writes (.nojekyll) must not become relative to it.
REPO_DIR=$(cd "$REPO_DIR" && pwd)
[[ $KEEP_VERSIONS =~ ^[0-9]+$ && $KEEP_VERSIONS -ge 1 ]] \
    || die "KEEP_VERSIONS must be a positive integer (got '$KEEP_VERSIONS')"
[[ $KEEP_DAYS =~ ^[0-9]+$ && $KEEP_DAYS -ge 1 ]] \
    || die "KEEP_DAYS must be a positive integer (got '$KEEP_DAYS')"

for cmd in dpkg-scanpackages apt-ftparchive gpg gzip dpkg; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "$cmd required (apt: dpkg-dev apt-utils gnupg)"
done

shopt -s nullglob
new_debs=("$DEBS_DIR"/*.deb)
((${#new_debs[@]})) || die "no .deb files in $DEBS_DIR"

mkdir -p "$REPO_DIR/$SUBDIR"
log "copying ${#new_debs[@]} deb(s) into $REPO_DIR/$SUBDIR"
cp -f "${new_debs[@]}" "$REPO_DIR/$SUBDIR/"

cd "$REPO_DIR/$SUBDIR"

# --- first-seen date tracking (version-dates.txt) --------------------------
# One line per deb stem: "<stem> <YYYY-MM-DD>" (UTC first-seen). Missing
# entries (fresh debs, or everything on the first run after this feature
# landed) get today's date — bootstrap is deliberately conservative: all
# pre-existing versions count as young and survive one full KEEP_DAYS
# window before age-based pruning starts biting.
DATES=version-dates.txt
TODAY=$(date -u +%F)
touch "$DATES"
for f in *.deb; do
    stem=${f%.deb}
    grep -q "^${stem} " "$DATES" || echo "$stem $TODAY" >> "$DATES"
done

first_seen() {  # first_seen <stem> → YYYY-MM-DD (falls back to today)
    local d
    d=$(awk -v s="$1" '$1 == s { print $2 }' "$DATES" | tail -1)
    echo "${d:-$TODAY}"
}

# --- prune old versions per package -----------------------------------------
# Keep rule: rank < KEEP_VERSIONS (newest-first) OR first-seen date is
# younger than KEEP_DAYS. Everything older AND out of the top ranks goes.
all_debs=(*.deb)
((${#all_debs[@]})) || die "no .deb files in $REPO_DIR/$SUBDIR after copy"

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
    rank=0
    for old in "${sorted[@]}"; do
        if (( rank < KEEP_VERSIONS )); then
            (( ++rank ))
            continue
        fi
        stem=${old%.deb}
        seen=$(first_seen "$stem")
        keep_until=$(date -u -d "$seen + $KEEP_DAYS days" +%F)
        if [[ ! $keep_until < $TODAY ]]; then
            log "keep: $old (first published $seen, within ${KEEP_DAYS}d window)"
            continue
        fi
        log "prune: $old (rank >$KEEP_VERSIONS of $pkg, first published $seen >${KEEP_DAYS}d ago)"
        rm -f "$old"
    done
done

# Garbage-collect date entries whose deb is gone.
tmp_dates=$(mktemp)
while read -r stem date; do
    if [[ -f ${stem}.deb ]]; then
        echo "$stem $date"
    fi
done < "$DATES" > "$tmp_dates"
mv "$tmp_dates" "$DATES"

# --- index ------------------------------------------------------------------
log "generating Packages / Packages.gz"
dpkg-scanpackages --multiversion . /dev/null > Packages
gzip -9kf Packages

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

touch "$REPO_DIR/.nojekyll"
log "done: $(ls ./*.deb | wc -l) deb(s), $(ls ./*.deb | cut -d_ -f1 | sort -u | wc -l) package(s) in $REPO_DIR/$SUBDIR"
