#!/usr/bin/env bash
# Create the armhf websdr build chroot on tmpfs (/tmp/websdr-build).
#
# btrfs work/ lost this directory twice (entries gone with stale parent
# mtime — not a normal unlink). tmpfs eliminates the btrfs variable;
# chroot is cheap to rebuild.
#
# Idempotent: skips debootstrap if /tmp/websdr-build/usr/bin/chroot exists,
# but refreshes the chroot (apt-get update + full-upgrade) on every reuse so
# debs always build against the latest trixie libraries.

set -euo pipefail
cd "$(dirname "$0")/.."

CHROOT=${WEB888_BUILD_CHROOT:-/tmp/websdr-build}
MIRROR=${DEBIAN_MIRROR:-http://mirrors.tuna.tsinghua.edu.cn/debian}

if [[ -x $CHROOT/usr/bin/cmake ]]; then
    # Reuse path: cached chroot — bring it fully up to date first, so
    # ${shlibs:Depends} minimum versions in built debs match the CURRENT
    # archive (upgraded users can install; stale users get libs pulled).
    sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin bash -c '
            apt-get update -qq
            apt-get -y full-upgrade
        '
    echo "chroot ready: $CHROOT (reused, apt refreshed)"
    exit 0
fi

if ! findmnt -n "$CHROOT" >/dev/null 2>&1; then
    sudo mkdir -p "$CHROOT"
    sudo mount -t tmpfs -o size=8G tmpfs "$CHROOT"
fi

if [[ ! -d $CHROOT/debootstrap ]]; then
    sudo debootstrap --arch=armhf --include=ca-certificates \
        --components=main,contrib,non-free,non-free-firmware \
        trixie "$CHROOT" "$MIRROR"
fi

sudo cp "$(command -v qemu-arm-static)" "$CHROOT/usr/bin/"

sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin bash -c '
        apt-get update -qq
        # Fresh debootstrap: upgrade to the latest trixie BEFORE installing
        # Build-Depends, so debs are compiled against current archive libs.
        apt-get -y full-upgrade
        apt-get install -y --no-install-recommends \
            build-essential cmake pkg-config dpkg-dev devscripts debhelper git \
            ca-certificates quilt libfftw3-dev zlib1g-dev libfdk-aac-dev \
            libgps-dev libunwind-dev libsqlite3-dev libcurl4-openssl-dev \
            libssl-dev libconfig++-dev
    '

echo "chroot ready: $CHROOT (tmpfs)"
