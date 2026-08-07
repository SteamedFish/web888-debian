#!/usr/bin/env bash
# hw-roundtrip.sh — Red Pitaya <-> websdr round-trip hardware gate (TODO P4.5)
# Driven from the build host over SSH against a live Web-888.
# Phases: 10x mode round-trips, reboot-default check, 1h websdr soak.
# Logs to .tmp/hw-roundtrip.log; prints ROUNDTRIP_OK / ROUNDTRIP_FAIL at the end.
#
# Usage: DEVICE=web888.local bash scripts/hw-test/hw-roundtrip.sh

set -u
cd "$(dirname "$0")/../.." || exit 1

DEV=${DEVICE:-web888.local}
SSH="sshpass -p changeme ssh -p 22 -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$DEV"
LOG=.tmp/hw-roundtrip.log
APP=${RP_APP:-sdr_receiver_hpsdr}   # RF-active app: websdr needs ~33 s recovery after it
fails=0

: > "$LOG"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

wait_port() { # $1 = timeout seconds; polls :8073 from host
    local deadline=$((SECONDS + $1))
    while [ $SECONDS -lt $deadline ]; do
        curl -s -o /dev/null --max-time 5 "http://$DEV:8073/" && return 0
        sleep 5
    done
    return 1
}

wait_ssh() { # $1 = timeout seconds
    local deadline=$((SECONDS + $1))
    while [ $SECONDS -lt $deadline ]; do
        $SSH true 2>/dev/null && return 0
        sleep 5
    done
    return 1
}

log "=== phase 1: 10x round-trip websdr <-> $APP (device $DEV) ==="
for i in $(seq 1 10); do
    if ! $SSH "web888-mode $APP" >>"$LOG" 2>&1; then
        log "iter $i: FAIL switch to $APP"; fails=$((fails+1)); continue
    fi
    sleep 20   # RF-active stint
    if ! $SSH "systemctl is-active web888-rpapp@$APP" 2>/dev/null | grep -q active; then
        log "iter $i: FAIL $APP not active after switch"; fails=$((fails+1))
    fi
    if ! $SSH "web888-mode websdr" >>"$LOG" 2>&1; then
        log "iter $i: FAIL switch back to websdr"; fails=$((fails+1)); continue
    fi
    if ! wait_port 90; then
        log "iter $i: FAIL :8073 not back within 90 s"; fails=$((fails+1)); continue
    fi
    if ! $SSH "systemctl is-active web888-websdr" 2>/dev/null | grep -q active; then
        log "iter $i: FAIL websdr service not active"; fails=$((fails+1)); continue
    fi
    log "iter $i OK"
done

log "=== phase 2: reboot-default check (boots into websdr, RP app off) ==="
$SSH "web888-mode $APP" >>"$LOG" 2>&1
$SSH "systemctl reboot" >/dev/null 2>&1
sleep 15
if ! wait_ssh 420; then
    log "phase 2: FAIL device did not come back after reboot"; fails=$((fails+1))
else
    back=$($SSH "systemctl is-active web888-websdr; systemctl is-active web888-rpapp@$APP" 2>/dev/null)
    websdr_st=$(echo "$back" | sed -n 1p)
    rpapp_st=$(echo "$back" | sed -n 2p)
    if [ "$websdr_st" != active ] || [ "$rpapp_st" = active ]; then
        log "phase 2: FAIL websdr=$websdr_st rpapp=$rpapp_st after reboot"
        fails=$((fails+1))
    elif ! wait_port 120; then
        log "phase 2: FAIL :8073 not listening after reboot"
        fails=$((fails+1))
    else
        log "phase 2 OK (websdr=$websdr_st rpapp=$rpapp_st)"
    fi
fi

log "=== phase 3: 1h websdr soak (check every 5 min) ==="
for j in $(seq 1 12); do
    sleep 300
    st=$($SSH "systemctl is-active web888-websdr" 2>/dev/null)
    if [ "$st" != active ]; then
        log "soak check $j: FAIL websdr=$st"; fails=$((fails+1))
    elif ! curl -s -o /dev/null --max-time 5 "http://$DEV:8073/"; then
        log "soak check $j: FAIL :8073 not responding"; fails=$((fails+1))
    else
        load=$($SSH "cut -d' ' -f1-3 /proc/loadavg; free -m | awk '/Mem:/{print \$3\"M/\"\$2\"M\"}'" 2>/dev/null | tr '\n' ' ')
        log "soak check $j OK ($load)"
    fi
done

log "=== final: websocket E2E after soak ==="
if python3 scripts/hw-test/ws-e2e.py "$DEV" 8073 >>"$LOG" 2>&1; then
    log "final E2E OK"
else
    log "final E2E FAIL"; fails=$((fails+1))
fi

if [ $fails -eq 0 ]; then
    log "ROUNDTRIP_OK"
else
    log "ROUNDTRIP_FAIL ($fails failures)"
fi
exit $fails
