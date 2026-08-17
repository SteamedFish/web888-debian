#!/usr/bin/env bash
# env-setup.sh — verify the host build toolchain for web888-debian step 1.
#
# Run from the repo root. Exits non-zero if anything required is missing.
# All tooling is native (no container required).
#
# bootgen is NOT a system package. Build it once into work/tools/ with:
#   git clone --depth 1 https://github.com/Xilinx/bootgen work/bootgen
#   make -C work/bootgen \
#     CFLAGS="-O -Wall -Wno-error=incompatible-pointer-types \
#             -Wno-error=int-conversion -Wno-error=implicit-function-declaration" \
#     CXXFLAGS="-std=c++14 -O -Wall -Wno-reorder -Wno-deprecated-declarations \
#               -Wno-aligned-new -Wno-misleading-indentation -Wno-class-memaccess"
#   cp work/bootgen/build/bin/bootgen work/tools/
# (the -Wno-error demotes are REQUIRED with gcc >= 14; gcc 16 turns
#  incompatible-pointer-types etc. into hard errors on bootgen master's C code)
#
# Debian package downloads use TUNA by default (deb.debian.org is very slow
# from this host). Override with: DEBIAN_MIRROR=https://deb.debian.org/debian

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/work/tools"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"

fail=0

report() { printf '%-28s %s\n' "$1" "$2"; }

need_cmd() {
    local cmd="$1" pkg="$2"
    if command -v "$cmd" &>/dev/null; then
        report "OK  $cmd" "$($cmd --version 2>/dev/null | head -n 1 || echo present)"
    else
        report "MISSING  $cmd" "pacman -S $pkg"
        fail=1
    fi
}

echo "== System packages =="
need_cmd debootstrap              debootstrap
need_cmd arm-linux-gnueabihf-gcc  arm-linux-gnueabihf-gcc
need_cmd arm-none-eabi-gcc        arm-none-eabi-gcc
need_cmd arm-none-eabi-objcopy    arm-none-eabi-binutils
need_cmd dtc                      dtc
need_cmd mkimage                  uboot-tools
need_cmd qemu-system-arm          qemu-system-arm
need_cmd qemu-arm-static          qemu-user-static
need_cmd mkfs.vfat                dosfstools
need_cmd mkfs.ext4                e2fsprogs
need_cmd parted                   parted
need_cmd cpio                     cpio
need_cmd rsync                    rsync
need_cmd wget                     wget
need_cmd git                      git

echo
echo "== Project-local tools =="
if [[ -x "$TOOLS_DIR/bootgen" ]]; then
    report "OK  bootgen" "$("$TOOLS_DIR/bootgen" -help 2>&1 | grep -m1 Bootgen || echo present)"
else
    # not fatal: bootgen is project-built, build-all.sh bootstraps it (step 3)
    report "NOTE  bootgen" "will be built into work/tools/ by build-all.sh (see header)"
fi

echo
echo "== binfmt_misc (ARM execution on x86_64 host) =="
BINFMT_ENTRY=/proc/sys/fs/binfmt_misc/qemu-arm
if [[ -r "$BINFMT_ENTRY" ]] && head -n 1 "$BINFMT_ENTRY" | grep --quiet '^enabled'; then
    INTERP=$(grep '^interpreter ' "$BINFMT_ENTRY" | cut --delimiter=' ' --fields=2)
    if [[ -n "$INTERP" && -x "$INTERP" ]]; then
        report "OK  binfmt qemu-arm" "$INTERP"
    else
        report "BROKEN  binfmt qemu-arm" "interpreter '$INTERP' not executable"
        fail=1
    fi
else
    report "MISSING  binfmt qemu-arm" "systemd-binfmt should register it (qemu-user-static)"
    fail=1
fi

echo
echo "== Smoke test: cross-gcc + qemu + binfmt =="
# KNOWN QUIRK (Arch): arm-linux-gnueabihf-gcc 16.1.1 cannot link HOSTED
# userspace programs — the package ships no libatomic.a / libatomic.spec, so the
# driver emits a literal `-latomic_asneeded` that ld cannot resolve. Our pipeline
# never needs hosted cross-links (kernel has its own linkage; debootstrap/busybox
# are prebuilt; WebSDR/Red Pitaya will be built chroot-NATIVE under qemu). So the
# smoke test deliberately uses a FREESTANDING static binary — the same linkage
# style the kernel build uses — executed through binfmt_misc.
# -marm is REQUIRED: Ubuntu's armhf gcc defaults to Thumb-2, where r7 is the
# frame pointer and "r7 cannot be used in 'asm'" fails the compile; the svc
# ABI test needs r7 as the syscall-number register (Arch gcc defaults to ARM
# mode, which is why this only bit CI runners).
if command -v arm-linux-gnueabihf-gcc &>/dev/null; then
    SMOKE_DIR=$(mktemp --directory)
    trap 'rm -rf "$SMOKE_DIR"' EXIT
    cat > "$SMOKE_DIR/hello.c" <<'EOF'
void _start(void) {
    const char msg[] = "CROSS-ARM-OK\n";
    register long r0 __asm__("r0") = 1;
    register const char *r1 __asm__("r1") = msg;
    register long r2 __asm__("r2") = sizeof(msg) - 1;
    register long r7 __asm__("r7") = 4;
    __asm__ volatile("svc 0" : : "r"(r0), "r"(r1), "r"(r2), "r"(r7) : "memory");
    register long e0 __asm__("r0") = 0;
    register long e7 __asm__("r7") = 1;
    __asm__ volatile("svc 0" : : "r"(e0), "r"(e7));
}
EOF
    if arm-linux-gnueabihf-gcc -marm -ffreestanding -fno-stack-protector -nostdlib -static \
            -Wl,--build-id=none -o "$SMOKE_DIR/hello" "$SMOKE_DIR/hello.c" 2>"$SMOKE_DIR/cc.log"; then
        OUT=$("$SMOKE_DIR/hello" 2>&1 || true)
        if [[ "$OUT" == "CROSS-ARM-OK" ]]; then
            report "OK  cross+binfmt" "$(file --brief "$SMOKE_DIR/hello" | cut --delimiter=',' --fields=1-2)"
        else
            report "FAIL  cross+binfmt" "ran but got: '$OUT'"
            fail=1
        fi
    else
        report "FAIL  cross-gcc" "$(head -n 1 "$SMOKE_DIR/cc.log")"
        fail=1
    fi
fi

echo
report "DEBIAN_MIRROR" "$DEBIAN_MIRROR"

if [[ "$fail" -ne 0 ]]; then
    echo
    echo "env-setup: FAILURES present — fix the MISSING/BROKEN/FAIL lines above." >&2
    exit 1
fi
echo
echo "env-setup: toolchain OK."
