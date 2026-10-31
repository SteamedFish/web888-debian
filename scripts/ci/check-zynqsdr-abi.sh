#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# check-zynqsdr-abi.sh — ABI lane gate for the /dev/zynqsdr UAPI.
#
#  1. Integrity: the vendored upstream reference header
#     (resources/reference/web888-ng-hw/driver/web888_sdr.h) must match the
#     blob SHA-256 pinned below — any upstream drift invalidates the
#     reference and must be a conscious re-vendor, not silent drift.
#  2. ABI lock: compile scripts/hw-test/zynqsdr-abi-lock.c (independent
#     numeric assertions on all 15 stock ioctls, packed struct
#     sizeof/offsetof, the WF_READ_CONTINUES flag, absence of private
#     commands, and value-parity with the vendored upstream reference)
#     on the build host, RUN it, then cross-compile it statically for
#     armhf (and run it under qemu-arm-static when available).
#  3. Consumer compile check: every userspace consumer of the shared
#     header must compile against it for armhf (catches consumers that
#     reintroduce local ABI duplicates).
#
# The lock does NOT merely recompute the header's own macros: the
# expected ioctl numbers are hand-derived literals, and the upstream
# parity block compares against a different implementation of the same
# ABI (ZSDR_* names vs our ZYNQSDR_* names).
#
# Run from anywhere; read-only apart from a mktemp build dir.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$PWD
LOCK_SRC=scripts/hw-test/zynqsdr-abi-lock.c
UPSTREAM_REF=resources/reference/web888-ng-hw/driver/web888_sdr.h
# blob SHA-256 of driver/web888_sdr.h @ v0.3.0 (commit 767030740a2fdecfebdd383efd23330e6455ff1b);
# see resources/reference/web888-ng-hw/PROVENANCE.md
UPSTREAM_SHA256=2e0d9513ad6034b509a157a32418244b58f5a48144f3d670e725a9941d837f2d

fail=0
say()  { printf '%s\n' "$*"; }
ok()   { say "ok: $*"; }
bad()  { say "FAIL: $*"; fail=1; }

# --- 1. vendored upstream reference integrity ---------------------------
if [[ ! -f $UPSTREAM_REF ]]; then
    bad "$UPSTREAM_REF missing (see PROVENANCE.md for the re-vendor procedure)"
else
    actual=$(sha256sum "$UPSTREAM_REF" | awk '{print $1}')
    if [[ $actual == "$UPSTREAM_SHA256" ]]; then
        ok "upstream reference $UPSTREAM_REF matches pinned blob sha256"
    else
        bad "upstream reference drifted: sha256 $actual != pinned $UPSTREAM_SHA256 (re-vendor consciously and update the pin + PROVENANCE)"
    fi
fi

OUT=$(mktemp -d "${TMPDIR:-/tmp}/zynqsdr-abi.XXXXXX")
trap 'rm -rf "$OUT"' EXIT

# --- 2. ABI lock: host build + run, armhf cross build (+qemu run) -------
CROSS=${CROSS_COMPILE:-arm-linux-gnueabihf-}

if command -v cc >/dev/null 2>&1; then
    if cc -std=c11 -O2 -Wall -Wextra -o "$OUT/abi-lock-host" "$LOCK_SRC" 2>"$OUT/host-cc.log"; then
        ok "host compile of $LOCK_SRC"
        if "$OUT/abi-lock-host"; then
            ok "host ABI lock run"
        else
            bad "host ABI lock binary failed (exit $?)"
        fi
    else
        bad "host compile failed:"; sed 's/^/    /' "$OUT/host-cc.log" | head -20
    fi
else
    say "skip: no host 'cc' found"
fi

if command -v "${CROSS}gcc" >/dev/null 2>&1; then
    # -L scripts/hw-test: the Arch cross spec injects -latomic_asneeded
    # (empty stub archive, see scripts/hw-test/README.md).
    if "${CROSS}gcc" -std=c11 -static -O2 -Wall -Wextra \
        -L"$ROOT/scripts/hw-test" -o "$OUT/abi-lock-arm" "$LOCK_SRC" 2>"$OUT/arm-cc.log"; then
        ok "armhf static cross-compile of $LOCK_SRC"
        if command -v qemu-arm-static >/dev/null 2>&1; then
            if qemu-arm-static "$OUT/abi-lock-arm"; then
                ok "armhf ABI lock run under qemu-arm-static"
            else
                bad "armhf ABI lock binary failed under qemu-arm-static (exit $?)"
            fi
        else
            say "skip: qemu-arm-static not found — armhf binary cross-compile verified, run skipped"
        fi
    else
        bad "armhf cross-compile failed:"; sed 's/^/    /' "$OUT/arm-cc.log" | head -20
    fi
else
    bad "cross compiler ${CROSS}gcc not found (see scripts/env-setup.sh)"
fi

# --- 3. consumers must compile against the shared header ----------------
# Every userspace tool that talks to /dev/zynqsdr must use
# config/kernel/zynqsdr_uapi.h (include-guard enforced here by grep: a
# consumer that re-defines _IOW('Z'...) locally instead of including the
# header is an ABI fork and fails this gate). Each consumer must build
# BOTH for armhf (guest payload) and for the host (the QEMU lane runs the
# tools on the host: `TOOL --emu HOST SSH_PORT`).
consumers=(scripts/hw-test/zynqsdr-smoke.c scripts/hw-test/zynqsdr-rearm-test.c scripts/hw-test/zynqsdr-datapath.c)
for src in "${consumers[@]}"; do
    [[ -f $src ]] || { bad "consumer $src missing"; continue; }
    if grep -Eq "^[[:space:]]*#define[[:space:]]+[A-Z0-9_]+[[:space:]]+_IO(W|R|WR)\('Z'" "$src"; then
        bad "$src defines _IO*('Z',...) locally — include config/kernel/zynqsdr_uapi.h instead"
        continue
    fi
done
if command -v "${CROSS}gcc" >/dev/null 2>&1; then
    for src in "${consumers[@]}"; do
        [[ -f $src ]] || continue
        if "${CROSS}gcc" -std=c11 -static -O2 -Wall -Wextra -pthread \
            -L"$ROOT/scripts/hw-test" -o "$OUT/$(basename "${src%.c}")" "$src" 2>"$OUT/consumer.log"; then
            ok "armhf cross-compile of consumer $src"
        else
            bad "consumer $src failed to cross-compile:"; sed 's/^/    /' "$OUT/consumer.log" | head -20
        fi
    done
fi
if command -v cc >/dev/null 2>&1; then
    for src in "${consumers[@]}"; do
        [[ -f $src ]] || continue
        name="host-$(basename "${src%.c}")"
        if cc -std=c11 -O2 -Wall -Wextra -pthread -o "$OUT/$name" "$src" 2>"$OUT/consumer-host.log"; then
            ok "host compile of consumer $src"
            # bogus arg must print usage and exit 2 (host lane entrypoint sane)
            if "$OUT/$name" __bogus__ >/dev/null 2>&1; then
                bad "host-built $name accepted a bogus argument"
            else
                [[ $? == 2 ]] && ok "host-built $name usage/exit-2 path" \
                             || bad "host-built $name bogus-arg exit != 2"
            fi
        else
            bad "consumer $src failed to compile for host:"; sed 's/^/    /' "$OUT/consumer-host.log" | head -20
        fi
    done
fi

if [[ $fail == 0 ]]; then
    say "ZYNQSDR_ABI_CHECK_OK"
else
    say "ZYNQSDR_ABI_CHECK_FAIL"
fi
exit "$fail"
