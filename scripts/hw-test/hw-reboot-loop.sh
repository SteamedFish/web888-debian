#!/usr/bin/env bash
# hw-reboot-loop.sh — WebSDR deeper HW gate (TODO step 2/3 remainder):
# reboot-loop x3 on the live device, verifying web888-websdr self-heals
# (active as web888 user, :8073 listening) after every boot, then a
# multi-hour soak with periodic health checks and a final websocket E2E.
# Driven from the build host over SSH. Logs to .tmp/hw-reboot-loop.log.
# Prints REBOOTLOOP_OK / REBOOTLOOP_FAIL at the end.
#
# Usage: DEVICE=web888.local bash scripts/hw-test/hw-reboot-loop.sh
#        SOAK_CHECKS=24 (default, 24x5min = 2h) can be overridden for tests.

set -u
cd "$(dirname "$0")/../.." || exit 1

DEV=${DEVICE:-web888.local}
SSH="sshpass -p changeme ssh -p 22 -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$DEV"
LOG=.tmp/hw-reboot-loop.log
SOAK_CHECKS=${SOAK_CHECKS:-24}   # 24 x 5 min = 2 h soak
fails=0

: > "$LOG"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

wait_ssh() { # $1 = timeout seconds
    local deadline=$((SECONDS + $1))
    while [ $SECONDS -lt $deadline ]; do
        $SSH true 2>/dev/null && return 0
        sleep 5
    done
    return 1
}

wait_websdr() { # $1 = timeout seconds; waits for service active + :8073
    local deadline=$((SECONDS + $1))
    while [ $SECONDS -lt $deadline ]; do
        if curl -s -o /dev/null --max-time 5 "http://$DEV:8073/" \
           && $SSH "systemctl is-active web888-websdr" 2>/dev/null | grep -q active; then
            return 0
        fi
        sleep 5
    done
    return 1
}

log "=== phase 1: reboot-loop x3 (device $DEV) ==="
for i in 1 2 3; do
    $SSH "systemctl reboot" >/dev/null 2>&1
    sleep 15
    if ! wait_ssh 420; then
        log "boot $i: FAIL device did not come back"; fails=$((fails+1)); continue
    fi
    if ! wait_websdr 180; then
        log "boot $i: FAIL websdr not healthy within 180 s"; fails=$((fails+1)); continue
    fi
    who=$($SSH "ps -o user= -C websdr.bin" 2>/dev/null | head -1)
    up=$($SSH "cut -d. -f1 /proc/uptime" 2>/dev/null)
    if [ "$who" != web888 ]; then
        log "boot $i: FAIL websdr.bin running as '$who' (expect web888)"; fails=$((fails+1)); continue
    fi
    log "boot $i OK (user=$who, healthy at uptime=${up}s)"
done

log "=== phase 2: ${SOAK_CHECKS}x5min soak ==="
for j in $(seq 1 "$SOAK_CHECKS"); do
    sleep 300
    st=$($SSH "systemctl is-active web888-websdr" 2>/dev/null)
    if [ "$st" != active ]; then
        log "soak $j: FAIL websdr=$st"; fails=$((fails+1))
    elif ! curl -s -o /dev/null --max-time 5 "http://$DEV:8073/"; then
        log "soak $j: FAIL :8073 not responding"; fails=$((fails+1))
    else
        errs=$($SSH "journalctl -u web888-websdr --since '5 min ago' --no-pager -p err 2>/dev/null | grep -vcE 'curl_easy_perform|DX: ERROR|-- No entries --'" 2>/dev/null)
        load=$($SSH "cut -d' ' -f1-3 /proc/loadavg; free -m | awk '/Mem:/{print \$3\"M/\"\$2\"M\"}'" 2>/dev/null | tr '\n' ' ')
        log "soak $j OK (err_lines=$errs $load)"
        if [ "${errs:-0}" -gt 0 ]; then
            log "soak $j: FAIL unexpected error-level journal lines"; fails=$((fails+1))
        fi
    fi
done

log "=== final: websocket E2E ==="
if python3 scripts/hw-test/ws-e2e.py "$DEV" 8073 >>"$LOG" 2>&1; then
    log "final E2E OK"
else
    log "final E2E FAIL"; fails=$((fails+1))
fi

if [ $fails -eq 0 ]; then
    log "REBOOTLOOP_OK"
else
    log "REBOOTLOOP_FAIL ($fails failures)"
fi
exit $fails
