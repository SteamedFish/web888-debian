#!/usr/bin/env bash
# install-kernel-deb.sh — install the 6.12 linux-image deb built by
# build-kernel-6.12.sh into work/rootfs (step 6). Retires
# install-modules.sh for the new kernel flow: modules arrive via the deb
# and depmod runs inside the chroot (qemu-arm) — no host-side modules_install.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOTFS=work/rootfs
DEB=$(ls output/kernel/linux-image-*_armhf.deb 2>/dev/null | grep -v -- -dbg | head -1)

[[ -n $DEB ]] || {
    echo "error: no output/kernel/linux-image-*_armhf.deb (run build-kernel-6.12.sh first)" >&2
    exit 1
}
[[ -d $ROOTFS/usr/bin ]] || {
    echo "error: $ROOTFS missing (run debootstrap steps first)" >&2
    exit 1
}

echo "==> staging $(basename "$DEB") into rootfs"
sudo mkdir -p "$ROOTFS"/tmp/debs
sudo cp "$DEB" "$ROOTFS"/tmp/debs/

# dpkg -i, not apt-get: same-version debs are a silent no-op under apt
# (install-websdr.sh hit the stale-binary case first).
echo "==> dpkg install"
sudo chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    bash -c 'dpkg -i /tmp/debs/linux-image-*_armhf.deb'

sudo rm -rf "$ROOTFS"/tmp/debs

KREL=$(dpkg-deb -f "$DEB" Package | sed 's/^linux-image-//')
echo "==> verify modules for $KREL"
sudo chroot "$ROOTFS" bash -c "
    [[ -d /lib/modules/$KREL ]] || { echo 'FATAL: /lib/modules/$KREL missing' >&2; exit 1; }
    # bindeb-pkg's postinst does not always depmod; guarantee it here.
    [[ -f /lib/modules/$KREL/modules.dep ]] || depmod -a $KREL
    ls /lib/modules/$KREL/kernel/drivers/char/ | grep -E 'xilinx_devcfg|zynqsdr'
"

echo "==> OK: linux-image-$KREL installed in rootfs"
