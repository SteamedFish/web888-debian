#!/usr/bin/env bash
# build-all.sh — reproduce the full final card image from scratch.
#
# Orchestrates the whole pipeline; every step is idempotent (skips outputs
# that already exist), so it doubles as an incremental rebuild driver:
#
#   1. env-setup.sh            verify host toolchain + binfmt
#   2. kernel source           work/linux-xlnx (local cache .tmp/linux-xlnx
#                              preferred, else shallow GitHub clone)
#   3. bootgen                 work/tools/bootgen (built from Xilinx/bootgen)
#   4. stock FSBL/SSBL         extracted from resources/stock/web888-boot.bin → work/stock/
#                              (= boot.bin from the stock TF card partition 1;
#                              copy it there yourself once — it is the ONLY
#                              input that does not come from the network;
#                              the extracted FSBL is only used for FSBL=stock)
#   5. build-kernel.sh         output/zImage
#   6. build-initramfs.sh      output/initramfs.cpio.gz (test-mode gate)
#   7. debootstrap             work/rootfs (trixie armhf, qemu binfmt)
#   8. configure-rootfs.sh     hostname/password/network/openssh-server
#  8b. install-modules.sh      kernel modules into rootfs
#  8c. build-websdr-deb.sh     web888-websdr deb (fetch-upstream-src.sh clones
#                              the pinned RaspSDR/server tree on first run;
#                              auto-creates armhf chroot via mk-websdr-chroot.sh;
#                              rebuilds if any patch is newer than the cached deb)
#  8d. install-websdr.sh       install the deb into rootfs
#  8e. build-redpitaya-deb.sh  web888-redpitaya deb (step 4; same upstream fetch,
#                              chroot + stale-deb sentinel pattern as 8c)
#  8f. install-redpitaya.sh    install the deb into rootfs (units disabled)
#  8g. build-uboot.sh          work/u-boot + output/u-boot.bin (CHAIN=uboot only)
#  8h. build-fsbl.sh           output/fsbl/fsbl.bin — FSBL built from vendored
#                              embeddedsw source (FSBL=source only; hardware-
#                              verified, see docs/dev/fsbl-source-build-plan.md)
#   9. build-bootbin.sh $MODE  output/web888.dtb + output/boot-$MODE.bin
#  10. build-image.sh $MODE    output/web888-debian-$MODE.img  <- deliverable
#
# usage: build-all.sh [--clean]
#   --clean  delete work/ and output/ first (true from-scratch reproduction;
#            .tmp/ is kept — it holds the stock firmware inputs and the
#            kernel git cache)
#
# Options (environment variables):
#   CHAIN=uboot|stub   boot chain; uboot = FSBL + full U-Boot as SSBL
#                      (default, production), stub = stock stub-SSBL chain
#                      (rollback; maps to bootbin/image mode "final")
#   KERNEL=6.12|6.6    kernel flow; 6.12 = Debian source + debs (default),
#                      6.6 = legacy linux-xlnx (rollback variant)
#   FSBL=source|stock  FSBL packed into boot.bin; source = built from the
#                      vendored embeddedsw zynq_fsbl tree (default,
#                      hardware-verified; needs arm-none-eabi-gcc),
#                      stock = blob extracted from the stock boot.bin
#                      (escape hatch)
#   DEBIAN_MIRROR=URL  debootstrap mirror (default: tuna.tsinghua.edu.cn)
#
# Steps 7-10 need sudo (debootstrap/chroot/losetup); run `sudo -v` first or
# let sudo prompt. Everything else runs unprivileged.
set -euo pipefail
cd "$(dirname "$0")/.."

DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"
KDIR=work/linux-xlnx

# Step 6 P1: kernel flow switch. 6.12 (Debian source + debs) is the default;
# KERNEL=6.6 keeps the legacy linux-xlnx path as the rollback variant.
KERNEL="${KERNEL:-6.12}"
if [[ $KERNEL == 6.12 ]]; then
    # write-dtb.sh picks its dtsi tree from this; xlnx default otherwise.
    export KERNEL_DTS_TREE=work/linux-debian-6.12
fi

# Boot-chain switch: uboot (FSBL + full U-Boot as SSBL) is the default
# production chain; stub maps to bootbin/image mode "final" (rollback).
CHAIN="${CHAIN:-uboot}"
case "$CHAIN" in
    uboot) IMG_MODE=uboot ;;
    stub)  IMG_MODE=final ;;
    *) echo "Error: CHAIN must be uboot or stub (got '$CHAIN')" >&2; exit 1 ;;
esac

# FSBL switch: source-built FSBL (from the vendored embeddedsw tree, via
# build-fsbl.sh) is the default — hardware-verified 2026-08-15. FSBL=stock
# packs the blob extracted from the stock boot.bin instead (escape hatch).
# Exported so build-bootbin.sh sees it.
export FSBL="${FSBL:-source}"
case "$FSBL" in
    source|stock) ;;
    *) echo "Error: FSBL must be source or stock (got '$FSBL')" >&2; exit 1 ;;
esac

if [[ "${1:-}" == --clean ]]; then
    echo "== --clean: removing work/ and output/ (rootfs is root-owned, needs sudo) =="
    sudo rm -rf work output
fi
mkdir -p work/tools output

echo "== 1/10 env check =="
bash scripts/env-setup.sh

echo "== 2/10 kernel source =="
if [[ $KERNEL == 6.12 ]]; then
    : # dpkg-source fetch is inside build-kernel-6.12.sh
elif [[ ! -d "$KDIR" ]]; then
    if [[ -d .tmp/linux-xlnx ]]; then
        git clone .tmp/linux-xlnx "$KDIR"   # local cache (fast)
    else
        git clone --depth 1 -b xlnx_rebase_v6.6_LTS \
            https://github.com/Xilinx/linux-xlnx "$KDIR"
    fi
fi

echo "== 3/10 bootgen =="
if [[ ! -x work/tools/bootgen ]]; then
    [[ -d work/bootgen ]] || \
        git clone --depth 1 https://github.com/Xilinx/bootgen work/bootgen
    # -Wno-error demotes REQUIRED with gcc >= 14 (see env-setup.sh header)
    make -C work/bootgen \
        CFLAGS="-O -Wall -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=implicit-function-declaration" \
        CXXFLAGS="-std=c++14 -O -Wall -Wno-reorder -Wno-deprecated-declarations -Wno-aligned-new -Wno-misleading-indentation -Wno-class-memaccess"
    cp work/bootgen/build/bin/bootgen work/tools/
fi

echo "== 4/10 stock FSBL/SSBL =="
# Offsets verified against the stock boot.bin (docs/research/bootbin-repack-spec.md).
# Input is vendored in git (resources/); extracted pieces are generated → work/.
mkdir -p work/stock
if [[ ! -f work/stock/fsbl.bin || ! -f work/stock/ssbl.bin ]]; then
    [[ -f resources/stock/web888-boot.bin ]] || {
        echo "Error: resources/stock/web888-boot.bin missing — incomplete checkout?" >&2
        exit 1
    }
    # sanity: Zynq boot header width-detection word 0xAA995566 at 0x20.
    # (The stock file's 0x24 identification reads "XNLX", not "XLNX" — do not
    # assert on it.)
    python3 - <<'PY'
import sys
with open('resources/stock/web888-boot.bin', 'rb') as f:
    f.seek(0x20)
    magic = f.read(4)
if magic != bytes.fromhex('665599aa'):
    sys.exit('Error: resources/stock/web888-boot.bin has no Zynq boot header')
PY
    dd if=resources/stock/web888-boot.bin of=work/stock/fsbl.bin \
        bs=1 skip=$((0x1700)) count=114696 status=none
    dd if=resources/stock/web888-boot.bin of=work/stock/ssbl.bin \
        bs=1 skip=$((0x1D740)) count=52 status=none
fi

echo "== 5/10 kernel =="
if [[ $KERNEL == 6.12 ]]; then
    bash scripts/build-kernel-6.12.sh
else
    bash scripts/build-kernel.sh
fi

echo "== 6/10 initramfs =="
bash scripts/build-initramfs.sh

echo "== 7/10 debootstrap rootfs =="
if [[ ! -d work/rootfs/etc ]]; then
    sudo debootstrap --arch=armhf --foreign trixie work/rootfs "$DEBIAN_MIRROR"
    sudo cp "$(command -v qemu-arm-static)" work/rootfs/usr/bin/
    sudo chroot work/rootfs /debootstrap/debootstrap --second-stage
fi

echo "== 8/10 configure rootfs =="
bash scripts/configure-rootfs.sh

echo "== 8b/10 kernel modules into rootfs =="
if [[ $KERNEL == 6.12 ]]; then
    bash scripts/install-kernel-deb.sh
else
    bash scripts/install-modules.sh
fi

echo "== 8c/10 build web888-websdr deb =="
bash scripts/fetch-upstream-src.sh websdr
# The armhf build chroot is a prerequisite for build-websdr-deb.sh. Create it
# on demand (idempotent — mk-websdr-chroot.sh skips if already present).
bash scripts/mk-websdr-chroot.sh

# Rebuild if the deb is missing OR stale (any patch/config newer than the deb).
# Without this, a pre-existing deb (e.g. from a prior run before new cherry-picks)
# would be reused and the new patches silently dropped from the image.
rebuild=1
if ls output/websdr/web888-websdr_*_armhf.deb >/dev/null 2>&1; then
    deb=$(ls output/websdr/web888-websdr_*_armhf.deb)
    if [[ -z $(find config/websdr/patches config/websdr/cherry-picks config/websdr/debian-patches-series packaging/web888-websdr -newer "$deb" 2>/dev/null) ]]; then
        rebuild=0
        echo "   deb up to date, skipping: $deb"
    fi
fi
if [[ $rebuild -eq 1 ]]; then
    rm -f output/websdr/web888-websdr_*_armhf.deb
    bash scripts/build-websdr-deb.sh
fi

echo "== 8d/10 install web888-websdr into rootfs =="
bash scripts/install-websdr.sh

echo "== 8e/10 build web888-redpitaya deb =="
bash scripts/fetch-upstream-src.sh redpitaya
# 8e.1 binaries: rebuild if missing or the pinned source clone is newer
if [[ ! -d work/redpitaya-build/bin || -n $(find work/redpitaya-src/projects scripts/hw-test/si5351 -newer work/redpitaya-build/bin 2>/dev/null) ]]; then
    bash scripts/build-redpitaya.sh
fi
# 8e.2 deb: rebuild if missing or any packaging/config/resource input is newer
rebuild=1
if ls output/redpitaya/web888-redpitaya_*_armhf.deb >/dev/null 2>&1; then
    deb=$(ls output/redpitaya/web888-redpitaya_*_armhf.deb)
    if [[ -z $(find packaging/web888-redpitaya config/redpitaya resources/redpitaya-bits work/redpitaya-build/bin -newer "$deb" 2>/dev/null) ]]; then
        rebuild=0
        echo "   deb up to date, skipping: $deb"
    fi
fi
if [[ $rebuild -eq 1 ]]; then
    rm -f output/redpitaya/web888-redpitaya_*_armhf.deb
    bash scripts/build-redpitaya-deb.sh
fi

echo "== 8f/10 install web888-redpitaya into rootfs =="
bash scripts/install-redpitaya.sh

if [[ $CHAIN == uboot ]]; then
    echo "== 8g/10 U-Boot =="
    bash scripts/build-uboot.sh
fi

if [[ $FSBL == source ]]; then
    echo "== 8h/10 FSBL from source =="
    # Same stale-artifact pattern as the deb steps: rebuild if fsbl.bin is
    # missing or any vendored input (embeddedsw tree, hooks, build script)
    # is newer. build-fsbl.sh itself rebuilds deterministically from
    # resources/reference/ into work/fsbl/.
    if [[ ! -f output/fsbl/fsbl.bin || -n $(find resources/reference/embeddedsw-zynq-fsbl resources/reference/redpitaya-fsbl-hooks scripts/build-fsbl.sh -newer output/fsbl/fsbl.bin 2>/dev/null) ]]; then
        bash scripts/build-fsbl.sh
    else
        echo "   fsbl.bin up to date, skipping: output/fsbl/fsbl.bin"
    fi
fi

echo "== 9/10 boot.bin ($IMG_MODE) =="
bash scripts/build-bootbin.sh "$IMG_MODE"

echo "== 10/10 card image ($IMG_MODE) =="
bash scripts/build-image.sh "$IMG_MODE"

echo "== DONE: output/web888-debian-${IMG_MODE}.img (chain=$CHAIN kernel=$KERNEL fsbl=$FSBL) =="
echo "   QEMU gate: bash scripts/test-qemu.sh $IMG_MODE"
echo "   Flash:     bash scripts/flash-image.sh /dev/sdX output/web888-debian-${IMG_MODE}.img"
