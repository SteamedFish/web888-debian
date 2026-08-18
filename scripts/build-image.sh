#!/usr/bin/env bash
# build-image.sh — assemble the card image.
# Layout: p1 = 64 MiB FAT32 firmware (boot.bin + boot.scr + uEnv.txt +
#         web888.dtb; the kernel lives in the rootfs /boot),
#         p2 = ext4 rootfs (contents of work/rootfs/).
# Partition table is plain MBR (msdos), NOT GPT: the Zynq-7000 BootROM finds
# BOOT.BIN by parsing the MBR partition table and does NOT understand GPT —
# a GPT image (single 0xEE protective entry) gives it no FAT partition to
# read → card does not boot (observed: D2 LED stays on forever).
# The stock card is plain MBR too. Linux does not care either way at 2 GiB.
#
# usage: build-image.sh [test|final|uboot] → output/web888-debian-<mode>.img
#   uboot — FAT carries boot.bin (FSBL+U-Boot), boot.scr + uEnv.txt +
#           web888.dtb (no-bootargs variant — bootargs live in boot.scr,
#           NOT the dtb) taken from the web888-boot deb payload installed
#           in the rootfs (work/rootfs/usr/lib/web888-boot/ — the deb is
#           the single source of truth for the bootloader). The kernel is
#           NOT on the FAT: boot.scr ext4-loads /boot/zImage (a symlink
#           into the kernel deb payload) from the rootfs partition.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-test}"
IMG=output/web888-debian-${MODE}.img
# The card's real capacity comes from web888-growroot at first boot, so the
# image only has to hold the payload: cleaned rootfs is ~540 MB (2026-08)
# + 64 MiB FAT, leaving ~420 MB headroom at 1024. Smaller image = less dd
# time on flash and a smaller .img.xz release asset. Grow the payload past
# ~900 MB and this must go up.
SIZE_MB=1024

[[ $MODE == test || $MODE == final || $MODE == uboot ]] || { echo "usage: $0 [test|final|uboot]" >&2; exit 1; }

DTB=output/web888.dtb
[[ $MODE == test ]] && DTB=output/web888-test.dtb

# output/zImage only feeds the stub chain (embedded into boot.bin) and the
# QEMU -kernel modes — uboot mode boots the rootfs /boot/zImage instead.
if [[ $MODE != uboot ]]; then
    [[ -f output/zImage ]] || { echo "Error: missing output/zImage (kernel build, or install-debs-apt.sh export)" >&2; exit 1; }
fi
# uboot mode never reads output/boot-uboot.bin (the FAT boot.bin comes from
# the deb payload below), so only test/final require output/boot-$MODE.bin.
if [[ $MODE != uboot ]]; then
    [[ -f output/boot-${MODE}.bin ]] || { echo "Error: missing output/boot-${MODE}.bin (run build-bootbin.sh $MODE)" >&2; exit 1; }
fi
# test/final embed the bootargs-carrying dtb (built by build-bootbin.sh) in
# boot.bin, so it must exist beforehand. uboot takes the no-bootargs dtb
# from the web888-boot deb payload below (bootargs live in boot.scr), so
# requiring it here would demand a stub-chain leftover.
if [[ $MODE != uboot ]]; then
    [[ -f $DTB ]] || { echo "Error: missing $DTB (run build-bootbin.sh $MODE)" >&2; exit 1; }
fi
# The stub chain (test/final) boots kernel+dtb from partitions EMBEDDED in
# boot.bin — the FAT copies are vestigial. A stale boot.bin silently boots
# old kernel/dtb while QEMU (-kernel/-dtb) validates the new ones: refuse
# to pack when boot.bin is older than its inputs (cost two flash cycles
#).
if [[ $MODE != uboot ]]; then
    if [[ output/boot-${MODE}.bin -ot output/zImage || output/boot-${MODE}.bin -ot config/web888.dts ]]; then
        echo "Error: output/boot-${MODE}.bin is stale (kernel/dtb are embedded — run build-bootbin.sh $MODE)" >&2
        exit 1
    fi
fi
[[ -d work/rootfs/etc ]] || { echo "Error: work/rootfs not populated (run configure-rootfs.sh)" >&2; exit 1; }

if [[ $MODE == uboot ]]; then
    [[ -L work/rootfs/boot/zImage ]] || { echo "Error: work/rootfs/boot/zImage symlink missing (kernel hook did not run in chroot)" >&2; exit 1; }
fi

if [[ $MODE == uboot ]]; then
    # dtb WITHOUT bootargs (boot.scr supplies them) ships in the web888-boot
    # deb payload — use it verbatim (identical bits to what an on-device apt
    # upgrade installs) instead of recompiling against a kernel source tree.
    PAYLOAD_DTB=work/rootfs/usr/lib/web888-boot/web888.dtb
    [[ -f $PAYLOAD_DTB ]] || { echo "Error: $PAYLOAD_DTB missing (web888-boot deb not installed in rootfs?)" >&2; exit 1; }
    sudo -n cp "$PAYLOAD_DTB" "$DTB"
fi

dd if=/dev/zero of="$IMG" bs=1M count="$SIZE_MB" status=none
parted --script "$IMG" \
    mklabel msdos \
    mkpart primary fat32 1MiB 65MiB \
    mkpart primary ext4 65MiB 100% \
    set 1 boot on

LOOP=$(sudo -n losetup --find --show --partscan "$IMG")
MNT=$(mktemp -d)
trap 'sudo -n umount -q "$MNT" 2>/dev/null; sudo -n losetup -d "$LOOP" 2>/dev/null || true' EXIT

# --partscan is asynchronous: the ${LOOP}p1/p2 nodes appear only once the
# kernel (and udev, where /dev is udev-managed) has re-read the table, so
# mkfs can race node creation and fail with "No such file or directory".
# Poll briefly; on failure exit AFTER the trap is armed so the loop device
# is detached. Bounded at ~5 s — a missing node never resolves later.
for _ in {1..50}; do
    [[ -b ${LOOP}p1 && -b ${LOOP}p2 ]] && break
    sleep 0.1
done
[[ -b ${LOOP}p1 && -b ${LOOP}p2 ]] || { echo "Error: ${LOOP}p1/p2 partition nodes did not appear" >&2; exit 1; }

sudo -n mkfs.vfat -F 32 -n BOOT "${LOOP}p1"
sudo -n mkfs.ext4 -q -L rootfs "${LOOP}p2"

sudo -n mount "${LOOP}p1" "$MNT"
if [[ $MODE == uboot ]]; then
    # boot.bin/boot.scr/uEnv.txt come from the deb payload in the rootfs,
    # not output/: identical bits to what a future deb upgrade installs.
    PAYLOAD=work/rootfs/usr/lib/web888-boot
    for f in boot.bin boot.scr uEnv.txt; do
        [[ -f $PAYLOAD/$f ]] || { echo "Error: $PAYLOAD/$f missing (run install-boot-deb.sh)" >&2; exit 1; }
    done
    sudo -n cp "$PAYLOAD/boot.bin" "$MNT/boot.bin"
    sudo -n cp "$PAYLOAD/boot.scr" "$MNT/boot.scr"
    sudo -n cp "$PAYLOAD/uEnv.txt" "$MNT/uEnv.txt"
    else
    sudo -n cp "output/boot-${MODE}.bin" "$MNT/boot.bin"
    # Stub chain embeds kernel+dtb inside boot.bin; the FAT zImage copy is
    # vestigial but kept for manual recovery with a stock bootloader.
    sudo -n cp output/zImage "$MNT/zImage"
fi
sudo -n cp "$DTB" "$MNT/web888.dtb"
sudo -n umount "$MNT"

sudo -n mount "${LOOP}p2" "$MNT"
# Ship-clean exclusions (excluded, not deleted, so work/rootfs keeps its apt
# cache for incremental rebuilds):
#   machine-id / random-seed — per-unit identity + entropy must be minted on
#     the device (systemd regenerates both at first boot); a shipped value
#     would be shared by every flashed card. var/lib/dbus/machine-id is a
#     byte-identical copy of etc/machine-id here (created during the chroot
#     build), so it must go too.
#   /var/cache/apt + /var/lib/apt/lists — ~260 MB of package cache/lists;
#     on-device apt update refetches the lists.
sudo -n rsync -a \
    --exclude='/etc/machine-id' \
    --exclude='/var/lib/dbus/machine-id' \
    --exclude='/var/lib/systemd/random-seed' \
    --exclude='/var/cache/apt/*' \
    --exclude='/var/lib/apt/lists/*' \
    work/rootfs/ "$MNT/"
sudo -n umount "$MNT"

rmdir "$MNT"
sudo -n losetup -d "$LOOP"
trap - EXIT

echo "image ready: $IMG ($(du -h "$IMG" | cut -f1))"
