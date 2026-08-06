#!/usr/bin/env bash
# build-kernel-6.12.sh — step 6 P1: Debian-source 6.12 kernel for the Web-888,
# packaged as .debs (step 6 — see docs/dev/kernel-update-sop.md).
#
# Source: Debian linux source package 6.12.100-1 (trixie security pool), fetched
# from deb.debian.org and extracted with dpkg-source into work/linux-debian-6.12.
# Config: Debian armmp hierarchy (debian/config/{config,kernelarch-arm/config,
# armhf/config}) merged by the source package's own kconfig.py, plus
# config/kernel-web888-6.12.fragment (Zynq platform + board deltas).
# Product: linux-image/linux-headers/linux-libc-dev .debs → output/kernel/
# (make bindeb-pkg, ikwzm's flow), plus output/kernel/zImage-6.12.100-web888
# for the boot.bin repack (stub chain unchanged: gzip zImage @0x02008000).
#
# Run from the repo root. Requirements: arm-linux-gnueabihf-gcc, dpkg-source,
# bc, flex, bison, dtc, python3 (see scripts/env-setup.sh).
set -euo pipefail

cd "$(dirname "$0")/.."
KVER=6.12.100
KREV=1
KDIR=work/linux-debian-6.12
DL=work/downloads/linux-${KVER}
CROSS=arm-linux-gnueabihf-
JOBS="$(nproc)"
FRAG=config/kernel-web888-6.12.fragment

for cmd in "${CROSS}gcc" bc flex bison dtc dpkg-source patch python3; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Error: $cmd required (see scripts/env-setup.sh)" >&2
        exit 1
    }
done

# --- 0.5 debhelper for bindeb-pkg -------------------------------------------
# The kernel's debian/rules is dh-based but debhelper is not an Arch package
# — extract it project-locally from Debian's arch:all .deb (same pattern as
# qemu-user-static in env-setup.sh). The dh_* perl frontend + its modules
# come from the .deb; the heavy lifting uses the host's own dpkg-* tools.
DHTOOLS=work/tools/debhelper
if [[ ! -f $DHTOOLS/usr/share/perl5/Debian/Debhelper/Dh_Lib.pm ]]; then
    mkdir --parents "$DHTOOLS" "$DL"
    DHVER=13.24.2
    # debhelper 13.19+ splits the perl modules into libdebhelper-perl —
    # both arch:all debs are needed.
    for pkg in debhelper libdebhelper-perl; do
        [[ -f $DL/${pkg}_${DHVER}_all.deb ]] || curl -fSL -o "$DL/${pkg}_${DHVER}_all.deb" \
            "https://deb.debian.org/debian/pool/main/d/debhelper/${pkg}_${DHVER}_all.deb"
        dpkg-deb --fsys-tarfile "$DL/${pkg}_${DHVER}_all.deb" | tar -x -C "$DHTOOLS"
    done
fi
export PATH="$(readlink --canonicalize "$DHTOOLS/usr/bin"):$PATH"
export PERL5LIB="$(readlink --canonicalize "$DHTOOLS/usr/share/perl5")${PERL5LIB:+:$PERL5LIB}"

# --- 1. fetch + extract the Debian source package (idempotent) --------------
if [[ ! -d $KDIR ]]; then
    mkdir --parents "$DL"
    base=https://deb.debian.org/debian/pool/main/l/linux
    for f in "linux_${KVER}.orig.tar.xz" "linux_${KVER}-${KREV}.debian.tar.xz" \
             "linux_${KVER}-${KREV}.dsc"; do
        [[ -f $DL/$f ]] || curl -fSL -o "$DL/$f" "$base/$f"
    done
    dpkg-source --no-check -x "$DL/linux_${KVER}-${KREV}.dsc" "$KDIR"
fi

# --- 2. materialize our drivers + patches (idempotent) ----------------------
# Same pattern as build-kernel.sh: the tree is gitignored, so tracked
# sources/patches in config/kernel/ are applied here. NOTE: use patch(1),
# not git apply — git apply misbehaves in this environment ("Skipped patch"
# on valid input; observed as a repo-discovery anomaly).
cp config/kernel/xilinx_devcfg.c "$KDIR/drivers/char/xilinx_devcfg.c"
cp config/kernel/zynqsdr.c "$KDIR/drivers/char/zynqsdr.c"
if ! grep --quiet "config XILINX_DEVCFG" "$KDIR/drivers/char/Kconfig"; then
    patch -p1 -d "$KDIR" < config/kernel/0001-char-kconfig-makefile-xilinx-devcfg.patch
fi
if ! grep --quiet "config ZYNQSDR" "$KDIR/drivers/char/Kconfig"; then
    patch -p1 -d "$KDIR" < config/kernel/0002-char-kconfig-makefile-zynqsdr.patch
fi
# ikwzm ULPI patch: usb0 host port depends on this hook.
if ! grep --quiet "devm_usb_get_phy_by_phandle" "$KDIR/drivers/usb/chipidea/ci_hdrc_usb2.c"; then
    patch -p1 -d "$KDIR" < config/kernel/0003-usb-ulpi-phy-phandle.patch
fi

# --- 2.5 snapshot Debian's packaging machinery ------------------------------
# bindeb-pkg's "make debian" step REGENERATES $KDIR/debian with the kernel's
# own minimal packaging (linux-upstream), deleting the source package's
# kconfig.py + config/ hierarchy that step 3 needs — so the config machinery
# must live in a snapshot outside the tree. Refresh it whenever the source
# package's copy still exists (i.e. before the first bindeb-pkg run).
SNAP=work/kconfig-${KVER}-snapshot
if [[ -f $KDIR/debian/bin/kconfig.py ]]; then
    rm -rf "$SNAP"
    mkdir --parents "$SNAP/bin" "$SNAP/lib"
    cp "$KDIR/debian/bin/kconfig.py" "$SNAP/bin/"
    cp -r "$KDIR/debian/lib/python" "$SNAP/lib/"
    cp -r "$KDIR/debian/config" "$SNAP/config"
elif [[ ! -f $SNAP/bin/kconfig.py ]]; then
    # Tree debian/ already clobbered by a previous bindeb-pkg run and no
    # snapshot yet: extract the machinery straight from the debian tarball.
    mkdir --parents "$SNAP"
    tar -xJf "$DL/linux_${KVER}-${KREV}.debian.tar.xz" -C "$SNAP" \
        --strip-components=1 \
        debian/bin/kconfig.py debian/lib/python debian/config
fi
[[ -f $SNAP/bin/kconfig.py ]] || { echo "Error: no kconfig.py snapshot" >&2; exit 1; }

# --- 3. config: Debian armmp hierarchy + our fragment -----------------------
# Merge Debian's own config layers with the source package's kconfig.py
# (armmp = armhf base flavour: global + kernelarch-arm + armhf subarch).
PYTHONPATH="$SNAP/bin:$SNAP/lib/python" python3 "$SNAP/bin/kconfig.py" \
    "$KDIR/.config" \
    "$SNAP/config/config" \
    "$SNAP/config/kernelarch-arm/config" \
    "$SNAP/config/armhf/config"

# Apply our fragment. Pin KCONFIG_CONFIG (stray-merge footgun, see
# build-kernel.sh) and keep CROSS_COMPILE on every make invocation.
KCONFIG_CONFIG="$(readlink --canonicalize "$KDIR/.config")" \
    "$KDIR/scripts/kconfig/merge_config.sh" -m "$KDIR/.config" "$FRAG"

# Deterministic fixups the fragment cannot express:
# - dep chains that must be promoted to =y for the initrd-less boot (Debian
#   ships them =m; olddefconfig silently demotes OF_ARASAN otherwise).
"$KDIR/scripts/config" --file "$KDIR/.config" \
    --enable MMC_SDHCI --enable MMC_SDHCI_PLTFM --enable MMC_SDHCI_OF_ARASAN
# - governor is a Kconfig choice: leave exactly ONDEMAND =y (same trap as
#   the 6.6 build — both =y until olddefconfig, winner unspecified).
"$KDIR/scripts/config" --file "$KDIR/.config" \
    --disable CPU_FREQ_DEFAULT_GOV_SCHEDUTIL \
    --enable CPU_FREQ_DEFAULT_GOV_ONDEMAND
# - build-speed, not config policy: Debian builds with DWARF debug info
#   (separate -dbg debs); we don't need it and it roughly doubles build time
#   and disk. Runtime-invisible.
"$KDIR/scripts/config" --file "$KDIR/.config" --disable DEBUG_INFO

make -C "$KDIR" ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig < /dev/null

# --- 4. assert: every contract symbol must survive resolution ---------------
fail=0
need_y="ARCH_ZYNQ SERIAL_XILINX_PS_UART SERIAL_XILINX_PS_UART_CONSOLE \
        GPIO_ZYNQ PINCTRL_ZYNQ CADENCE_WATCHDOG I2C_CADENCE NVMEM \
        EEPROM_AT24 I2C_CHARDEV \
        DEVTMPFS DEVTMPFS_MOUNT MMC MMC_SDHCI MMC_SDHCI_PLTFM \
        MMC_SDHCI_OF_ARASAN EXT4_FS SQUASHFS OVERLAY_FS MACB REALTEK_PHY \
        CMA PSTORE PSTORE_RAM CPUFREQ_DT CPUFREQ_DT_PLATDEV \
        CPU_FREQ_DEFAULT_GOV_ONDEMAND NETFILTER PPS ZSWAP CRYPTO_LZO"
need_m="XILINX_DEVCFG ZYNQSDR NF_TABLES PPS_CLIENT_GPIO ZRAM XILINX_XADC \
        USB_CHIPIDEA USB_ULPI_BUS BRCMFMAC USB_SERIAL_CH341 WIREGUARD \
        NFT_COMPAT"
need_n="FPGA_MGR_ZYNQ_FPGA CPU_FREQ_DEFAULT_GOV_SCHEDUTIL LOCALVERSION_AUTO"
for sym in $need_y; do
    grep --quiet "^CONFIG_${sym}=y" "$KDIR/.config" || {
        echo "verify: FAIL — CONFIG_${sym} is not =y" >&2; fail=1; }
done
for sym in $need_m; do
    grep --quiet "^CONFIG_${sym}=m" "$KDIR/.config" || {
        echo "verify: FAIL — CONFIG_${sym} is not =m" >&2; fail=1; }
done
for sym in $need_n; do
    if ! grep --quiet "^# CONFIG_${sym} is not set" "$KDIR/.config" \
       && grep --quiet "^CONFIG_${sym}=" "$KDIR/.config"; then
        echo "verify: FAIL — CONFIG_${sym} must be n/absent" >&2; fail=1
    fi
done
grep --quiet '^CONFIG_CMA_SIZE_MBYTES=64' "$KDIR/.config" || {
    echo "verify: FAIL — CMA_SIZE_MBYTES != 64" >&2; fail=1; }
grep --quiet '^CONFIG_LOCALVERSION="-web888"' "$KDIR/.config" || {
    echo "verify: FAIL — LOCALVERSION != -web888" >&2; fail=1; }
(( fail == 0 )) || exit 1
echo "verify: config contract OK (armmp + web888 fragment resolved)"

# --- 5. build + package -----------------------------------------------------
# Package via the debian/rules binary-image target directly, NOT bindeb-pkg:
#  - bindeb-pkg also builds linux-headers/linux-libc-dev, whose staging build
#    recompiles scripts/* host programs with the CROSS toolchain — Arch's
#    cross-gcc cannot link hosted binaries (-latomic_asneeded quirk, see
#    env-setup.sh). Headers are out of scope: websdr is userspace, no DKMS,
#    no out-of-tree modules on target (step 6).
#  - Skipping dpkg-buildpackage also sidesteps dpkg-checkbuilddeps (Arch's
#    dpkg db knows nothing about the cross toolchain). debian/rules needs
#    the project-local debhelper on PATH/PERL5LIB (step 0.5).
make -C "$KDIR" ARCH=arm CROSS_COMPILE="$CROSS" -j"$JOBS" < /dev/null
# Maintainer identity embedded in the generated debian/changelog:
# scripts/package/mkdebian reads DEBFULLNAME/DEBEMAIL (fallbacks are
# git config / KBUILD_BUILD_USER). Keep in sync with
# packaging/*/debian/control.
export DEBFULLNAME="SteamedFish"
export DEBEMAIL="steamedfish@hotmail.com"
# Regenerate the kernel's minimal debian/ with the identity above. Invoke
# mkdebian DIRECTLY: `make debian` is a silent no-op here (the top Makefile
# does not expose scripts/Makefile.package's `debian` target, and the
# existing debian/ directory satisfies the file lookup), which previously
# left stale packaging with a host-derived maintainer in place. mkdebian is
# normally driven by kbuild, so supply the variables it dereferences
# (set -u: KERNELRELEASE/KERNELVERSION/srctree/ARCH/SRCARCH/UTS_MACHINE).
( cd "$KDIR" && \
    KERNELRELEASE="$KVER-web888" KERNELVERSION="$KVER" srctree=. \
    ARCH=arm SRCARCH=arm UTS_MACHINE=arm \
    ./scripts/package/mkdebian )
DEB_BUILD_OPTIONS="parallel=$JOBS" \
    make -C "$KDIR" -f debian/rules binary-image < /dev/null

mkdir --parents output/kernel
mv work/linux-image-*.deb output/kernel/ 2>/dev/null || true
rm -f output/kernel/linux-image-*-dbg_*.deb work/linux-image-*-dbg_*.deb
cp "$KDIR/arch/arm/boot/zImage" "output/kernel/zImage-${KVER}-web888"
# Downstream contract: build-bootbin.sh / build-image.sh consume output/zImage
# regardless of kernel flow (6.6 build-kernel.sh writes the same path).
cp "$KDIR/arch/arm/boot/zImage" output/zImage

# --- 6. post-build verification ---------------------------------------------
if "$KDIR/scripts/extract-vmlinux" "output/kernel/zImage-${KVER}-web888" > /dev/null 2>&1; then
    echo "verify: zImage gzip self-extractor OK"
else
    echo "verify: FAIL — zImage is not gzip-extractable" >&2; fail=1
fi
for ko in "$KDIR/drivers/char/xilinx_devcfg.ko" "$KDIR/drivers/char/zynqsdr.ko"; do
    [[ -f $ko ]] || { echo "verify: FAIL — $ko missing" >&2; fail=1; }
done
# The two pre-existing -Wmissing-prototypes in xilinx_devcfg.c are known and
# unchanged from 6.6; no new warnings expected, but bindeb-pkg log parsing is
# left to the reader (module builds fail hard on errors anyway).

ls -lh output/kernel/
exit $fail
