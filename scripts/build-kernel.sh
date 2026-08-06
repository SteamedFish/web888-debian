#!/usr/bin/env bash
# build-kernel.sh — configure and build the Web-888 kernel (zImage).
# Run from the repo root or worktree. Output: output/zImage.
#
# Requirements: arm-linux-gnueabihf-gcc, bc, flex, bison, openssl, dtc
# (see scripts/env-setup.sh). Clone first:
#   git clone --depth 1 -b xlnx_rebase_v6.6_LTS \
#     https://github.com/Xilinx/linux-xlnx work/linux-xlnx
set -euo pipefail

cd "$(dirname "$0")/.."
KDIR=work/linux-xlnx
CROSS=arm-linux-gnueabihf-
JOBS="$(nproc)"

for cmd in "${CROSS}gcc" bc flex bison dtc; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Error: $cmd required (see scripts/env-setup.sh)" >&2
        exit 1
    }
done

[[ -d "$KDIR" ]] || {
    echo "Error: $KDIR missing. Clone:" >&2
    echo "  git clone --depth 1 -b xlnx_rebase_v6.6_LTS \\" >&2
    echo "    https://github.com/Xilinx/linux-xlnx $KDIR" >&2
    exit 1
}

# Step 2: materialize the tracked xilinx_devcfg port into the tree
# (work/linux-xlnx is gitignored and re-cloned pristine by build-all.sh
# --clean, so the driver + Kconfig/Makefile plumbing live in config/kernel/).
cp config/kernel/xilinx_devcfg.c "$KDIR/drivers/char/xilinx_devcfg.c"
if ! grep --quiet "config XILINX_DEVCFG" "$KDIR/drivers/char/Kconfig"; then
    git -C "$KDIR" apply "$PWD/config/kernel/0001-char-kconfig-makefile-xilinx-devcfg.patch"
fi

# Step 2: materialize the zynqsdr control-plane driver the same way.
# Patch 0002's context assumes 0001 is already applied (both append at the
# tail of drivers/char/Kconfig/Makefile).
cp config/kernel/zynqsdr.c "$KDIR/drivers/char/zynqsdr.c"
if ! grep --quiet "config ZYNQSDR" "$KDIR/drivers/char/Kconfig"; then
    git -C "$KDIR" apply "$PWD/config/kernel/0002-char-kconfig-makefile-zynqsdr.patch"
fi

# Base: Xilinx Zynq defconfig, then apply our fragment, then resolve.
# CROSS_COMPILE on EVERY make: Kconfig compiler-capability probes
# (e.g. STACKPROTECTOR_PER_TASK's TLS guard) must use the cross gcc —
# with host gcc the symbols stay invisible at olddefconfig time, then
# reappear as (NEW) during the build's syncconfig and conf hangs on an
# interactive prompt. </dev/null turns any such prompt into a fast error.
make -C "$KDIR" ARCH=arm CROSS_COMPILE="$CROSS" xilinx_zynq_defconfig < /dev/null
# merge_config.sh writes to KCONFIG_CONFIG (default: ./.config in the CWD —
# observed: merges silently landed in a stray repo-root .config
# and the kernel was built without half the fragment). Pin the target.
KCONFIG_CONFIG="$(readlink --canonicalize "$KDIR/.config")" \
    "$KDIR/scripts/kconfig/merge_config.sh" -m "$KDIR/.config" config/kernel-web888.fragment
# merge+olddefconfig drops PPS_CLIENT_GPIO=m (observed on xlnx 6.6.80) —
# re-assert it before resolving.
"$KDIR/scripts/config" --file "$KDIR/.config" --module PPS_CLIENT_GPIO
# CPU_FREQ_DEFAULT_GOV_* is a Kconfig choice: the defconfig selects USERSPACE
# and our fragment asks for ONDEMAND, leaving both =y until olddefconfig —
# the winner is then unspecified. Assert the choice deterministically.
"$KDIR/scripts/config" --file "$KDIR/.config" \
    --disable CPU_FREQ_DEFAULT_GOV_USERSPACE \
    --enable CPU_FREQ_DEFAULT_GOV_ONDEMAND
make -C "$KDIR" ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig < /dev/null

# Fail fast: every fragment symbol must survive into the resolved .config
# before we spend 20 minutes compiling.
missing=0
while IFS= read -r line; do
    if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)=n$ ]]; then
        sym="${BASH_REMATCH[1]}"
        grep --quiet "^# CONFIG_${sym} is not set$" "$KDIR/.config" || {
            echo "verify: FAIL — fragment symbol CONFIG_${sym}=n not reflected in $KDIR/.config" >&2
            missing=1
        }
    elif [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)= ]]; then
        sym="${BASH_REMATCH[1]}"
        grep --quiet "^CONFIG_${sym}=" "$KDIR/.config" || {
            echo "verify: FAIL — fragment symbol CONFIG_${sym} missing from $KDIR/.config" >&2
            missing=1
        }
    fi
done < config/kernel-web888.fragment
(( missing == 0 )) || exit 1

# zImage + modules in one pass (fragment has =m symbols: PPS_CLIENT_GPIO,
# XILINX_DEVCFG). Modules land in the rootfs via scripts/install-modules.sh.
make -C "$KDIR" ARCH=arm CROSS_COMPILE="$CROSS" -j"$JOBS" zImage modules < /dev/null

mkdir --parents output
cp "$KDIR/arch/arm/boot/zImage" output/zImage

# --- verification ---------------------------------------------------------
fail=0

# 1. zImage must be the gzip self-extractor format (contract with stock SSBL)
if "$KDIR/scripts/extract-vmlinux" output/zImage > /dev/null 2>&1; then
    echo "verify: zImage gzip self-extractor OK"
else
    echo "verify: FAIL — zImage is not gzip-extractable" >&2
    fail=1
fi

# 2. Required drivers must be built-in
for sym in PPS NVMEM PSTORE PSTORE_RAM DEVTMPFS_MOUNT \
           MACB REALTEK_PHY I2C_CADENCE SERIAL_XILINX_PS_UART GPIO_ZYNQ \
           PINCTRL_ZYNQ XILINX_XADC CADENCE_WATCHDOG MMC_SDHCI_OF_ARASAN \
           CMA EXT4_FS VFAT_FS SQUASHFS OVERLAY_FS; do
    if ! grep --quiet "^CONFIG_${sym}=y" "$KDIR/.config"; then
        echo "verify: FAIL — CONFIG_${sym} is not =y" >&2
        fail=1
    fi
done
[[ $fail -eq 0 ]] && echo "verify: required CONFIG_* symbols OK"

# 3. Fragment module symbols must have produced .ko files
if grep --quiet "^CONFIG_XILINX_DEVCFG=m" "$KDIR/.config"; then
    if [[ -f $KDIR/drivers/char/xilinx_devcfg.ko ]]; then
        echo "verify: drivers/char/xilinx_devcfg.ko OK"
    else
        echo "verify: FAIL — CONFIG_XILINX_DEVCFG=m but xilinx_devcfg.ko missing" >&2
        fail=1
    fi
fi
if grep --quiet "^CONFIG_ZYNQSDR=m" "$KDIR/.config"; then
    if [[ -f $KDIR/drivers/char/zynqsdr.ko ]]; then
        echo "verify: drivers/char/zynqsdr.ko OK"
    else
        echo "verify: FAIL — CONFIG_ZYNQSDR=m but zynqsdr.ko missing" >&2
        fail=1
    fi
fi

ls -lh output/zImage
exit $fail
