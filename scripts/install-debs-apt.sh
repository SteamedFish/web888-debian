#!/usr/bin/env bash
# install-debs-apt.sh — DEB_SOURCE=apt path: install the four project debs
# (kernel, websdr, redpitaya, boot) from the web888 APT repo into
# work/rootfs, replacing the local deb build+install steps (8b-8f, 9b/9c).
#
# Verifications mirror the local installers' contracts:
#   install-kernel-deb.sh: /lib/modules/<krel> + depmod + our two ko's
#   install-websdr.sh:     binary present + service enabled (md5 compare is
#                          impossible here — no local deb to diff against)
#   install-boot-deb.sh:   /usr/lib/web888-boot/ payload staged (postinst's
#                          /boot write is skipped inside the chroot)
#
# Also exports the two output/ artifacts downstream steps consume:
#   output/zImage     <- rootfs /boot/vmlinuz-<krel> (FAT copy, test-qemu.sh)
#   output/u-boot.bin <- boot payload (test-qemu.sh uboot gate loader)
set -euo pipefail
cd "$(dirname "$0")/.."

ROOTFS=work/rootfs
[[ -d $ROOTFS/usr/bin ]] || {
    echo "Error: $ROOTFS missing (run debootstrap steps first)" >&2
    exit 1
}

# Kernel release string comes from the same KVER the CI kernel deb was built
# with — keep it derived, not duplicated.
KVER=$(sed -n 's/^KVER=//p' scripts/build-kernel-6.12.sh | head -1)
[[ -n $KVER ]] || { echo "Error: cannot derive KVER from build-kernel-6.12.sh" >&2; exit 1; }
KREL="${KVER}-web888"

bash scripts/setup-apt-repo.sh

# Suppress service start/restart inside the chroot, keep enablement (same
# policy-rc.d trick as install-websdr.sh).
echo -e '#!/bin/sh\nexit 101' | sudo -n tee "$ROOTFS"/usr/sbin/policy-rc.d >/dev/null
sudo -n chmod +x "$ROOTFS"/usr/sbin/policy-rc.d

echo "==> apt install web888 debs from the repo"
sudo -n chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    bash -c "apt-get update -qq && apt-get install -y --no-install-recommends \
        linux-image-${KREL} web888-websdr web888-redpitaya web888-boot"

sudo -n rm -f "$ROOTFS"/usr/sbin/policy-rc.d

echo "==> verify: packages"
sudo -n chroot "$ROOTFS" bash -c \
    "dpkg -l linux-image-${KREL} web888-websdr web888-redpitaya web888-boot | grep '^ii'"

echo "==> verify: kernel modules for $KREL"
sudo -n chroot "$ROOTFS" bash -c "
    [[ -d /lib/modules/$KREL ]] || { echo 'FATAL: /lib/modules/$KREL missing' >&2; exit 1; }
    [[ -f /lib/modules/$KREL/modules.dep ]] || depmod -a $KREL
    ls /lib/modules/$KREL/kernel/drivers/char/ | grep -E 'xilinx_devcfg|zynqsdr'
"

echo "==> verify: websdr"
sudo -n chroot "$ROOTFS" bash -c \
    '[[ -x /usr/bin/websdr.bin ]] && systemctl is-enabled web888-websdr.service'

echo "==> verify: boot payload staged"
sudo -n chroot "$ROOTFS" bash -c '
    for f in boot.bin fsbl.bin u-boot.bin boot.scr uEnv.txt web888.dtb; do
        [[ -s /usr/lib/web888-boot/$f ]] || { echo "FATAL: /usr/lib/web888-boot/$f missing" >&2; exit 1; }
    done
'

echo "==> export output/ artifacts for build-image.sh / test-qemu.sh"
mkdir --parents output
sudo -n cp "$ROOTFS/boot/vmlinuz-$KREL" output/zImage
sudo -n chmod 0644 output/zImage
sudo -n cp "$ROOTFS/usr/lib/web888-boot/u-boot.bin" output/u-boot.bin
sudo -n chmod 0644 output/u-boot.bin

echo "==> OK: all four debs installed from the APT repo"
