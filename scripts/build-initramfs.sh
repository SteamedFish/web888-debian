#!/usr/bin/env bash
# build-initramfs.sh — assemble the first-boot busybox initramfs.
# Run from the repo root or worktree. Output: output/initramfs.cpio.gz
#
# Contains: static busybox (Debian armhf .deb) + config/initramfs-init.
# No device nodes are archived — the kernel populates /dev via devtmpfs
# (CONFIG_DEVTMPFS_MOUNT=y in config/kernel-web888.fragment), so no root
# privileges are needed to pack the image.
set -euo pipefail

cd "$(dirname "$0")/.."
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"
BUSYBOX_DEB_VERSION=1.38.0-3
STAGING=work/initramfs

for cmd in wget bsdtar cpio gzip; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Error: $cmd required (see scripts/env-setup.sh)" >&2
        exit 1
    }
done

# Prefer the vendored copy: Debian removes superseded versions from the pool,
# so the pinned URL will eventually 404 (see resources/README.md).
deb=work/downloads/busybox-static_${BUSYBOX_DEB_VERSION}_armhf.deb
if [[ -f "resources/busybox-static_${BUSYBOX_DEB_VERSION}_armhf.deb" ]]; then
    mkdir --parents work/downloads
    cp "resources/busybox-static_${BUSYBOX_DEB_VERSION}_armhf.deb" "$deb"
elif [[ ! -f "$deb" ]]; then
    mkdir --parents work/downloads
    wget --show-progress -O "$deb" \
        "$DEBIAN_MIRROR/pool/main/b/busybox/busybox-static_${BUSYBOX_DEB_VERSION}_armhf.deb"
fi

rm -rf "$STAGING"
mkdir --parents "$STAGING"/{bin,proc,sys,dev,newroot}

tmp="$(mktemp --directory)"
trap 'rm -rf "$tmp"' EXIT
bsdtar -xf "$deb" -C "$tmp" data.tar.xz
bsdtar -xf "$tmp/data.tar.xz" -C "$tmp" usr/bin/busybox
cp "$tmp/usr/bin/busybox" "$STAGING/bin/busybox"
chmod 755 "$STAGING/bin/busybox"

# Applet symlinks for everything the init script calls.
# `busybox --install -s <dir>` would bake the HOST-absolute $STAGING path into
# link targets (busybox resolves its own argv[0] path on the host), leaving
# every symlink dangling inside the initramfs. Link to the image-absolute
# /bin/busybox instead — valid once the image is the root filesystem.
"$STAGING/bin/busybox" --list | while IFS= read -r app; do
    [[ "$app" == busybox ]] && continue
    ln --symbolic --force busybox "$STAGING/bin/$app"
done

cp config/initramfs-init "$STAGING/init"
chmod 755 "$STAGING/init"

mkdir --parents output
(cd "$STAGING" && find . -print0 | cpio --null --create --format=newc) |
    gzip -9 >output/initramfs.cpio.gz

size=$(stat --format=%s output/initramfs.cpio.gz)
echo "initramfs: $size bytes (SSBL contract: <= $((4 * 1024 * 1024)) compressed)"
if [[ $size -gt $((4 * 1024 * 1024)) ]]; then
    echo "Error: initramfs exceeds the initrd=0x3000000,4M contract" >&2
    exit 1
fi
