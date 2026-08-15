#!/usr/bin/env bash
# build-uboot.sh — mainline U-Boot (no SPL) for web888 → output/u-boot.bin
# (step 6). The stock FSBL loads this u-boot.bin as the SSBL
# partition of boot.bin; kernel/dtb come from the FAT partition via
# boot.scr/uEnv.txt, replacing the 52-byte stub chain.
#
# Tree: work/u-boot (mainline v2026.07, pinned in config/u-boot/upstream.pin;
# fetch-upstream-src.sh u-boot clones it on first run). Tracked sources in
# config/u-boot/ are materialized into the gitignored tree — same pattern
# as build-kernel.sh; use patch(1), not git apply (host anomaly).
set -euo pipefail
cd "$(dirname "$0")/.."

UBDIR=work/u-boot
CROSS=arm-linux-gnueabihf-
JOBS="$(nproc)"

[[ -d $UBDIR/arch/arm/mach-zynq ]] || {
    echo "Error: $UBDIR missing (run scripts/fetch-upstream-src.sh u-boot first)" >&2
    exit 1
}

# --- 1. materialize board dts + dts Makefile entry (idempotent) -------------
cp config/u-boot/zynq-web888.dts "$UBDIR/arch/arm/dts/zynq-web888.dts"
if ! grep --quiet "zynq-web888" "$UBDIR/arch/arm/dts/Makefile"; then
    patch -p1 -d "$UBDIR" < config/u-boot/0001-dts-makefile-web888.patch
fi
# Board EEPROM → ethaddr hook (per-unit MAC; see web888.fragment notes).
if ! grep --quiet "WEB888_EEPROM_MAC" "$UBDIR/board/xilinx/zynq/Kconfig"; then
    patch -p1 -d "$UBDIR" < config/u-boot/0002-board-eeprom-mac.patch
fi

# --- 2. defconfig + our fragment --------------------------------------------
make -C "$UBDIR" xilinx_zynq_virt_defconfig < /dev/null
# Pin KCONFIG_CONFIG: merge_config.sh defaults to ./.config in the CALLER's
# cwd (stray-merge footgun, see build-kernel.sh).
KCONFIG_CONFIG="$(readlink --canonicalize "$UBDIR/.config")" \
    "$UBDIR/scripts/kconfig/merge_config.sh" -m "$UBDIR/.config" \
    config/u-boot/web888.fragment
make -C "$UBDIR" olddefconfig < /dev/null

# --- 3. assert the config contract ------------------------------------------
fail=0
need_y="ARCH_ZYNQ ZYNQ_SERIAL MMC_SDHCI MMC_SDHCI_ZYNQ ZYNQ_GEM PHY_REALTEK \
        DM_ETH_PHY OF_SEPARATE REMAKE_ELF ENV_IS_NOWHERE CMD_MMC CMD_FAT \
        DISTRO_DEFAULTS SKIP_LOWLEVEL_INIT WEB888_EEPROM_MAC"
need_n="SPL ENV_IS_IN_FAT ENV_IS_IN_NAND ENV_IS_IN_SPI_FLASH ENV_REDUNDANT \
        ZYNQ_QSPI NAND_ZYNQ MTD_RAW_NAND MTD_NOR_FLASH CMD_UBI CMD_UBIFS \
        MTD_UBI"
for sym in $need_y; do
    grep --quiet "^CONFIG_${sym}=y" "$UBDIR/.config" || {
        echo "verify: FAIL — CONFIG_${sym} is not =y" >&2; fail=1; }
done
for sym in $need_n; do
    if ! grep --quiet "^# CONFIG_${sym} is not set" "$UBDIR/.config" \
       && grep --quiet "^CONFIG_${sym}=" "$UBDIR/.config"; then
        echo "verify: FAIL — CONFIG_${sym} must be n/absent" >&2; fail=1
    fi
done
grep --quiet '^CONFIG_DEFAULT_DEVICE_TREE="zynq-web888"' "$UBDIR/.config" || {
    echo "verify: FAIL — DEFAULT_DEVICE_TREE != zynq-web888" >&2; fail=1; }
(( fail == 0 )) || exit 1
echo "verify: config contract OK (zynq_virt + web888 fragment resolved)"

# --- 4. build ----------------------------------------------------------------
make -C "$UBDIR" CROSS_COMPILE="$CROSS" -j"$JOBS" < /dev/null

mkdir --parents output
# u-boot-dtb.bin = u-boot.bin + appended dtb: the single self-contained
# binary the FSBL loads as the SSBL partition of boot.bin.
cp "$UBDIR/u-boot-dtb.bin" output/u-boot.bin
cp "$UBDIR/u-boot.elf" output/u-boot.elf 2>/dev/null || true

# --- 5. post-build verification ----------------------------------------------
# The appended DTB must be ours: check the model string inside the binary.
# (no grep -q: it exits early → strings dies on SIGPIPE → pipefail trips)
if strings output/u-boot.bin | grep "Web-888 SDR" > /dev/null; then
    echo "verify: DTB model string OK"
else
    echo "verify: FAIL — 'Web-888 SDR' not found in u-boot.bin (OF_EMBED broken?)" >&2
    exit 1
fi
ls -la output/u-boot.bin
