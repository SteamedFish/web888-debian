#!/usr/bin/env bash
# install-boot-deb.sh — install the web888-boot deb built by
# build-boot-deb.sh into work/rootfs (chain=uboot). Same pattern as
# install-kernel-deb.sh: dpkg -i inside the chroot.
#
# The postinst skips the /boot/firmware write here (no
# /boot/firmware/boot.bin inside the
# chroot — the FAT partition only exists at image-flash time), so this
# only stages the payload to /usr/lib/web888-boot/. build-image.sh then
# populates the FAT partition FROM THAT PAYLOAD, making the deb the single
# source of truth for the bootloader — on the card and for later upgrades.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOTFS=work/rootfs
DEB=$(ls output/boot/web888-boot_*_armhf.deb 2>/dev/null | head -1)

[[ -n $DEB ]] || {
    echo "error: no output/boot/web888-boot_*_armhf.deb (run build-boot-deb.sh first)" >&2
    exit 1
}
[[ -d $ROOTFS/usr/bin ]] || {
    echo "error: $ROOTFS missing (run debootstrap steps first)" >&2
    exit 1
}

echo "==> staging $(basename "$DEB") into rootfs"
sudo mkdir -p "$ROOTFS"/tmp/debs
sudo cp "$DEB" "$ROOTFS"/tmp/debs/

echo "==> dpkg install"
sudo chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    bash -c 'dpkg -i /tmp/debs/web888-boot_*_armhf.deb'

sudo rm -rf "$ROOTFS"/tmp/debs

echo "==> verify payload staged"
sudo chroot "$ROOTFS" bash -c '
    for f in boot.bin fsbl.bin u-boot.bin boot.scr uEnv.txt web888.dtb; do
        [[ -s /usr/lib/web888-boot/$f ]] || { echo "FATAL: /usr/lib/web888-boot/$f missing" >&2; exit 1; }
    done
    echo "    $(ls -l /usr/lib/web888-boot/boot.bin | awk "{print \$5}") bytes boot.bin"
'

echo "==> OK: web888-boot installed in rootfs (payload staged; FAT write happens in build-image.sh)"
