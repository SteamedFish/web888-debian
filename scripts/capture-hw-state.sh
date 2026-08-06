#!/bin/sh
# capture-hw-state.sh — run scripts/hw-test/hw-probe.py on the Web-888 and
# save a labelled capture on the host. Used for stock-vs-Debian
# golden-reference diffing:
# run once on our Debian image (baseline) and once on the stock card
# (golden), then diff the two capture files.
#
# Usage: scripts/capture-hw-state.sh <device-ip> <label>
#   label e.g. "debian-noise", "debian-good", "stock-golden"
# Output: .tmp/hw-captures/<label>-<timestamp>.txt (gitignored)
set -eu

IP=${1:?device IP required}
LABEL=${2:?label required}
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTDIR="$REPO/.tmp/hw-captures"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/${LABEL}-$(date +%Y%m%d-%H%M%S).txt"

SSH="sshpass -p changeme ssh -p 22 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 root@$IP"

echo "== capture-hw-state: $LABEL @ $IP -> $OUT" >&2

{
    echo "### label: $LABEL"
    echo "### captured: $(date -Is) (host time)"
    echo
    echo "== uname ==";            $SSH 'uname -a'
    echo "== uptime ==";           $SSH 'uptime'
    echo "== cmdline ==";          $SSH 'cat /proc/cmdline'
    echo "== device-tree model =="; $SSH 'tr -d "\0" < /proc/device-tree/model 2>/dev/null; echo'
    echo "== websdr proc ==";      $SSH 'ps -o pid,etime,%cpu,stat,cmd -C websdr.bin || echo "websdr.bin NOT RUNNING"'
    echo "== websdr journal (key lines) =="
    $SSH 'journalctl -u web888-websdr --no-pager 2>/dev/null | grep -E "ADC_CLOCK|si5351|RX chans|bitstream|error|version|WEB-888" | tail -12 || true'
    echo "== dmesg tail ==";       $SSH 'dmesg | tail -25'
    echo "== hw-probe =="
    $SSH 'python3 -' < "$REPO/scripts/hw-test/hw-probe.py"
} > "$OUT" 2>&1 || true

echo "== saved: $OUT" >&2
cat "$OUT"
