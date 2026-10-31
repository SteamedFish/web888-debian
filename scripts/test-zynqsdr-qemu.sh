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
# Optional independent stock-ABI consumer check (system mode only; ignored
# with --baremetal-only): after smoke+rearm, run the pinned upstream web888d
# binary inside the guest against our in-kernel zynqsdr driver:
#   WEB888D=work/upstream/web888-ng/target/armv7-unknown-linux-musleabihf/release/web888d \
#     ./scripts/test-zynqsdr-qemu.sh
# WEB888D is absolute or repo-relative. WEB888D_UI_DIR is optional and
# defaults to scripts/hw-test/web888d-test-ui (a tiny HTTP fixture; no
# Node/pnpm/upstream-UI build is needed for the ABI and /ws checks).
# This validates the
# stock ABI against an independent consumer under the PL model — it is NOT
# hardware verification and NOT a web888d product integration test. After
# HTTP-ready it also proves real /ws data flow (proto2 text control plus
# binary audio + waterfall) with the guest's python3 stdlib via
# scripts/hw-test/web888d-ws-check.py.
#
# Exit codes: 0 = pass, 1 = failure (missing sentinel, timeout, test FAIL),
#             2 = skipped (required artifacts/tools missing — see message).
#
# System mode requires (built by the other lanes):
#   work/qemu-web888/qemu-system-arm   (scripts/build-qemu-web888.sh)
#   output/zImage, output/web888.dtb, output/web888-debian-uboot.img
#                                     (scripts/build-image.sh uboot)
#   host tools: sshpass, sfdisk, mcopy (mtools), python3
#     sfdisk/mcopy/python3 extract the FSBL (BOOT.BIN first stage) from the
#     image's FAT partition so the machine can boot it like the board's ROM
#   host cc + arm-linux-gnueabihf-gcc: fresh host/armhf smoke + rearm tools
#     are built into work/qemu-web888/tools (ZYNQSDR_SMOKE / ZYNQSDR_REARM
#     can override them); each tool accepts TOOL --emu HOST SSH_PORT
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

usage() { sed -n '2,29p' "$0"; }
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

# Build fresh host launchers and their adjacent armhf payloads.  Using a
# work-tree output avoids silently running stale binaries after a C/UAPI
# change (the ABI CI check intentionally builds only in a temporary dir).
TOOL_DIR=work/qemu-web888/tools
mkdir -p "$TOOL_DIR"
if [[ -z ${ZYNQSDR_SMOKE:-} ]]; then
    command -v cc >/dev/null || skip "host cc not found (needed to build zynqsdr-smoke)"
    command -v arm-linux-gnueabihf-gcc >/dev/null || skip "arm-linux-gnueabihf-gcc not found"
    cc -std=c11 -O2 -Wall -Wextra -pthread \
        -o "$TOOL_DIR/zynqsdr-smoke" scripts/hw-test/zynqsdr-smoke.c
    arm-linux-gnueabihf-gcc -std=c11 -static -O2 -Wall -Wextra -pthread \
        -L"$PWD/scripts/hw-test" -o "$TOOL_DIR/zynqsdr-smoke.armhf" \
        scripts/hw-test/zynqsdr-smoke.c
    ZYNQSDR_SMOKE=$TOOL_DIR/zynqsdr-smoke
fi
if [[ -z ${ZYNQSDR_REARM:-} ]]; then
    command -v cc >/dev/null || skip "host cc not found (needed to build zynqsdr-rearm)"
    command -v arm-linux-gnueabihf-gcc >/dev/null || skip "arm-linux-gnueabihf-gcc not found"
    cc -std=c11 -O2 -Wall -Wextra -pthread \
        -o "$TOOL_DIR/zynqsdr-rearm" scripts/hw-test/zynqsdr-rearm-test.c
    arm-linux-gnueabihf-gcc -std=c11 -static -O2 -Wall -Wextra -pthread \
        -L"$PWD/scripts/hw-test" -o "$TOOL_DIR/zynqsdr-rearm.armhf" \
        scripts/hw-test/zynqsdr-rearm-test.c
    ZYNQSDR_REARM=$TOOL_DIR/zynqsdr-rearm
fi
SMOKE=$ZYNQSDR_SMOKE
REARM=$ZYNQSDR_REARM
[[ -x $SMOKE ]] || skip "zynqsdr smoke tool is not executable: $SMOKE"
[[ -x $REARM ]] || skip "zynqsdr rearm tool is not executable: $REARM"

# The web888 machine has no direct -kernel system boot: like the board's
# boot ROM it needs the FSBL. Extract BOOT.BIN from the assembled image's
# FAT partition (as the boot ROM reads it), pull its first stage from the
# Zynq boot header (source offset 0x30, length 0x34), and boot the SD
# image in boot-mode=sd with the FSBL loaded at CPU0's reset vector — the
# same --bootrom flow as upstream work/upstream/web888-ng-hw/emu/run.sh.
# Using the BOOT.BIN inside the image verifies the assembled chain, not a
# side artifact. U-Boot in the image FAT then ext4-loads output/zImage via
# the rootfs /boot/zImage symlink. PL model is part of the machine —
# never touch /dev/xdevcfg inside the guest.
for c in sfdisk mcopy python3; do
    command -v "$c" >/dev/null || skip "$c not found (needed to extract the FSBL from the image; see scripts/env-setup.sh)"
done
IMG=output/web888-debian-uboot.img
BOOTROM_DIR=work/qemu-web888/bootrom
rm -rf "$BOOTROM_DIR"   # bounded scratch dir this script owns
mkdir -p "$BOOTROM_DIR"
QPID=
cleanup() {
    if [[ -n $QPID ]]; then
        kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
    fi
    rm -rf "$BOOTROM_DIR"
}
trap cleanup EXIT
part_off=$(sfdisk -d "$IMG" | sed -n 's/.*: start= *\([0-9]*\),.*/\1/p' | head -n 1)
[[ $part_off =~ ^[0-9]+$ ]] || fail "cannot parse first partition offset of $IMG (sfdisk output changed?)"
MTOOLS_SKIP_CHECK=1 mcopy -i "$IMG@@$((part_off * 512))" ::BOOT.BIN "$BOOTROM_DIR/BOOT.BIN" \
    || fail "no BOOT.BIN on the first partition of $IMG (image not assembled?)"
python3 -I - "$BOOTROM_DIR/BOOT.BIN" "$BOOTROM_DIR/fsbl.bin" <<'PY' || fail "BOOT.BIN in $IMG is not a Zynq boot image (bad XNLX magic?)"
import struct, sys
d = open(sys.argv[1], 'rb').read()
assert d[0x24:0x28] == b'XNLX', 'not a Zynq boot image'
off, ln = struct.unpack_from('<II', d, 0x30)
open(sys.argv[2], 'wb').write(d[off:off + ln])
PY
SNAP=,snapshot=on
[[ $WRITE_SD == 1 ]] && SNAP=
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5 -o PreferredAuthentications=password
    -o PubkeyAuthentication=no -p "$SSH_PORT")
# scp wants -P for the port (ssh uses -p); same options otherwise.
SCP_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5 -o PreferredAuthentications=password
    -o PubkeyAuthentication=no -P "$SSH_PORT")
: > "$SYS_LOG"
echo ">> booting (timeout ${TIMEOUT}s, serial log: $SYS_LOG)"
"$QEMU" -M web888,boot-mode=sd -m 512M -smp 2 -display none -serial stdio -monitor none \
    -device "loader,file=$BOOTROM_DIR/fsbl.bin,addr=0x0,force-raw=on" \
    -drive "file=$IMG,if=sd,format=raw,index=0$SNAP" \
    -net nic -net "user,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
    -no-reboot > "$SYS_LOG" 2>&1 &
QPID=$!

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

# ------------------------------------------------- web888d consumer check
# Optional, opt-in only (default test behaviour unchanged). Runs the pinned
# upstream web888d binary inside the guest against our in-kernel zynqsdr
# driver: this cross-checks the stock ABI with an independent userspace
# consumer under the PL model. NOT hardware verification, NOT a web888d
# product integration test (no service/package is installed; the guest runs
# from a scratch dir and the image is booted with snapshot=on).
# Web888d is started with --bitstream none: the PL model is already loaded
# and /dev/xdevcfg must never be written.
run_web888d_consumer() {
    local bin ui gdir=/tmp/web888d-abi-check pid rc
    bin=$WEB888D; [[ $bin == /* ]] || bin=$PWD/$bin
    ui=${WEB888D_UI_DIR:-scripts/hw-test/web888d-test-ui}
    [[ $ui == /* ]] || ui=$PWD/$ui
    [[ -f $bin ]] || fail "WEB888D binary not found: $bin"
    [[ -d $ui ]] || fail "WEB888D_UI_DIR not found: $ui"

    echo ">> web888d consumer check: $(basename "$bin") + $(basename "$ui")"
    sshpass -p changeme ssh "${SSH_OPTS[@]}" root@127.0.0.1 \
        "rm -rf $gdir && mkdir -p $gdir/state" \
        || fail "web888d check: cannot prepare guest dir $gdir"
    sshpass -p changeme scp "${SCP_OPTS[@]}" "$bin" "root@127.0.0.1:$gdir/web888d" \
        || fail "web888d check: scp of $bin failed"
    sshpass -p changeme scp -r "${SCP_OPTS[@]}" "$ui" "root@127.0.0.1:$gdir/ui" \
        || fail "web888d check: scp of $ui failed"
    sshpass -p changeme ssh "${SSH_OPTS[@]}" root@127.0.0.1 \
        "systemctl stop web888-websdr.service" \
        || fail "web888d check: cannot stop web888-websdr.service"

    # setsid detaches web888d from the ssh session scope (logind would kill
    # it when the ssh session closes). The guest-side poll below is bounded
    # (90s) and checks liveness, fatal log lines and the guest-local HTTP
    # socket, so a failed startup can never hang this script.
    pid=$(timeout --kill-after=5s 20s sshpass -p changeme ssh "${SSH_OPTS[@]}" root@127.0.0.1 \
        "chmod +x $gdir/web888d && { setsid nohup $gdir/web888d serve \
            --backend zynqsdr --bitstream none --no-hpsdr --no-tls \
            --http 127.0.0.1:8073 --ui-dir $gdir/ui --state-dir $gdir/state \
            < /dev/null > $gdir/web888d.log 2>&1 & echo \$!; }" | tr -d '[:space:]') \
        || fail "web888d check: guest start command failed"
    [[ $pid =~ ^[0-9]+$ ]] || fail "web888d check: no guest pid (got '$pid')"

    rc=$(timeout --kill-after=5s 120s sshpass -p changeme ssh "${SSH_OPTS[@]}" root@127.0.0.1 "
        for i in \$(seq 1 90); do
            kill -0 $pid 2>/dev/null || { echo DEAD; exit 0; }
            grep -qi 'fatal' $gdir/web888d.log 2>/dev/null && { echo FATAL; exit 0; }
            (exec 3<>/dev/tcp/127.0.0.1/8073 && \
                printf 'GET / HTTP/1.0\r\n\r\n' >&3 && \
                IFS= read -r status <&3 && [[ \${status:-} == HTTP/*\ 200* ]]) \
                2>/dev/null && { echo READY; exit 0; }
            sleep 1
        done; echo TIMEOUT") \
        || fail "web888d check: guest poll command failed (ssh error)"
    if [[ $rc != READY ]]; then
        echo "---- web888d guest log ($gdir/web888d.log) ----" >&2
        timeout --kill-after=5s 20s sshpass -p changeme ssh "${SSH_OPTS[@]}" root@127.0.0.1 \
            "tail -40 $gdir/web888d.log" >&2 || true
        fail "web888d check: guest reported '$rc' (pid $pid)"
    fi
    # Still alive after becoming ready — now prove real data flow through
    # this independent stock-ABI consumer: RFC6455 /ws, protocol-2 text
    # control (hello/state/lease) and binary audio/waterfall frames, driven
    # by the guest's own python3 stdlib (scripts/hw-test/web888d-ws-check.py
    # piped to `python3 -`). --check-model-tone asserts the QEMU model's
    # deterministic 10 MHz tone (df=117.1875 Hz); stale/default full-view WF
    # frames are excluded from that assertion.
    echo ">> web888d /ws data-path check (guest python3)"
    timeout --kill-after=5s 180s sshpass -p changeme ssh "${SSH_OPTS[@]}" root@127.0.0.1 \
        'timeout --kill-after=5s 180s python3 - --host 127.0.0.1 --port 8073 --check-model-tone' \
        < scripts/hw-test/web888d-ws-check.py \
        || fail "web888d WebSocket data path failed"
    echo ">> web888d WebSocket data path: PASS (QEMU model, not hardware)"
    # Then stop it.
    sshpass -p changeme ssh "${SSH_OPTS[@]}" root@127.0.0.1 "kill -0 $pid" \
        || fail "web888d check: web888d exited during the data-path check"
    sshpass -p changeme ssh "${SSH_OPTS[@]}" root@127.0.0.1 "kill $pid" \
        || fail "web888d check: cannot stop web888d (pid $pid)"
    echo "== web888d consumer check: PASS =="
    echo "NOTE: web888d startup under the model validates the stock ABI for an"
    echo "      independent consumer — not hardware, not web888d integration."
}
[[ -n ${WEB888D:-} ]] && run_web888d_consumer

cleanup; trap - EXIT
echo "PASS: zynqsdr QEMU model validation complete"
echo "NOTE: this validates against the QEMU PL model only — NOT hardware verification."
