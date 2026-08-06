#!/usr/bin/env bash
# install-modules.sh — install the kernel modules built by build-kernel.sh
# into the debootstrapped rootfs (work/rootfs is root-owned → sudo).
# Idempotent: safe to re-run after every kernel build. depmod runs on the
# host (kmod's depmod is arch-agnostic) so modprobe works on first boot.
set -euo pipefail

cd "$(dirname "$0")/.."
KDIR=work/linux-xlnx
CROSS=arm-linux-gnueabihf-
ROOTFS="$(readlink --canonicalize work/rootfs)"

[[ -d "$KDIR" ]] || { echo "Error: $KDIR missing (run build-kernel.sh)" >&2; exit 1; }
[[ -d "$ROOTFS/etc" ]] || {
    echo "Error: $ROOTFS is not a populated rootfs (run debootstrap first)" >&2
    exit 1
}

KREL=$(make -s -C "$KDIR" ARCH=arm CROSS_COMPILE="$CROSS" kernelrelease </dev/null)

sudo -n make -C "$KDIR" ARCH=arm CROSS_COMPILE="$CROSS" \
    INSTALL_MOD_PATH="$ROOTFS" modules_install </dev/null

# modules_install only runs depmod when it finds one at build time and skips
# it for cross builds on some hosts; run it explicitly to be sure.
sudo -n depmod -b "$ROOTFS" "$KREL"

echo "modules installed: $ROOTFS/lib/modules/$KREL"
ls "$ROOTFS/lib/modules/$KREL"/kernel/drivers/char/ 2>/dev/null || true
