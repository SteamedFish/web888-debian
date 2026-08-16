#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# mk-build-chroot.sh — create/update a generic armhf Debian trixie build
# chroot (qemu-user) for CI. Unlike scripts/mk-websdr-chroot.sh this is
# package-agnostic: only the base toolchain is installed; per-package build
# dependencies are installed by scripts/ci/build-thirdparty-deb.sh.
#
# Environment:
#   CI_BUILD_CHROOT  chroot location   (default /tmp/web888-ci-chroot)
#   DEBIAN_MIRROR    debootstrap mirror (default https://deb.debian.org/debian)
#
# Requires: sudo, debootstrap, qemu-arm-static (binfmt must be registered;
# on GitHub ubuntu-24.04 the workflow installs qemu-user-static).

set -euo pipefail
cd "$(dirname "$0")/.."

CHROOT=${CI_BUILD_CHROOT:-/tmp/web888-ci-chroot}
MIRROR=${DEBIAN_MIRROR:-https://deb.debian.org/debian}

log() { echo "[mk-build-chroot] $*"; }

log "chroot: $CHROOT (mirror: $MIRROR)"

if [ -f "$CHROOT/usr/bin/dpkg-buildpackage" ]; then
    # Reuse path: cached chroot — bring it fully up to date first, so
    # ${shlibs:Depends} minimum versions in built debs match the CURRENT
    # archive (upgraded users can install; stale users get libs pulled).
    log "chroot exists; refreshing (apt-get update + full-upgrade)"
    sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin bash -c '
            apt-get update -qq
            apt-get -y full-upgrade
        '
    echo "chroot ready: $CHROOT (reused, apt refreshed)"
    exit 0
fi

log "creating armhf trixie chroot..."
sudo mkdir -p "$CHROOT"
if ! findmnt "$CHROOT" >/dev/null 2>&1; then
    sudo mount -t tmpfs -o size=8G tmpfs "$CHROOT"
fi
sudo debootstrap --arch=armhf \
    --include=ca-certificates \
    --components=main,contrib,non-free,non-free-firmware \
    trixie "$CHROOT" "$MIRROR"
sudo cp "$(command -v qemu-arm-static)" "$CHROOT/usr/bin/"
log "installing base build toolchain"
sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    bash -c '
        apt-get update -qq
        # Fresh debootstrap: upgrade to the latest trixie BEFORE installing
        # Build-Depends, so debs are compiled against current archive libs.
        apt-get -y full-upgrade
        apt-get install -y --no-install-recommends build-essential cmake pkg-config dpkg-dev devscripts debhelper git ca-certificates curl
    '

echo "chroot ready: $CHROOT (tmpfs)"
