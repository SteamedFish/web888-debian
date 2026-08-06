#!/usr/bin/env bash
# hw-gate-step2.sh — step-2 hardware gate (zynqsdr driver bring-up: M1/M3/M4).
# Runs against the device over SSH; every sub-gate prints PASS/FAIL.
# usage: hw-gate-step2.sh <device-ip>
set -uo pipefail
cd "$(dirname "$0")/.."

IP="${1:?usage: hw-gate-step2.sh <device-ip> (discover via the ce:cf:3f:* MAC prefix)}"
SSH="sshpass -p changeme ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@$IP"
FAILURES=0

gate() { # gate <name> <remote-command> [expected-substring]
    local name="$1" cmd="$2" expect="${3:-}"
    local out rc
    out=$($SSH "$cmd" 2>&1); rc=$?
    if (( rc != 0 )); then
        echo "FAIL  $name (ssh rc=$rc): $out"; FAILURES=$((FAILURES+1)); return
    fi
    if [[ -n $expect && $out != *"$expect"* ]]; then
        echo "FAIL  $name (want '$expect'): $out"; FAILURES=$((FAILURES+1)); return
    fi
    echo "PASS  $name: ${out:-ok}"
}

echo "== hw-gate-step2 against $IP =="

# -- M1: devcfg --
gate "M1 modprobe xilinx_devcfg"   "modprobe xilinx_devcfg && echo ok" "ok"
gate "M1 /dev/xdevcfg exists"      "ls -l /dev/xdevcfg" "244, 0"
gate "M1 bitstream upload"         "cat > /dev/xdevcfg" < resources/stock-card/websdr_hf.bit ""
gate "M1 prog_done=1"              "cat /sys/devices/soc0/axi/f8007000.devcfg/prog_done" "1"

# -- M3: zynqsdr control plane --
gate "M3 modprobe zynqsdr"         "modprobe zynqsdr && echo ok" "ok"
gate "M3 /dev/zynqsdr exists"      "ls -l /dev/zynqsdr" "zynqsdr"
gate "M3 dmesg probe line"         "dmesg | grep zynqsdr | tail -2" "zynqsdr"

# -- M4: data plane smoke (binary baked into image at /root/zynqsdr-smoke) --
gate "M4 GET_DNA (stock: 4a8a0e6000c0)" \
     "cd /root && ./zynqsdr-smoke 2>&1 | grep -i dna" "dna"
gate "M4 GET_SIGNATURE (rx=4 wf=4)" \
     "cd /root && ./zynqsdr-smoke 2>&1 | grep -i sig" "sig"
gate "M4 IRQ/DMA counters"         "grep -i 'zynqsdr\|sdr' /proc/interrupts" ""

echo "== $FAILURES failure(s) =="
exit $((FAILURES > 0))
