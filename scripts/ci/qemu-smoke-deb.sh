#!/usr/bin/env bash
# qemu-smoke-deb.sh — pre-publish QEMU smoke gate for the deb publisher
# workflows (build-kernel-deb.yml, build-boot-deb.yml). Runs between the
# build and publish jobs so a deb that breaks boot never reaches the APT
# repo — previously the only QEMU gate lived in build-image.yml, which runs
# AFTER publish (bad deb already installable via apt upgrade).
#
# Recipe:
#   1. Build a baseline card image the DEB_SOURCE=apt way (all four project
#      debs from the published APT repo).
#   2. Overlay the deb(s) under test into work/rootfs via chroot dpkg -i
#      (dpkg, not apt: same-version debs are a silent no-op under apt — see
#      install-kernel-deb.sh).
#   3. Verify the package-specific payload and re-export the artifact(s)
#      QEMU/build-image consume (mirrors install-debs-apt.sh exports).
#   4. Rebuild the image and boot it in QEMU (test-qemu.sh uboot),
#      requiring the 'web888 login:' prompt in the serial log.
#
# Coverage note: the uboot QEMU mode loads U-Boot via -device loader and
# SKIPS the FSBL (see scripts/test-qemu.sh) — a broken FSBL inside
# web888-boot is NOT caught here; that residual risk is hardware-gate only.
#
# usage: qemu-smoke-deb.sh <deb> [<deb>...]   (*-dbg_* debs are skipped)
set -euo pipefail
cd "$(dirname "$0")/../.."

[[ $# -ge 1 ]] || { echo "usage: $0 <deb> [<deb>...]" >&2; exit 1; }

# Skip debug-symbol debs: install-kernel-deb.sh excludes them the same way,
# and package detection below needs a real payload deb first.
DEBS=()
for deb in "$@"; do
    [[ -f $deb ]] || { echo "Error: $deb not found" >&2; exit 1; }
    case $deb in
        *-dbg_*.deb) echo "   (skipping debug deb: $(basename "$deb"))" ;;
        *)           DEBS+=("$deb") ;;
    esac
done
[[ ${#DEBS[@]} -ge 1 ]] || { echo "Error: no non-debug debs given" >&2; exit 1; }

for cmd in debootstrap qemu-system-arm qemu-arm-static dpkg-deb; do
    command -v "$cmd" >/dev/null || { echo "Error: $cmd required (see build-image.yml install step)" >&2; exit 1; }
done

echo "== 1/4 baseline image from published debs (DEB_SOURCE=apt) =="
DEB_SOURCE=apt bash scripts/build-all.sh

echo "== 2/4 overlay deb(s) under test into work/rootfs =="
ROOTFS=work/rootfs
# policy-rc.d: suppress service start/restart inside the chroot (same trick
# as install-debs-apt.sh).
echo -e '#!/bin/sh\nexit 101' | sudo -n tee "$ROOTFS"/usr/sbin/policy-rc.d >/dev/null
sudo -n chmod +x "$ROOTFS"/usr/sbin/policy-rc.d

sudo -n mkdir --parents "$ROOTFS"/tmp/debs
sudo -n cp "${DEBS[@]}" "$ROOTFS"/tmp/debs/
sudo -n chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    bash -c 'dpkg -i /tmp/debs/*.deb'
sudo -n rm -rf "$ROOTFS"/tmp/debs
sudo -n rm -f "$ROOTFS"/usr/sbin/policy-rc.d

echo "== 3/4 verify payload, re-export QEMU/build-image artifacts =="
PKG=$(dpkg-deb -f "${DEBS[0]}" Package)
case $PKG in
    linux-image-*)
        KREL=${PKG#linux-image-}
        sudo -n chroot "$ROOTFS" bash -c "
            [[ -d /lib/modules/$KREL ]] || { echo 'FATAL: /lib/modules/$KREL missing' >&2; exit 1; }
            # bindeb-pkg's postinst does not always depmod; guarantee it here.
            [[ -f /lib/modules/$KREL/modules.dep ]] || depmod -a $KREL
            ls /lib/modules/$KREL/kernel/drivers/char/ | grep -E 'xilinx_devcfg|zynqsdr'
        "
        # FAT copy of the kernel (build-image.sh packs output/zImage).
        echo "==> export output/zImage from /boot/vmlinuz-$KREL"
        sudo -n cp "$ROOTFS/boot/vmlinuz-$KREL" output/zImage
        sudo -n chmod 0644 output/zImage
        ;;
    web888-boot)
        sudo -n chroot "$ROOTFS" bash -c '
            for f in boot.bin fsbl.bin u-boot.bin boot.scr uEnv.txt web888.dtb; do
                [[ -s /usr/lib/web888-boot/$f ]] || { echo "FATAL: /usr/lib/web888-boot/$f missing" >&2; exit 1; }
            done
        '
        # U-Boot for the QEMU gate loader (build-image.sh takes the rest of
        # the FAT payload straight from the rootfs).
        echo "==> export output/u-boot.bin from the deb payload"
        sudo -n cp "$ROOTFS/usr/lib/web888-boot/u-boot.bin" output/u-boot.bin
        sudo -n chmod 0644 output/u-boot.bin
        ;;
    *)
        echo "Error: no smoke-verify recipe for package '$PKG'" >&2
        exit 1
        ;;
esac

echo "==> rebuild card image with the deb under test"
bash scripts/build-image.sh uboot

echo "== 4/4 QEMU boot gate =="
bash scripts/test-qemu.sh uboot | tee output/qemu-test.log
grep -q 'web888 login:' output/qemu-test.log || {
    echo "Error: QEMU smoke gate FAILED — no login prompt within timeout" >&2
    exit 1
}
echo "== OK: $PKG boots in QEMU (web888 login: reached) =="
