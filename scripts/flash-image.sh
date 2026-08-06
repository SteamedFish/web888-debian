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

echo "About to DESTROY all data on:"
lsblk --output NAME,SIZE,MODEL,TRAN,MOUNTPOINT "$DEV"
read -r -p "Type the exact device path ($DEV) to confirm: " CONFIRM
[[ $CONFIRM == "$DEV" ]] || { echo "aborted: confirmation mismatch" >&2; exit 1; }

sudo -n dd if="$IMG" of="$DEV" bs=4M status=progress oflag=sync conv=fsync
sync
echo "flashed OK. Insert into Web-888, power on, then watch for the unit's ce:cf:3f:* MAC on DHCP."
