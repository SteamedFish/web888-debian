#!/usr/bin/env bash
# build-bootbin.sh — repack boot.bin from the source-built FSBL (default) or
# stock FSBL+SSBL, plus our DTB and zImage, per docs/research/bootbin-repack-spec.md.
#
# usage: build-bootbin.sh [test|final|uboot]
#   test  — dtb with initrd= bootargs + initramfs @ 0x03000000 (first-boot gate)
#   final — dtb with root=/dev/mmcblk0p2 bootargs, no initramfs (direct ext4 boot)
#   uboot — step 6: FSBL + mainline U-Boot (u-boot-dtb.bin) as the
#           SSBL partition; kernel/dtb/bootargs move to the FAT partition
#           (boot.scr/uEnv.txt). Stub modes stay as the rollback.
#
# FSBL=source (default, hardware-verified) packs the source-built
# output/fsbl/fsbl.bin from scripts/build-fsbl.sh. FSBL=stock is the escape
# hatch: packs the FSBL extracted from the stock boot.bin. (QEMU's
# test-qemu.sh uboot gate skips the FSBL entirely, so it cannot vet it;
# hardware verification is documented in docs/dev/CHANGELOG.md.) Only the
# [bootloader] partition and the header-patch length change; everything else
# is identical.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-test}"
FSBL="${FSBL:-source}"
# Extracted from resources/stock/web888-boot.bin by build-all.sh step 4.
STOCK=work/stock
BIF=work/bootgen-${MODE}.bif
DTB=output/web888.dtb
[[ $MODE == test ]] && DTB=output/web888-test.dtb

[[ $MODE == test || $MODE == final || $MODE == uboot ]] || { echo "usage: $0 [test|final|uboot]" >&2; exit 1; }
case "$FSBL" in
    stock)  FSBL_BIN="$STOCK/fsbl.bin" ;;
    source) FSBL_BIN=output/fsbl/fsbl.bin ;;
    *)      echo "Error: FSBL must be 'stock' or 'source' (got '$FSBL')" >&2; exit 1 ;;
esac
[[ -f $FSBL_BIN ]] || {
    echo "Error: missing $FSBL_BIN$([[ $FSBL == source ]] && echo ' (run scripts/build-fsbl.sh)')" >&2
    exit 1
}
FSBL_LEN=$(stat --format=%s "$FSBL_BIN")
echo "FSBL: $FSBL — $FSBL_BIN ($FSBL_LEN bytes)"

if [[ $MODE == uboot ]]; then
    for f in output/u-boot.bin work/tools/bootgen; do
        [[ -f $f ]] || { echo "Error: missing $f (run build-uboot.sh)" >&2; exit 1; }
    done
    {
        echo 'the_ROM_image:'
        echo '{'
        echo "    [bootloader] $FSBL_BIN"
        echo "    [load = 0x04000000, startup = 0x04000000] output/u-boot.bin"
        echo '}'
    } > "$BIF"
    ./work/tools/bootgen -image "$BIF" -arch zynq -o "output/boot-${MODE}.bin" -w
    # Same bootgen header-word patch as the stub chain (see below).
    python3 - "output/boot-${MODE}.bin" "$FSBL_LEN" <<'PY'
import struct, sys
path, fsbl_len = sys.argv[1], int(sys.argv[2])
with open(path, 'r+b') as f:
    f.seek(0x34); f.write(struct.pack('<I', fsbl_len))
    f.seek(0x40); f.write(struct.pack('<I', fsbl_len))
    f.seek(0x20); words = struct.unpack('<10I', f.read(40))
    f.seek(0x48); f.write(struct.pack('<I', (~sum(words)) & 0xFFFFFFFF))
PY
    echo "output/boot-${MODE}.bin: $(stat --format=%s "output/boot-${MODE}.bin") bytes"
    exit 0
fi

for f in "$STOCK/ssbl.bin" output/zImage work/tools/bootgen; do
    [[ -f $f ]] || { echo "Error: missing $f" >&2; exit 1; }
done

# The stock SSBL sets no ATAGS/DTB initrd properties, so on hardware the
# initrd location must come from DTB bootargs (QEMU -append overrides them).
if [[ $MODE == test ]]; then
    [[ -f output/initramfs.cpio.gz ]] || { echo "Error: output/initramfs.cpio.gz missing (run build-initramfs.sh)" >&2; exit 1; }
    SIZE=$(stat --format=%s output/initramfs.cpio.gz)
    if (( SIZE > 4194304 )); then
        echo "Error: initramfs $SIZE bytes exceeds 4 MiB SSBL contract" >&2
        exit 1
    fi
    bash scripts/write-dtb.sh "$DTB" "console=ttyPS0,115200 earlycon initrd=0x3000000,$SIZE"
else
    # fw_devlink=off — with fw_devlink=on (6.6 default) gem0's fwnode supplier
    # links can never resolve: phy-handle points at phy@1 on the MDIO bus that
    # macb's own probe registers (circular), and clkc is CLK_OF_DECLARE (never
    # becomes a struct device). The driver core then blocks e000b000.ethernet
    # before probe -> deferred forever -> no eth0. Observed in QEMU
    # (probe never entered; suppliers/ sysfs dirs absent = fwnode-level links).
    # net.ifnames=0 — udev predictable naming renames eth0 to end0, but
    # /etc/network/interfaces.d/eth0 says "auto eth0" -> ifupdown/dhcpcd fail
    # with "eth0: interface not found". Keep the kernel name.
    #
    # (netconsole + ignore_loglevel were removed: they were blind-boot debug
    # aids; the device boots reliably now and they only added noise. Early
    # boot/panic output is still captured by pstore/ramoops across reboots.)
    bash scripts/write-dtb.sh "$DTB" "console=ttyPS0,115200 earlycon root=/dev/mmcblk0p2 rw rootwait fw_devlink=off net.ifnames=0"
fi

{
    echo 'the_ROM_image:'
    echo '{'
    echo "    [bootloader] $FSBL_BIN"
    echo "    [load = 0x00100000, startup = 0x00100000] $STOCK/ssbl.bin"
    echo "    [load = 0x02000000] $DTB"
    echo "    [load = 0x02008000] output/zImage"
    [[ $MODE == test ]] && echo "    [load = 0x03000000] output/initramfs.cpio.gz"
    echo '}'
} > "$BIF"

./work/tools/bootgen -image "$BIF" -arch zynq -o "output/boot-${MODE}.bin" -w

# bootgen v2026.1 leaves boot-header words 0x34 (Image Length) and 0x40 (FSBL
# Length) at 0; the stock (known-good) boot.bin carries the FSBL size in both.
# The Zynq-7000 BootROM uses these to copy the FSBL into OCM — length 0 means
# nothing is loaded and the card never boots. Patch to match stock, then fix
# the header checksum at 0x48 (one's complement of words 0x20..0x44).
python3 - "output/boot-${MODE}.bin" "$FSBL_LEN" <<'PY'
import struct, sys
path, fsbl_len = sys.argv[1], int(sys.argv[2])
with open(path, 'r+b') as f:
    f.seek(0x34); f.write(struct.pack('<I', fsbl_len))
    f.seek(0x40); f.write(struct.pack('<I', fsbl_len))
    f.seek(0x20); words = struct.unpack('<10I', f.read(40))
    f.seek(0x48); f.write(struct.pack('<I', (~sum(words)) & 0xFFFFFFFF))
PY
echo "output/boot-${MODE}.bin: $(stat --format=%s "output/boot-${MODE}.bin") bytes"
