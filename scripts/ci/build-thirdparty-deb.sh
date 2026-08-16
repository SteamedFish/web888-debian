#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# build-thirdparty-deb.sh — build one third-party package into armhf .deb(s)
# for the Web-888 flat APT repo (Debian trixie).
#
# Usage: build-thirdparty-deb.sh <libacars|dumphfdl|frpc|noip-duc> <OUTDIR>
#
#   libacars / dumphfdl : source builds inside the armhf qemu chroot created
#                         by mk-build-chroot.sh (dpkg-buildpackage -us -uc -b).
#                         dumphfdl additionally installs the libacars2 debs
#                         found in DEP_DEBS_DIR (default: OUTDIR) first —
#                         build libacars before dumphfdl.
#   frpc                : repack of the official static Go release binary
#                         (sha256-verified), plain dpkg-deb, no chroot.
#   noip-duc            : republish No-IP's official armhf deb verbatim
#                         (tarball sha256-verified), no chroot.
#
# Environment:
#   CI_BUILD_CHROOT    chroot location (default /tmp/web888-ci-chroot)
#   DEBIAN_MIRROR      debootstrap mirror (passed to mk-build-chroot.sh)
#   DEP_DEBS_DIR       where dumphfdl looks for libacars2*_armhf.deb
#                      (default: OUTDIR)
#   GITHUB_RUN_NUMBER  if set, append "+ci<N>" to the Debian revision of
#                      the source/repack builds (libacars, dumphfdl, frpc);
#                      noip-duc always keeps the official version verbatim.

set -euo pipefail

REPO=$(git rev-parse --show-toplevel)
CHROOT=${CI_BUILD_CHROOT:-/tmp/web888-ci-chroot}

log() { echo "[build-thirdparty] $*"; }
die() { echo "[build-thirdparty] ERROR: $*" >&2; exit 1; }

NAME=${1:-}
OUTDIR=${2:-}
case "$NAME" in
    libacars|dumphfdl|frpc|noip-duc) ;;
    *) die "usage: $0 <libacars|dumphfdl|frpc|noip-duc> <OUTDIR>" ;;
esac
[ -n "$OUTDIR" ] || die "usage: $0 <libacars|dumphfdl|frpc|noip-duc> <OUTDIR>"
mkdir -p "$OUTDIR"
OUTDIR=$(readlink -f "$OUTDIR")

PIN="$REPO/packaging/$NAME/upstream.pin"
[ -f "$PIN" ] || die "missing pin file: $PIN"

pin_get() { # pin_get <key> — first "key: value" line, value may contain colons
    grep -m1 "^$1:" "$PIN" | sed "s/^$1:[[:space:]]*//"
}

PIN_URL=$(pin_get url)
PIN_VERSION=$(pin_get version)
PKGREV=$(pin_get pkgrev)
[ -n "$PIN_URL" ] || die "pin file missing url:"
[ -n "$PIN_VERSION" ] || die "pin file missing version:"
[ -n "$PKGREV" ] || die "pin file missing pkgrev:"

VER=${PIN_VERSION#v}
REV="1web888${PKGREV}"
if [ -n "${GITHUB_RUN_NUMBER:-}" ]; then
    REV="${REV}+ci${GITHUB_RUN_NUMBER}"
fi
DEBVER="${VER}-${REV}"

WORK=$(mktemp -d "/tmp/web888-build-$NAME.XXXXXX")
CHROOT_MOUNTED=""
cleanup() {
    if [ -n "$CHROOT_MOUNTED" ]; then
        for m in sys proc dev/pts dev; do
            sudo umount "$CHROOT/$m" 2>/dev/null || true
        done
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- chroot helpers

ensure_chroot() {
    # mk-build-chroot.sh is idempotent: it creates the chroot when missing
    # and refreshes it (apt-get update + full-upgrade) on reuse, so builds
    # always link against the current trixie archive.
    "$REPO/scripts/ci/mk-build-chroot.sh"
}

mount_chroot() {
    # Fresh bind mounts on every run: the host mounts live in a private
    # mount namespace of whatever process created them, so a previous
    # script's mounts may be gone.
    local m
    for m in dev dev/pts proc sys; do
        sudo findmnt "$CHROOT/$m" >/dev/null 2>&1 || sudo mount --bind "/$m" "$CHROOT/$m"
    done
    CHROOT_MOUNTED=1
}

chroot_run() { # chroot_run <command-string>
    sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin bash -c "$1"
}

# ---------------------------------------------------------------- source builds (libacars, dumphfdl)

build_src_pkg() { # build_src_pkg <tarball-url> <extra-apt-deps...>
    local url=$1
    shift
    local extra_deps="$*"

    ensure_chroot

    log "downloading $url"
    curl -fsSL -o "$WORK/src.tar.gz" "$url"
    tar xzf "$WORK/src.tar.gz" -C "$WORK"
    local srcdir
    srcdir=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name '*-*' | head -n1)
    [ -n "$srcdir" ] || die "could not locate unpacked source tree in $WORK"

    log "overlaying packaging/$NAME/debian"
    cp -a "$REPO/packaging/$NAME/debian" "$srcdir/debian"
    # Stamp version: <upstream-ver>-1web888<pkgrev>[+ci<N>]
    sed -i "1s/([^)]*)/(${DEBVER})/" "$srcdir/debian/changelog"
    head -n1 "$srcdir/debian/changelog"

    log "installing extra build deps into chroot: $extra_deps"
    chroot_run "apt-get update -qq && apt-get install -y --no-install-recommends $extra_deps"

    if [ "$NAME" = "dumphfdl" ]; then
        local depdir=${DEP_DEBS_DIR:-$OUTDIR}
        local debs
        debs=$(find "$depdir" -maxdepth 1 -name 'libacars2*_armhf.deb' | sort)
        [ -n "$debs" ] || die "dumphfdl requires libacars2*_armhf.deb in DEP_DEBS_DIR ($depdir) — build libacars first"
        log "installing libacars debs into chroot: $debs"
        mkdir -p "$WORK/dep-debs"
        find "$depdir" -maxdepth 1 -name 'libacars2*_armhf.deb' -exec cp -t "$WORK/dep-debs/" {} +
        sudo rm -rf "$CHROOT/root/dep-debs"
        sudo cp -a "$WORK/dep-debs" "$CHROOT/root/dep-debs"
        chroot_run 'dpkg -i /root/dep-debs/*.deb || apt-get -f install -y'
    fi

    sudo rm -rf "$CHROOT/root/build"
    sudo mkdir -p "$CHROOT/root/build"
    sudo cp -a "$srcdir" "$CHROOT/root/build/"

    mount_chroot
    local bname
    bname=$(basename "$srcdir")
    log "building $NAME $DEBVER (armhf, in chroot)"
    chroot_run "cd /root/build/$bname && dpkg-buildpackage -us -uc -b"

    # Chroot dirs are root-owned: expand the glob inside a root shell.
    log "collecting .debs -> $OUTDIR"
    sudo bash -c "cp \"$CHROOT\"/root/build/*.deb \"$OUTDIR\"/"
    sudo chown "$USER":"$USER" "$OUTDIR"/*.deb
}

# ---------------------------------------------------------------- frpc repack

build_frpc() {
    local tarball="frp_${VER}_linux_arm_hf.tar.gz"
    local base="https://github.com/fatedier/frp/releases/download/${PIN_VERSION}"

    log "downloading $base/$tarball"
    curl -fsSL -o "$WORK/$tarball" "$base/$tarball"
    curl -fsSL -o "$WORK/frp_sha256_checksums.txt" "$base/frp_sha256_checksums.txt"

    log "verifying sha256"
    local sumline
    sumline=$(awk -v f="$tarball" '$NF == f {print $1 "  " $NF}' "$WORK/frp_sha256_checksums.txt")
    [ -n "$sumline" ] || die "no checksum entry for $tarball in frp_sha256_checksums.txt"
    (cd "$WORK" && echo "$sumline" | sha256sum --check -)

    mkdir -p "$WORK/x"
    tar xzf "$WORK/$tarball" -C "$WORK/x"
    local root="$WORK/x/frp_${VER}_linux_arm_hf"
    [ -f "$root/frpc" ] || die "frpc binary missing in tarball"
    [ -f "$root/frpc.toml" ] || die "frpc.toml sample config missing in tarball"

    local stage="$WORK/stage"
    mkdir -p "$stage/usr/bin" "$stage/etc/frp" "$stage/lib/systemd/system" "$stage/usr/share/doc/frpc"
    cp "$root/frpc" "$stage/usr/bin/frpc"
    cp "$root/frpc.toml" "$stage/etc/frp/frpc.toml"
    cp "$root/LICENSE" "$stage/usr/share/doc/frpc/LICENSE"
    cp "$REPO/packaging/frpc/frpc.service" "$stage/lib/systemd/system/frpc.service"
    cp "$REPO/packaging/frpc/copyright" "$stage/usr/share/doc/frpc/copyright"
    cp -a "$REPO/packaging/frpc/DEBIAN" "$stage/DEBIAN"
    sed -i "s/^Version:.*/Version: ${DEBVER}/" "$stage/DEBIAN/control"
    chmod 755 "$stage/DEBIAN/postinst"

    local out="$OUTDIR/frpc_${DEBVER}_armhf.deb"
    dpkg-deb --build --root-owner-group "$stage" "$out"
    log "built $out"
}

# ---------------------------------------------------------------- noip-duc republish

build_noip_duc() {
    local sha
    sha=$(pin_get sha256)
    [ -n "$sha" ] || die "pin file missing sha256:"

    log "downloading $PIN_URL"
    curl -fsSL -o "$WORK/noip-duc.tar.gz" "$PIN_URL"

    log "verifying sha256"
    (cd "$WORK" && echo "$sha  noip-duc.tar.gz" | sha256sum --check -)

    tar xzf "$WORK/noip-duc.tar.gz" -C "$WORK"
    local deb
    deb=$(find "$WORK" -mindepth 2 -name 'noip-duc_*_armhf.deb' | head -n1)
    [ -n "$deb" ] || die "no noip-duc_*_armhf.deb inside the tarball"
    cp "$deb" "$OUTDIR/"
    log "republished $(basename "$deb") (official No-IP deb, verbatim)"
}

# ---------------------------------------------------------------- dispatch

case "$NAME" in
    libacars)
        build_src_pkg "https://github.com/szpajder/libacars/archive/refs/tags/${PIN_VERSION}.tar.gz" \
            zlib1g-dev libxml2-dev libjansson-dev
        ;;
    dumphfdl)
        build_src_pkg "https://github.com/szpajder/dumphfdl/archive/refs/tags/${PIN_VERSION}.tar.gz" \
            libfftw3-dev libglib2.0-dev libconfig++-dev libsoapysdr-dev libzmq3-dev librdkafka-dev libliquid-dev libsqlite3-dev
        ;;
    frpc)     build_frpc ;;
    noip-duc) build_noip_duc ;;
esac

log "done: $NAME -> $OUTDIR"
ls -l "$OUTDIR"
