#!/usr/bin/env bash
# write-dtb.sh — compile config/web888.dts → dtb.
# usage: write-dtb.sh <output.dtb> [bootargs-string]
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: $0 <output.dtb> [bootargs-string]}"
BOOTARGS="${2:-}"

# Kernel tree providing zynq-7000.dtsi + include/. Default: step-1 xlnx 6.6
# tree; step 6 (6.12) callers set KERNEL_DTS_TREE=work/linux-debian-6.12.
KTREE="${KERNEL_DTS_TREE:-work/linux-xlnx}"
DTS_DIR="$KTREE/arch/arm/boot/dts"
if [[ ! -f $DTS_DIR/xilinx/zynq-7000.dtsi ]]; then
    echo "Error: $KTREE missing zynq-7000.dtsi (clone/build kernel first)" >&2
    exit 1
fi

mkdir --parents work/dt

CPP_ARGS=()
if [[ -n $BOOTARGS ]]; then
    CPP_ARGS+=("-DBOOTARGS=\"$BOOTARGS\"")
fi

# dts files use cpp-style #include — preprocess exactly like the kernel dtbs build
cpp -nostdinc -I "$DTS_DIR" -I "$DTS_DIR/xilinx" -I "$KTREE/include" \
    -undef -x assembler-with-cpp "${CPP_ARGS[@]}" config/web888.dts > work/dt/web888.dts.pp

dtc -I dts -O dtb -o "$OUT" work/dt/web888.dts.pp
dtc -I dtb -O dts -o /dev/null "$OUT"   # roundtrip sanity check
echo "$OUT: $(stat --format=%s "$OUT") bytes"
