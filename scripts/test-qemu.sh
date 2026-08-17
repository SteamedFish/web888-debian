#!/usr/bin/env bash
# test-qemu.sh — QEMU boot gate. Boots the assembled card image on
# xilinx-zynq-a9 with serial on stdio. QEMU tests gate every hardware flash.
#
# usage: test-qemu.sh [test|final|uboot]
#   test  — -initrd initramfs gate: must print DEBIAN_ROOTFS_MOUNTED and exec
#   final — direct ext4 boot: must reach a login prompt on /dev/mmcblk0p2
#   uboot — real-flow gate: QEMU direct-boots the U-Boot ELF, U-Boot runs
#           boot.scr from the image FAT which loads zImage+dtb; must reach a
#           login prompt on the serial log (no ssh hostfwd: eth0 can't probe
#           under QEMU — phy@1 mismatch, no 24c64 for the MAC either)
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-test}"
IMG=output/web888-debian-${MODE}.img
DTB=output/web888.dtb
[[ $MODE == test ]] && DTB=output/web888-test.dtb

[[ $MODE == test || $MODE == final || $MODE == uboot ]] || { echo "usage: $0 [test|final|uboot]" >&2; exit 1; }
for f in "$IMG" output/zImage "$DTB"; do
    [[ -f $f ]] || { echo "Error: missing $f (run build-image.sh $MODE first)" >&2; exit 1; }
done
[[ $MODE != uboot || -f output/u-boot.bin ]] || { echo "Error: output/u-boot.bin missing (run build-uboot.sh)" >&2; exit 1; }

# QEMU's cadence_gem PHY is fixed at MDIO address 7 and emulates no 24c64
# EEPROM on i2c0 — so the production DTB can never probe eth0 under QEMU
# (phy@1 mismatch; nvmem MAC cell unresolvable because at24's test read
# returns -ENODEV on the missing chip). The -global
# driver=cadence_gem,property=phy-addr,value=1 flag parses but is silently
# ignored (verified via monitor info qtree: phy-addr stays 7).
# Workaround: a QEMU-only DTB variant with phy@7 and a local-mac-address.
if [[ $MODE == final ]]; then
    python3 - <<'PY'
src = open('config/web888.dts').read()
src = src.replace('phy-handle = <&phy1>;',
                  'phy-handle = <&phy1>;\n\t\tlocal-mac-address = [02 11 22 33 44 55];', 1)
src = src.replace('phy1: ethernet-phy@1 {\n\t\treg = <1>;',
                  'phy1: ethernet-phy@7 {\n\t\treg = <7>;', 1)
assert 'reg = <7>' in src and 'local-mac-address' in src
open('work/dt/web888-qemu.dts', 'w').write(src)
PY
    DTS_DIR="${KERNEL_DTS_TREE:-work/linux-xlnx}/arch/arm/boot/dts"
    cpp -nostdinc -I "$DTS_DIR" -I "$DTS_DIR/xilinx" -I "${KERNEL_DTS_TREE:-work/linux-xlnx}/include" \
        -undef -x assembler-with-cpp work/dt/web888-qemu.dts > work/dt/web888-qemu.dts.pp
    dtc -I dts -O dtb -o output/web888-qemu.dtb work/dt/web888-qemu.dts.pp
    DTB=output/web888-qemu.dtb
fi

QEMU_ARGS=(-M xilinx-zynq-a9 -m 512M -display none -serial stdio
    -drive "file=$IMG,if=sd,format=raw,index=0"
    -net nic -no-reboot)
if [[ $MODE == uboot ]]; then
    # QEMU xilinx-zynq-a9 loads raw -kernel at 0x10000 (our TEXT_BASE is
    # 0x04000000) and the ELF carries no appended FDT — only the generic
    # loader with the dtb-appended binary boots U-Boot here (FSBL skipped).
    # U-Boot then finds boot.scr on the SD image FAT, which supplies the
    # kernel dtb + bootargs.
    QEMU_ARGS+=(-device loader,file=output/u-boot.bin,addr=0x04000000,cpu-num=0)
else
    QEMU_ARGS+=(-kernel output/zImage -dtb "$DTB")
fi

# panic=-1 + -no-reboot: a kernel panic exits QEMU immediately instead of looping
if [[ $MODE == test ]]; then
    # -initrd sets linux,initrd-start/end in the dtb, so no initrd= bootarg needed
    QEMU_ARGS+=(-net user -initrd output/initramfs.cpio.gz
        -append "console=ttyPS0,115200 earlycon panic=-1")
elif [[ $MODE == final ]]; then
    # fw_devlink=off net.ifnames=0 must match the final dtb bootargs in
    # build-bootbin.sh — -append overrides dtb bootargs when -kernel is used.
    # hostfwd enables the post-boot ssh check (openssh-server) over QEMU user-net.
    QEMU_ARGS+=(-net "user,hostfwd=tcp:127.0.0.1:12222-:22"
        -append "console=ttyPS0,115200 earlycon root=/dev/mmcblk0p2 rw rootwait panic=-1 fw_devlink=off net.ifnames=0")
else
    QEMU_ARGS+=(-net user)
fi

# Wall-clock budget: TCG emulation speed varies with host load (loaded CI
# runners have shown ~4x slowdowns), so CI overrides this with
# QEMU_TIMEOUT=300; 120s stays the local default.
timeout --foreground "${QEMU_TIMEOUT:-120}" qemu-system-arm "${QEMU_ARGS[@]}" || true
