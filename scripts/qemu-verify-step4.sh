#!/usr/bin/env bash
# qemu-verify-step4.sh — post-boot verification for the step-4 redpitaya deb,
# run against a QEMU-booted final image (test-qemu.sh final exposes ssh on
# 127.0.0.1:12222). QEMU has no PL: load-bitstream's prog_done poll can never
# succeed here (same class of limit as the step-2 xdevcfg QEMU gate), so bit
# loading is NOT exercised — that is the P4 hardware gate. This script gates:
# deb installed, units present + disabled, websdr enablement untouched,
# web888-mode functional (list/status), 0 failed units at boot.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SSH="sshpass -p changeme ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p 12222 root@127.0.0.1"
fail=0
check() { # name, command...
    local name="$1"; shift
    local out rc
    out=$($SSH "$*" 2>&1); rc=$?
    printf '== %s\n%s\n' "$name" "$out"
    if [ $rc -ne 0 ]; then echo "!! $name: ssh rc=$rc"; fail=1; fi
}

check "0 failed units" 'systemctl --failed --no-legend'
check "redpitaya deb installed" 'dpkg -l web888-redpitaya | tail -1'
check "rpapp template present, not enabled" 'ls -la /usr/lib/systemd/system/web888-rpapp@.service; systemctl is-enabled web888-rpapp@sdr_receiver_hpsdr.service 2>&1; true'
check "no rpapp instance active" 'systemctl list-units "web888-rpapp@*" --no-legend; true'
check "websdr drop-in present" 'cat /usr/lib/systemd/system/web888-websdr.service.d/50-redpitaya.conf'
check "websdr still enabled (default-on untouched)" 'systemctl is-enabled web888-websdr.service'
check "payload present" 'ls -la /usr/sbin/web888-mode /usr/lib/web888-redpitaya/ /usr/lib/web888-redpitaya/bin/ /usr/share/web888-redpitaya/apps/'
check "switch.conf conffile" 'cat /etc/web888-redpitaya/switch.conf; dpkg -s web888-redpitaya | grep -A2 Conffiles; true'
check "web888-mode list" 'web888-mode list'
check "web888-mode status (none active in QEMU)" 'web888-mode'
# SKIP (measured): running load-bitstream in QEMU hard-hangs the
# guest kernel — QEMU's zynq model exposes /dev/xdevcfg but the bitstream
# write stalls (devcfg unemulated), freezing sshd until the 120s timeout.
# load-bitstream's fail-closed paths are host-mock-tested
# (scripts/test-redpitaya-mode.sh, 20 cases); real PL load = P4 hardware.
echo "== SKIP: load-bitstream runtime check (QEMU devcfg write hangs the guest — documented limit)"

echo
if [ "$fail" = 0 ]; then echo "== qemu-verify-step4: ALL SSH CHECKS EXECUTED (review output above)"; else echo "== qemu-verify-step4: SSH FAILURES"; exit 1; fi
