#!/usr/bin/env bash
# test-redpitaya-mode.sh — host test harness for packaging/web888-redpitaya/
# {load-bitstream, web888-mode, rpapp-hold} with fully mocked externals
# (systemctl, /dev/xdevcfg, prog_done sysfs, si5351-init, id).
# No root, no hardware, no systemd required. Scratch lives in .tmp/ per repo
# rule. Exit 0 iff every case passes.

set -u
cd "$(dirname "$0")/.." || exit 1

PKG=packaging/web888-redpitaya
SANDBOX=.tmp/test-redpitaya-mode

pass=0 fail=0
ok()   { printf 'PASS %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
cond=1
check() { # name, condition-already-evaluated (0/1)
    if [ "$cond" = 0 ]; then ok "$1"; else bad "$1"; fi
}

# ---------- sandbox ----------
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"/{bin,apps/sdr_receiver,apps/led_blinker,apps/sdr_receiver_hpsdr,state,etc}
for app in sdr_receiver led_blinker sdr_receiver_hpsdr; do
    echo "DUMMY-BITSTREAM-$app" > "$SANDBOX/apps/$app/$app.bit"
done
: > "$SANDBOX/xdevcfg"          # fake device node (regular file: cat > works)
echo 1 > "$SANDBOX/prog_done"   # default: PL configures fine
: > "$SANDBOX/systemctl.log"
: > "$SANDBOX/order.log"
echo inactive > "$SANDBOX/state/websdr"   # is-active script states

export MOCK_LOG="$PWD/$SANDBOX/systemctl.log"
export MOCK_STATE_DIR="$PWD/$SANDBOX/state"
export MOCK_ORDER="$PWD/$SANDBOX/order.log"

cat > "$SANDBOX/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$MOCK_LOG"
if [ "$1" = is-active ]; then
    unit=${2%.service}; unit=${unit#web888-rpapp@}
    case $2 in
        web888-websdr.service) key=websdr ;;
        web888-rpapp@*.service) key="$unit" ;;
        *) key=$2 ;;
    esac
    state=$(cat "$MOCK_STATE_DIR/$key" 2>/dev/null || echo inactive)
    echo "$state"
    [ "$state" = active ] && exit 0 || exit 3
fi
exit 0
EOF

cat > "$SANDBOX/bin/si5351-init" <<'EOF'
#!/usr/bin/env bash
# record xdevcfg size AT INVOCATION so the harness can prove call ordering
# (si5351 must run BEFORE the bitstream cat when SI5351_RESET=1)
echo "si5351-init xdevcfg_size=$(stat -c%s "$WEB888_XDEVCFG" 2>/dev/null || echo -1)" >> "$MOCK_ORDER"
EOF

cat > "$SANDBOX/bin/id-nonroot" <<'EOF'
#!/bin/sh
if [ "$1" = -u ]; then echo 1000; else exec /usr/bin/id "$@"; fi
EOF

# default id mock = root (switching subcommands require uid 0); case 15 swaps
# in id-nonroot temporarily
cat > "$SANDBOX/bin/id" <<'EOF'
#!/bin/sh
if [ "$1" = -u ]; then echo 0; else exec /usr/bin/id "$@"; fi
EOF

chmod +x "$SANDBOX/bin/systemctl" "$SANDBOX/bin/si5351-init" "$SANDBOX/bin/id-nonroot" "$SANDBOX/bin/id"

# ---------- env shared by all load-bitstream runs ----------
lb_env() {
    env \
        WEB888_RP_APPS_DIR="$PWD/$SANDBOX/apps" \
        WEB888_XDEVCFG="$PWD/$SANDBOX/xdevcfg" \
        WEB888_PROG_DONE="$PWD/$SANDBOX/prog_done" \
        WEB888_SI5351_INIT="$PWD/$SANDBOX/bin/si5351-init" \
        WEB888_SWITCH_CONF="$PWD/$SANDBOX/etc/switch.conf" \
        WEB888_PROG_DONE_TIMEOUT="${LB_TIMEOUT:-5}" \
        WEB888_PROG_DONE_INTERVAL="${LB_INTERVAL:-0.1}" \
        "$@"
}
wm_env() {
    env \
        WEB888_SYSTEMCTL="${WM_SYSTEMCTL:-$PWD/$SANDBOX/bin/systemctl}" \
        WEB888_RP_APPS_DIR="$PWD/$SANDBOX/apps" \
        PATH="$PWD/$SANDBOX/bin:$PATH" \
        "$@"
}

echo "== load-bitstream =="

# 1. happy path
out=$(lb_env bash "$PKG/load-bitstream" sdr_receiver 2>&1); rc=$?
if [ $rc = 0 ] && [ "$(cat "$SANDBOX/xdevcfg")" = "DUMMY-BITSTREAM-sdr_receiver" ] \
    && printf '%s' "$out" | grep -q 'prog_done=1'; then cond=0; else cond=1; fi
check "load-bitstream happy path (rc=0, bit written, prog_done reported)"

# 2. invalid charset
rc=0; lb_env bash "$PKG/load-bitstream" 'Bad-App!' >/dev/null 2>&1 || rc=$?
if [ $rc = 1 ]; then cond=0; else cond=1; fi
check "load-bitstream rejects invalid charset"

# 3. path traversal
rc=0; lb_env bash "$PKG/load-bitstream" '../etc' >/dev/null 2>&1 || rc=$?
if [ $rc = 1 ]; then cond=0; else cond=1; fi
check "load-bitstream rejects path traversal"

# 4. valid charset, no such app
rc=0; lb_env bash "$PKG/load-bitstream" nosuchapp >/dev/null 2>&1 || rc=$?
if [ $rc = 1 ]; then cond=0; else cond=1; fi
check "load-bitstream rejects app without bitstream"

# 5. missing xdevcfg
rc=0; lb_env WEB888_XDEVCFG="$PWD/$SANDBOX/no-such-dev" \
    bash "$PKG/load-bitstream" sdr_receiver >/dev/null 2>&1 || rc=$?
if [ $rc = 1 ]; then cond=0; else cond=1; fi
check "load-bitstream fails closed when xdevcfg missing"

# 6. prog_done timeout
echo 0 > "$SANDBOX/prog_done"
rc=0; LB_TIMEOUT=0.3 LB_INTERVAL=0.05 lb_env bash "$PKG/load-bitstream" sdr_receiver >/dev/null 2>&1 || rc=$?
if [ $rc = 1 ]; then cond=0; else cond=1; fi
check "load-bitstream fails on prog_done timeout"
echo 1 > "$SANDBOX/prog_done"

# 7. SI5351_RESET=1 -> si5351-init runs BEFORE the bitstream cat
: > "$SANDBOX/xdevcfg"; : > "$SANDBOX/order.log"
echo 'SI5351_RESET=1' > "$SANDBOX/etc/switch.conf"
lb_env bash "$PKG/load-bitstream" sdr_receiver >/dev/null 2>&1
if grep -q 'si5351-init xdevcfg_size=0' "$SANDBOX/order.log" \
    && [ "$(cat "$SANDBOX/xdevcfg")" = "DUMMY-BITSTREAM-sdr_receiver" ]; then cond=0; else cond=1; fi
check "SI5351_RESET=1 runs si5351-init before bitstream load"

# 8. SI5351_RESET=0 -> si5351-init NOT run
: > "$SANDBOX/order.log"
echo 'SI5351_RESET=0' > "$SANDBOX/etc/switch.conf"
lb_env bash "$PKG/load-bitstream" sdr_receiver >/dev/null 2>&1
if [ ! -s "$SANDBOX/order.log" ]; then cond=0; else cond=1; fi
check "SI5351_RESET=0 skips si5351-init"

# 9. missing switch.conf tolerated
rm -f "$SANDBOX/etc/switch.conf"
if lb_env bash "$PKG/load-bitstream" sdr_receiver >/dev/null 2>&1; then cond=0; else cond=1; fi
check "load-bitstream tolerates missing switch.conf"

echo "== web888-mode =="

# 10. switch to app: stop websdr THEN start rpapp instance (ordered)
: > "$MOCK_LOG"
wm_env bash "$PKG/web888-mode" sdr_receiver >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(sed -n '1p;2p' "$MOCK_LOG")" = "systemctl stop web888-websdr.service
systemctl start web888-rpapp@sdr_receiver.service" ]; then cond=0; else cond=1; fi
check "web888-mode <app>: stop websdr, then start rpapp@<app> (ordered)"

# 11. switch to websdr: glob-stop rpapps THEN start websdr (ordered)
: > "$MOCK_LOG"
wm_env bash "$PKG/web888-mode" websdr >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(sed -n '1p;2p' "$MOCK_LOG")" = "systemctl stop web888-rpapp@*
systemctl start web888-websdr.service" ]; then cond=0; else cond=1; fi
check "web888-mode websdr: glob-stop rpapps, then start websdr (ordered)"

# 12. stop: stops both sides
: > "$MOCK_LOG"
wm_env bash "$PKG/web888-mode" stop >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(sed -n '1p;2p' "$MOCK_LOG")" = "systemctl stop web888-websdr.service
systemctl stop web888-rpapp@*" ]; then cond=0; else cond=1; fi
check "web888-mode stop: stops websdr and rpapp glob"

# 13. list
out=$(wm_env bash "$PKG/web888-mode" list 2>&1)
if printf '%s' "$out" | grep -q 'sdr_receiver_hpsdr' && printf '%s' "$out" | grep -q 'led_blinker' \
    && printf '%s' "$out" | grep -q 'websdr'; then cond=0; else cond=1; fi
check "web888-mode list shows apps + special modes"

# 14a. status: websdr active
echo active > "$SANDBOX/state/websdr"
out=$(wm_env bash "$PKG/web888-mode" 2>&1)
if printf '%s' "$out" | grep -q 'current mode: websdr'; then cond=0; else cond=1; fi
check "status reports websdr when websdr active"
# 14b. status: rpapp active
echo inactive > "$SANDBOX/state/websdr"; echo active > "$SANDBOX/state/sdr_receiver_hpsdr"
out=$(wm_env bash "$PKG/web888-mode" 2>&1)
if printf '%s' "$out" | grep -q 'current mode: sdr_receiver_hpsdr'; then cond=0; else cond=1; fi
check "status reports rp app when rpapp instance active"
# 14c. status: none
echo inactive > "$SANDBOX/state/sdr_receiver_hpsdr"
out=$(wm_env bash "$PKG/web888-mode" 2>&1)
if printf '%s' "$out" | grep -q 'current mode: none'; then cond=0; else cond=1; fi
check "status reports none when everything stopped"

# 15. non-root refusal for switching; list still allowed
mv "$SANDBOX/bin/id" "$SANDBOX/bin/id-root"
cp "$SANDBOX/bin/id-nonroot" "$SANDBOX/bin/id"; chmod +x "$SANDBOX/bin/id"
out=$(wm_env bash "$PKG/web888-mode" websdr 2>&1); rc=$?
if [ $rc = 1 ] && printf '%s' "$out" | grep -q 'requires root'; then cond=0; else cond=1; fi
check "web888-mode refuses switching as non-root"
if wm_env bash "$PKG/web888-mode" list >/dev/null 2>&1; then cond=0; else cond=1; fi
check "web888-mode list works unprivileged"
mv "$SANDBOX/bin/id-root" "$SANDBOX/bin/id"

# 16. unknown app/command -> usage + exit 2
out=$(wm_env bash "$PKG/web888-mode" frobnicate 2>&1); rc=$?
if [ $rc = 2 ] && printf '%s' "$out" | grep -qi 'usage'; then cond=0; else cond=1; fi
check "web888-mode unknown arg -> usage + exit 2"

echo "== rpapp-hold =="
# 17. rpapp-hold prints hold message then would sleep (run with timeout)
out=$(timeout 2 bash "$PKG/rpapp-hold" 2>&1); rc=$?
if [ $rc = 124 ] && printf '%s' "$out" | grep -q 'holding unit open'; then cond=0; else cond=1; fi
check "rpapp-hold prints message and holds (timeout 124 expected)"

echo
echo "== summary: $pass passed, $fail failed =="
[ "$fail" = 0 ]
