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

# deb.debian.org (Fastly) occasionally resets connections mid-fetch
# ("OpenSSL ... Connection reset by peer"), killing whole chroot builds.
# Every in-chroot apt call retries via this dropin; debootstrap itself
# is wrapped in a retry loop below.
write_apt_retries() {
    echo 'Acquire::Retries "10";' | sudo tee "$CHROOT/etc/apt/apt.conf.d/80ci-retries" >/dev/null
}

log "chroot: $CHROOT (mirror: $MIRROR)"

if [ -f "$CHROOT/usr/bin/dpkg-buildpackage" ]; then
    # Reuse path: cached chroot — bring it fully up to date first, so
    # ${shlibs:Depends} minimum versions in built debs match the CURRENT
    # archive (upgraded users can install; stale users get libs pulled).
    log "chroot exists; refreshing (apt-get update + full-upgrade)"
    write_apt_retries
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
for attempt in 1 2 3; do
    if sudo debootstrap --arch=armhf \
        --include=ca-certificates \
        --components=main,contrib,non-free,non-free-firmware \
        trixie "$CHROOT" "$MIRROR"; then
        break
    fi
    if (( attempt == 3 )); then
        log "debootstrap failed after 3 attempts"; exit 1
    fi
    log "debootstrap attempt $attempt failed; cleaning and retrying in 20s"
    # Only the tmpfs itself may be mounted at this point (no bind mounts are
    # ever created under this chroot); refuse to clean if anything else is
    # mounted underneath (AGENTS.md scratch-chroot rule).
    if findmnt -rn -o TARGET "$CHROOT" | grep -vx "$CHROOT" | grep -q .; then
        log "child mounts under $CHROOT — refusing to clean"; exit 1
    fi
    sudo find "$CHROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    sleep 20
done
sudo cp "$(command -v qemu-arm-static)" "$CHROOT/usr/bin/"
write_apt_retries
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
