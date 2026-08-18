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
#   output/zImage     <- rootfs /boot/vmlinuz-<krel> (stub chain + QEMU
#                        -kernel modes only; the uboot chain boots the
#                        rootfs /boot/zImage symlink instead)
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

# apt-get update can race a deb publisher mid-push: the repo sits behind a
# CDN whose edge nodes briefly serve a stale Packages.gz against the new
# Release file ("File has unexpected size ... Mirror sync in progress?"),
# which apt treats as a hard failure. Retry until the index settles —
# worst case is one edge-cache TTL (~10 min).
echo "==> apt update (retry while the repo index settles)"
for attempt in $(seq 1 20); do
    if sudo -n chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        apt-get update -qq; then
        break
    fi
    if (( attempt == 20 )); then
        echo "install-debs-apt.sh: apt-get update still failing after $attempt attempts" >&2
        exit 1
    fi
    echo "install-debs-apt.sh: apt-get update failed (attempt $attempt/20) — waiting 30s for the repo index to settle" >&2
    sleep 30
done

echo "==> apt install web888 debs from the repo"
sudo -n chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    apt-get install -y --no-install-recommends \
        linux-image-${KREL} web888-websdr web888-redpitaya web888-boot

# noip-duc + frpc (web888-websdr Depends) postinsts self-enable, but both
# packages are unconfigured (no /etc/default/noip-duc, no frpc.ini) →
# guaranteed start failure on every boot (frpc crash-loops on RestartSec=5s).
# Disable here; configure-rootfs.sh's 99-web888.preset keeps them off across
# the first-boot preset pass. Users who configure them can re-enable.
sudo -n chroot "$ROOTFS" /usr/bin/systemctl disable noip-duc.service frpc.service 2>/dev/null || true

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

echo "==> ensure: /boot/zImage symlink exists (heal repo/deb skew)"
# The link is normally created during the apt install above by web888-boot's
# kernel hook (or its postinst fallback). Heal it when the APT repo still
# carries a pre-hook web888-boot: without this, a hook/layout change in
# web888-boot is a bootstrap deadlock — the build-boot-deb smoke gate builds
# its baseline from the PUBLISHED repo, so a verify-only check can never
# pass with the old deb, and the fixed deb can never be published (observed
# 2026-08-18: ci17 predated the hook; build-boot-deb #18 + build-image
# #17/#18 all red until the deb could be published). The image builder owns
# the final rootfs state, and build-image.sh uboot mode cannot assemble
# without the link. A heal is logged loudly: with a current web888-boot in
# the repo, needing one IS a hook regression.
sudo -n chroot "$ROOTFS" bash -c "
    if [[ ! -L /boot/zImage && -f /boot/vmlinuz-$KREL ]]; then
        echo 'WARNING: /boot/zImage missing after deb install — healing (repo web888-boot predates the kernel hook?)' >&2
        # ci17-era hooks deliberately no-op inside a chroot (they guarded on
        # /boot/boot.bin, absent here — observed 2026-08-18: hook ran, link
        # still missing, verify FATAL). So never TRUST the hook: fall through
        # to a direct symlink whenever the link is still missing afterwards.
        if [[ -x /etc/kernel/postinst.d/zz-web888-zimage ]]; then
            /etc/kernel/postinst.d/zz-web888-zimage $KREL /boot/vmlinuz-$KREL || true
        fi
        [[ -L /boot/zImage ]] || ln -sfn vmlinuz-$KREL /boot/zImage
    fi
"

echo "==> verify: /boot/zImage symlink (kernel hook ran in chroot)"
sudo -n chroot "$ROOTFS" bash -c "
    [[ -L /boot/zImage ]] || { echo 'FATAL: /boot/zImage symlink missing (web888-boot kernel hook did not run)' >&2; exit 1; }
    target=\$(readlink /boot/zImage)
    [[ \$target == vmlinuz-$KREL ]] || { echo \"FATAL: /boot/zImage -> \$target, expected vmlinuz-$KREL\" >&2; exit 1; }
"

echo "==> export output/ artifacts for build-image.sh / test-qemu.sh"
mkdir --parents output
sudo -n cp "$ROOTFS/boot/vmlinuz-$KREL" output/zImage
sudo -n chmod 0644 output/zImage
sudo -n cp "$ROOTFS/usr/lib/web888-boot/u-boot.bin" output/u-boot.bin
sudo -n chmod 0644 output/u-boot.bin

echo "==> OK: all four debs installed from the APT repo"
