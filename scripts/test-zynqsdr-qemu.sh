#!/usr/bin/env bash
# test-zynqsdr-qemu.sh — zynqsdr driver validation on the vendored web888 QEMU
# machine (resources/qemu-web888, from jeskko/web888-ng-hw v0.3.0 — see
# resources/qemu-web888/PROVENANCE.md).
#
# This runs OUR kernel/dtb/rootfs image on the emulated web888 board (the PL
# model web888-pl is loaded by the machine itself) and then drives the
# zynqsdr smoke test and the driver rearm test inside the guest.
#
#   ./scripts/test-zynqsdr-qemu.sh                 # baremetal gate + full system mode
#   ./scripts/test-zynqsdr-qemu.sh --baremetal-only  # fast mode: PL model smoke test only
#
# Exit codes: 0 = pass, 1 = failure (missing sentinel, timeout, test FAIL),
#             2 = skipped (required artifacts/tools missing — see message).
#
# System mode requires (built by the other lanes):
#   work/qemu-web888/qemu-system-arm   (scripts/build-qemu-web888.sh)
#   output/zImage, output/web888.dtb, output/web888-debian-uboot.img
#                                     (scripts/build-image.sh uboot)
#   zynqsdr smoke + rearm test tools accepting:  TOOL --emu HOST SSH_PORT
#     searched as $ZYNQSDR_SMOKE / scripts/hw-test/zynqsdr-smoke / scripts/zynqsdr-smoke
#     and     $ZYNQSDR_REARM / scripts/hw-test/zynqsdr-rearm / scripts/zynqsdr-rearm
#
# HARD RULES (emulation lane):
#   * The PL model is already loaded — guest/host code must NEVER write
#     /dev/xdevcfg (there is no devcfg on the web888 machine; a write would
#     hang or fault). The smoke/rearm tools are invoked with --emu for this.
#   * This is QEMU-model validation only, NEVER hardware verification.
set -euo pipefail
cd "$(dirname "$0")/.."

QEMU=work/qemu-web888/qemu-system-arm
BM_BUILD=work/qemu-web888/baremetal
BM_LOG=work/qemu-web888/baremetal/pltest.log
SYS_LOG=work/qemu-web888/system-serial.log
SSH_PORT=${SSH_PORT:-12223}
BAREMETAL_ONLY=0
WRITE_SD=0
TIMEOUT=${QEMU_ZYNQSDR_TIMEOUT:-900}
BM_TIMEOUT=90

usage() { sed -n '2,18p' "$0"; }
while [[ $# -gt 0 ]]; do
    case "$1" in
    --baremetal-only) BAREMETAL_ONLY=1; shift ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --ssh-port) SSH_PORT=$2; shift 2 ;;
    --write-sd) WRITE_SD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option $1" >&2; usage >&2; exit 1 ;;
    esac
done

skip() { echo "SKIP: $*" >&2; exit 2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- baremetal
# Fast gate: the vendored freestanding PL test must print RESULT: PASS.
run_baremetal() {
    echo "== baremetal PL model test =="
    [[ -x $QEMU ]] || fail "$QEMU missing — run scripts/build-qemu-web888.sh first"
    command -v arm-none-eabi-gcc >/dev/null || fail "arm-none-eabi-gcc not found (see scripts/env-setup.sh)"
    mkdir -p "$BM_BUILD"
    cp resources/qemu-web888/tests/baremetal/{link.ld,Makefile,pltest.c,start.S} "$BM_BUILD/"
    make -s -C "$BM_BUILD"
    : > "$BM_LOG"
    "$QEMU" -M web888 -smp 1 -display none -serial stdio -monitor none \
        -kernel "$BM_BUILD/pltest.elf" \
        -global web888-pl.scene=10001000:-20 -global web888-pl.noise= \
        > "$BM_LOG" 2>&1 &
    local pid=$! rc=1
    for ((i = 0; i < BM_TIMEOUT; i++)); do
        if tr -d '\r' < "$BM_LOG" | grep -q '^RESULT:'; then rc=0; break; fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    tr -d '\r' < "$BM_LOG" | sed '/^RESULT/q'
    if [[ $rc != 0 ]]; then
        fail "baremetal test produced no RESULT within ${BM_TIMEOUT}s (log: $BM_LOG)"
    fi
    tr -d '\r' < "$BM_LOG" | grep -q '^RESULT: PASS' \
        || fail "baremetal test FAILED (log: $BM_LOG)"
    echo "== baremetal: PASS =="
}

run_baremetal
[[ $BAREMETAL_ONLY == 1 ]] && { echo "--baremetal-only: done"; exit 0; }

# ---------------------------------------------------------------- system
echo "== system mode: web888 QEMU + our kernel/dtb/rootfs =="
[[ -x $QEMU ]] || fail "$QEMU missing — run scripts/build-qemu-web888.sh first"
for f in output/zImage output/web888.dtb output/web888-debian-uboot.img; do
    [[ -f $f ]] || skip "$f missing — run scripts/build-image.sh uboot first"
done
command -v sshpass >/dev/null || skip "sshpass not found (needed to drive the guest over forwarded ssh)"

SMOKE=${ZYNQSDR_SMOKE:-}
for c in "$SMOKE" scripts/hw-test/zynqsdr-smoke scripts/zynqsdr-smoke; do
    [[ -n $c && -f $c && -x $c ]] && { SMOKE=$c; break; }
done
[[ -n $SMOKE ]] || skip "zynqsdr smoke tool missing (set ZYNQSDR_SMOKE; expected a tool accepting '--emu HOST SSH_PORT')"
REARM=${ZYNQSDR_REARM:-}
for c in "$REARM" scripts/hw-test/zynqsdr-rearm scripts/zynqsdr-rearm; do
    [[ -n $c && -f $c && -x $c ]] && { REARM=$c; break; }
done
[[ -n $REARM ]] || skip "zynqsdr rearm test missing (set ZYNQSDR_REARM; expected a tool accepting '--emu HOST SSH_PORT')"

# The web888 machine boots the Zynq like the board's boot ROM: no direct
# -kernel; U-Boot in the image FAT ext4-loads output/zImage via the rootfs
# /boot/zImage symlink. PL model is part of the machine — never touch
# /dev/xdevcfg inside the guest.
SNAP=,snapshot=on
[[ $WRITE_SD == 1 ]] && SNAP=
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5 -o PreferredAuthentications=password
    -o PubkeyAuthentication=no -p "$SSH_PORT")
: > "$SYS_LOG"
echo ">> booting (timeout ${TIMEOUT}s, serial log: $SYS_LOG)"
"$QEMU" -M web888 -m 512M -smp 2 -display none -serial stdio -monitor none \
    -drive "file=output/web888-debian-uboot.img,if=sd,format=raw,index=0$SNAP" \
    -net nic -net "user,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
    -no-reboot > "$SYS_LOG" 2>&1 &
QPID=$!
cleanup() { kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true; }
trap cleanup EXIT

# Boot sentinel: getty login prompt on the serial console AND ssh reachable.
booted=0
for ((i = 0; i < TIMEOUT; i++)); do
    if ! kill -0 "$QPID" 2>/dev/null; then
        echo "---- last serial output ----" >&2; tail -30 "$SYS_LOG" >&2 || true
        fail "QEMU exited before boot sentinel (see $SYS_LOG)"
    fi
    if tr -d '\r' < "$SYS_LOG" | grep -qE 'login:' && \
       sshpass -p changeme ssh "${SSH_OPTS[@]}" root@127.0.0.1 true 2>/dev/null; then
        booted=1; break
    fi
    sleep 1
done
[[ $booted == 1 ]] || fail "no boot sentinel (login prompt + ssh) within ${TIMEOUT}s (see $SYS_LOG)"
echo ">> guest booted"

# The zynqsdr driver must be live in the guest before the smoke test:
# that is the kernel-side success sentinel. The tools run with --emu and
# must not write /dev/xdevcfg (PL model is already loaded).
sshpass -p changeme ssh "${SSH_OPTS[@]}" root@127.0.0.1 \
    'dmesg | grep -i zynqsdr' >> "$SYS_LOG" 2>&1 \
    || fail "zynqsdr driver did not probe in guest (dmesg has no zynqsdr)"
echo ">> zynqsdr probed in guest"

echo ">> smoke: $SMOKE --emu 127.0.0.1 $SSH_PORT"
"$SMOKE" --emu 127.0.0.1 "$SSH_PORT" || fail "zynqsdr smoke test failed"
echo ">> rearm: $REARM --emu 127.0.0.1 $SSH_PORT"
"$REARM" --emu 127.0.0.1 "$SSH_PORT" || fail "zynqsdr rearm test failed"

cleanup; trap - EXIT
echo "PASS: zynqsdr QEMU model validation complete"
echo "NOTE: this validates against the QEMU PL model only — NOT hardware verification."
