#!/usr/bin/env bash
# flash-image.sh — write output/web888-debian.img to a removable USB SD reader.
#
# Hard guards (project AGENTS.md): target must be /dev/sdX on USB transport,
# never NVMe or internal disk; requires an exact-path type-confirm.
# The stock TF card is the rollback — do NOT flash it.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="${1:-}"
IMG="${2:-output/web888-debian.img}"

[[ -n $DEV ]] || { echo "usage: $0 /dev/sdX [image]" >&2; exit 1; }
[[ -f $IMG ]] || { echo "Error: $IMG missing (run build-image.sh)" >&2; exit 1; }
[[ $DEV == /dev/sd[a-z] ]] || { echo "REFUSED: '$DEV' is not /dev/sdX" >&2; exit 1; }

TRAN=$(lsblk --noheadings --output TRAN "$DEV" 2>/dev/null || true)
[[ $TRAN == usb ]] || { echo "REFUSED: $DEV transport='$TRAN' (required: usb)" >&2; exit 1; }

BUS=$(udevadm info --query=property --name="$DEV" | grep '^ID_BUS=' || true)
[[ $BUS == ID_BUS=usb ]] || { echo "REFUSED: $DEV $BUS (required: ID_BUS=usb)" >&2; exit 1; }

# Payload gate: the image must carry the web888-boot deb payload, or a later
# `apt upgrade web888-boot` on the device has nothing to install from.
LOOP=$(sudo -n losetup --find --show --partscan --read-only "$IMG")
trap 'sudo -n losetup -d "$LOOP" 2>/dev/null || true' EXIT
MNT=$(mktemp -d)
sudo -n mount -o ro,noload -t ext4 "${LOOP}p2" "$MNT"
ok=1
for f in boot.bin boot.scr uEnv.txt fsbl.bin u-boot.bin; do
  [[ -s $MNT/usr/lib/web888-boot/$f ]] || { echo "REFUSED: image lacks /usr/lib/web888-boot/$f" >&2; ok=0; }
done
magic=$(sudo -n od -An -tx1 -j32 -N4 "$MNT/usr/lib/web888-boot/boot.bin" 2>/dev/null | tr -d ' \n')
[[ $magic == 665599aa ]] || { echo "REFUSED: payload boot.bin has no Zynq boot header" >&2; ok=0; }
sudo -n umount "$MNT"
rmdir "$MNT"
[[ $ok -eq 1 ]] && echo "payload gate OK: web888-boot payload present in image"

echo "About to DESTROY all data on:"
lsblk --output NAME,SIZE,MODEL,TRAN,MOUNTPOINT "$DEV"
read -r -p "Type the exact device path ($DEV) to confirm: " CONFIRM
[[ $CONFIRM == "$DEV" ]] || { echo "aborted: confirmation mismatch" >&2; exit 1; }

sudo -n dd if="$IMG" of="$DEV" bs=4M status=progress oflag=sync conv=fsync
sync
echo "flashed OK. Insert into Web-888, power on, then watch for the unit's ce:cf:3f:* MAC on DHCP."
