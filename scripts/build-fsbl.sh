#!/usr/bin/env bash
# build-fsbl.sh — build the Web-888 FSBL from source (Task 3 of the
# fsbl-source-build plan).
#
# Source inputs (all tracked):
#   resources/reference/embeddedsw-zynq-fsbl/   vendored embeddedsw subset
#     (xilinx_v2023.1) with the web888 board dir under
#     lib/sw_apps/zynq_fsbl/misc/web888/
#   resources/reference/redpitaya-fsbl-hooks/   Red Pitaya board hooks
#     (Si5351 clock programming + EEPROM MAC hook) and fsbl.patch
#
# Working copies (gitignored):
#   work/fsbl/    rsync'd copy of the FSBL app; the hooks source and
#                 fsbl.patch are applied HERE, never to the vendored tree
#   output/fsbl/  fsbl.elf + fsbl.bin
#
# Host notes (see resources/reference/embeddedsw-zynq-fsbl/PROVENANCE.md):
#   - Arch arm-none-eabi-gcc ships no libc; newlib is expected at
#     .tmp/newlib/usr/arm-none-eabi (see scripts/extract-ps7-init.py era
#     notes / Task 1). CPATH injects headers, --sysroot injects the linker
#     library path (env LIBRARY_PATH is silently sysroot-prefixed by this
#     gcc — do not rely on it). Debian/Ubuntu gcc-arm-none-eabi +
#     libnewlib-arm-none-eabi find newlib natively, so a link probe below
#     decides; the sysroot is only required when the probe fails.
#   - Xilinx 2020-era makefiles race under parallel make: -j1 is forced.
#   - xilrsa is a PREBUILT librsa.a upstream (no C sources) — linked as-is.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="$PWD"
VENDOR=resources/reference/embeddedsw-zynq-fsbl
FSBL_REL=lib/sw_apps/zynq_fsbl
VENDOR_FSBL="$VENDOR/$FSBL_REL"
HOOKS_DIR=resources/reference/redpitaya-fsbl-hooks
WORK_FSBL=work/fsbl
WORK_APP="$WORK_FSBL/$FSBL_REL"
OUT_DIR=output/fsbl
NEWLIB_SYSROOT="${NEWLIB_SYSROOT:-$REPO/.tmp/newlib/usr/arm-none-eabi}"
BOARD=web888
MAX_FSBL_BYTES=$((192 * 1024))

for f in "$VENDOR_FSBL/src/Makefile" \
         "$VENDOR_FSBL/misc/$BOARD/xparameters.h" \
         "$VENDOR_FSBL/misc/$BOARD/ps7_init.c" \
         "$HOOKS_DIR/red_pitaya_fsbl_hooks.c" \
         "$HOOKS_DIR/fsbl.patch"; do
    [[ -f $f ]] || { echo "Error: missing $f" >&2; exit 1; }
done
command -v arm-none-eabi-gcc &>/dev/null || {
    echo "Error: arm-none-eabi-gcc required (pacman: arm-none-eabi-gcc)" >&2; exit 1; }
command -v arm-none-eabi-objcopy &>/dev/null || {
    echo "Error: arm-none-eabi-objcopy required (pacman: arm-none-eabi-binutils)" >&2; exit 1; }
# Newlib probe: can this arm-none-eabi-gcc compile AND LINK a trivial newlib
# program without any sysroot flag? Debian/Ubuntu (gcc-arm-none-eabi +
# libnewlib-arm-none-eabi) can; Arch's arm-none-eabi-gcc ships no libc and
# needs the project-local newlib sysroot ($NEWLIB_SYSROOT, env-overridable).
# The probe must be FREESTANDING (-nostartfiles, own _start): that is how the
# FSBL itself links (its own boot/start objects + -lc), while a hosted
# `int main` link would additionally need crt0.o (libgloss), which
# Debian/Ubuntu's arm-none-eabi newlib does not reliably ship — so a hosted
# probe wrongly reports "no native newlib" on exactly the toolchains we want
# to detect.
PROBE=$(mktemp --suffix=.elf)
if printf '#include <stdint.h>\nvoid _start(void){ for(;;){} }\n' \
    | arm-none-eabi-gcc -x c - -nostartfiles -o "$PROBE" 2>/dev/null; then
    NATIVE_NEWLIB=1
else
    NATIVE_NEWLIB=0
fi
rm -f "$PROBE"

LINKER="arm-none-eabi-gcc"
if [[ $NATIVE_NEWLIB == 1 ]]; then
    echo "newlib: native (arm-none-eabi-gcc links with no --sysroot)"
else
    [[ -f $NEWLIB_SYSROOT/lib/libc.a && -f $NEWLIB_SYSROOT/include/stdint.h ]] || {
        echo "Error: newlib sysroot missing at $NEWLIB_SYSROOT" >&2
        echo "  (extract arm-none-eabi-newlib pkg under .tmp/newlib/ — see Task 1 notes)" >&2
        exit 1; }
    # CPATH injects headers, --sysroot injects the linker library path.
    export CPATH="$NEWLIB_SYSROOT/include"
    LINKER="arm-none-eabi-gcc --sysroot=$NEWLIB_SYSROOT"
    echo "newlib: sysroot $NEWLIB_SYSROOT (CPATH + LINKER --sysroot)"
fi

# --- stage a fresh working copy -------------------------------------------
# copy_bsp.sh resolves drivers/services via ../../../../ relative to misc/,
# so the work copy must preserve the full embeddedsw directory layout.
mkdir --parents "$OUT_DIR"
rm -rf "$WORK_FSBL"
mkdir --parents "$WORK_FSBL"
rsync --archive --delete --copy-links \
    --exclude 'ps7_cortexa9_0' --exclude 'fsbl.elf' --exclude '*.o' \
    "$VENDOR/" "$WORK_FSBL/"

# --- apply the Red Pitaya board hooks -------------------------------------
cp "$HOOKS_DIR/red_pitaya_fsbl_hooks.c" "$WORK_APP/src/red_pitaya_fsbl_hooks.c"
# fsbl.patch is a classic unified patch (no git a/ b/ prefixes) — use patch(1)
patch --dry-run -p0 -d "$WORK_APP/src" < "$HOOKS_DIR/fsbl.patch"
patch -p0 -d "$WORK_APP/src" < "$HOOKS_DIR/fsbl.patch"

# --- build (serial make; when the newlib probe failed, CPATH + --sysroot ---
# --- were set above; with native newlib neither is injected) --------------
# SHELL=/bin/bash: the vendored Xilinx Makefiles use non-POSIX `[ a == b ]`.
# Arch's /bin/sh is bash so local builds never noticed, but on Ubuntu/Debian
# /bin/sh is dash: the `[` errors out, the `if` goes false and the
# `make -C ../misc` BSP build is silently SKIPPED — xparameters_ps.h never
# lands in misc/ps7_cortexa9_0/include and the src compile dies. GNU make
# ignores the SHELL env var on Unix but honors it on the command line, and
# command-line variables propagate to sub-makes via MAKEFLAGS.
make -j1 -C "$WORK_APP/src" \
    SHELL=/bin/bash \
    BOARD="$BOARD" \
    CC=arm-none-eabi-gcc \
    LINKER="$LINKER"

# --- artifacts -------------------------------------------------------------
arm-none-eabi-objcopy -O binary "$WORK_APP/src/fsbl.elf" "$OUT_DIR/fsbl.bin"
cp "$WORK_APP/src/fsbl.elf" "$OUT_DIR/fsbl.elf"

SIZE=$(stat --format='%s' "$OUT_DIR/fsbl.bin")
echo "fsbl.bin: $SIZE bytes"
if (( SIZE > MAX_FSBL_BYTES )); then
    echo "Error: fsbl.bin exceeds 192 KiB boot.bin partition budget" >&2
    exit 1
fi
echo "OK: $OUT_DIR/fsbl.{elf,bin}"
