#!/usr/bin/env bash
# test-redpitaya-mode.sh — host test harness for packaging/web888-redpitaya/
# {load-bitstream, web888-fpga-select, web888-mode, rpapp-hold} with fully
# mocked externals (systemctl, /dev/xdevcfg, prog_done sysfs, si5351-init,
# id, lock dir). No root, no hardware, no systemd required. Scratch lives in
# .tmp/ per repo rule. Exit 0 iff every case passes.

set -uo pipefail
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
mkdir -p "$SANDBOX"/{bin,apps/sdr_receiver,apps/led_blinker,apps/sdr_receiver_hpsdr,state,etc,fpga,ngfw,factory,lock}
for app in sdr_receiver led_blinker sdr_receiver_hpsdr; do
    echo "DUMMY-BITSTREAM-$app" > "$SANDBOX/apps/$app/$app.bit"
done
echo "DUMMY-OPEN-HF"    > "$SANDBOX/ngfw/websdr_hf.bit"
echo "DUMMY-FACTORY-HF" > "$SANDBOX/factory/websdr_hf.bit"
OPEN_SHA=$(sha256sum "$SANDBOX/ngfw/websdr_hf.bit" | awk '{print $1}')
: > "$SANDBOX/xdevcfg"          # fake device node (regular file: cat > works)
echo 1 > "$SANDBOX/prog_done"   # default: PL configures fine
: > "$SANDBOX/systemctl.log"
: > "$SANDBOX/order.log"
echo inactive > "$SANDBOX/state/websdr"    # is-active script states
echo inactive > "$SANDBOX/state/web888d"

export MOCK_LOG="$PWD/$SANDBOX/systemctl.log"
export MOCK_STATE_DIR="$PWD/$SANDBOX/state"
export MOCK_ORDER="$PWD/$SANDBOX/order.log"

cat > "$SANDBOX/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" != is-active ]; then
    echo "systemctl $*" >> "$MOCK_LOG"
fi
if [ "$1" = is-active ]; then
    unit=${2%.service}; unit=${unit#web888-rpapp@}
    case $2 in
        web888-websdr.service) key=websdr ;;
        web888-web888d.service) key=web888d ;;
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

# Tracing wrapper around the real helper: records mutating helper verbs
# (select/load) in MOCK_LOG so tests can assert helper-vs-systemctl ordering
# (validation BEFORE any stop, select before start). Read-only `status` is
# not logged, so no-op/negative tests keep their "nothing happened" asserts.
cat > "$SANDBOX/bin/fpga-select-trace" <<EOF
#!/usr/bin/env bash
case \${1:-} in
    select|load) echo "fpga-select \$*" >> "\$MOCK_LOG" ;;
esac
exec "$PWD/$PKG/web888-fpga-select" "\$@"
EOF
chmod +x "$SANDBOX/bin/fpga-select-trace"

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

# ---------- env shared by all web888-fpga-select runs ----------
# Defaults mirror the runtime paths; ACK_UID/SNAP_UID accept the invoking
# (non-root) user so ownership checks can be exercised without root.
fpga_env() {
    env \
        WEB888_FPGA_STATE_DIR="$PWD/$SANDBOX/fpga" \
        WEB888_FPGA_ACK="$PWD/$SANDBOX/etc/fpga-experimental" \
        WEB888_FPGA_ACK_UID="${FS_ACK_UID:-$(id -u)}" \
        WEB888_FPGA_SNAP_UID="${FS_SNAP_UID:-$(id -u)}" \
        WEB888_FPGA_OPEN_SRC="$PWD/$SANDBOX/ngfw/websdr_hf.bit" \
        WEB888_FPGA_STOCK_SRC="$PWD/$SANDBOX/factory/websdr_hf.bit" \
        WEB888_FPGA_XDEVCFG="$PWD/$SANDBOX/xdevcfg" \
        WEB888_FPGA_PROG_DONE="$PWD/$SANDBOX/prog_done" \
        WEB888_FPGA_LOCK="$PWD/$SANDBOX/lock/fpga.lock" \
        WEB888_FPGA_SYSTEMCTL="$PWD/$SANDBOX/bin/systemctl" \
        WEB888_FPGA_TIMEOUT="${FS_TIMEOUT:-5}" \
        WEB888_FPGA_INTERVAL="${FS_INTERVAL:-0.1}" \
        WEB888_RP_APPS_DIR="$PWD/$SANDBOX/apps" \
        "$@"
}
fs_env() { # helper invoked directly: needs the mocked id/systemctl in PATH
    fpga_env PATH="$PWD/$SANDBOX/bin:$PATH" "$@"
}

# ---------- env shared by all web888-mode runs ----------
wm_env() {
    fpga_env \
        WEB888_SYSTEMCTL="${WM_SYSTEMCTL:-$PWD/$SANDBOX/bin/systemctl}" \
        WEB888_FPGA_SELECT="$PWD/$SANDBOX/bin/fpga-select-trace" \
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

echo "== web888-fpga-select =="
FPGA_SEL="$PKG/web888-fpga-select"
SNAP=.tmp/test-redpitaya-mode/fpga/websdr_hf.bit
ACK=.tmp/test-redpitaya-mode/etc/fpga-experimental

# 21. status with nothing persisted: selected profile is stock, reported
# separately from the active service (and never from prog_done)
out=$(fs_env bash "$FPGA_SEL" status 2>&1); rc=$?
if [ $rc = 0 ] && printf '%s' "$out" | grep -q 'selected fpga: stock' \
    && printf '%s' "$out" | grep -q 'active service: none'; then cond=0; else cond=1; fi
check "fpga-select status: default selection is stock, service none"

# 22. experimental select without consent file -> clear refusal
rm -f "$ACK"
rc=0; fs_env bash "$FPGA_SEL" select web888-ng-hf --experimental >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ] && [ ! -e "$SNAP" ]; then cond=0; else cond=1; fi
check "fpga-select: select web888-ng-hf refuses without consent file"

# 23. consent file with the WRONG digest -> refused, no snapshot
echo "web888-ng-hf 0000000000000000000000000000000000000000000000000000000000000000" > "$ACK"
rc=0; fs_env bash "$FPGA_SEL" select web888-ng-hf --experimental >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ] && [ ! -e "$SNAP" ]; then cond=0; else cond=1; fi
check "fpga-select: wrong digest in consent file is refused"

# 24. consent file not owned by the required uid -> refused
echo "web888-ng-hf $OPEN_SHA" > "$ACK"
rc=0; FS_ACK_UID=0 fs_env bash "$FPGA_SEL" select web888-ng-hf --experimental >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ] && [ ! -e "$SNAP" ]; then cond=0; else cond=1; fi
check "fpga-select: consent file with wrong owner is refused"

# 25. --experimental flag itself is mandatory
rc=0; fs_env bash "$FPGA_SEL" select web888-ng-hf >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ] && [ ! -e "$SNAP" ]; then cond=0; else cond=1; fi
check "fpga-select: --experimental flag is required"

# 25b. --check validates consent/digest but persists NOTHING and snapshots
# NOTHING (used to pre-validate before disrupting a running stack)
echo "web888-ng-hf $OPEN_SHA" > "$ACK"
rc=0; fs_env bash "$FPGA_SEL" select web888-ng-hf --experimental --check >/dev/null 2>&1 || rc=$?
st=$(fs_env bash "$FPGA_SEL" status 2>&1)
if [ $rc = 0 ] && [ ! -e "$SNAP" ] && grep -q 'selected fpga: stock' <<< "$st"; then cond=0; else cond=1; fi
check "fpga-select: --check with valid consent changes no state"

echo "web888-ng-hf 0000000000000000000000000000000000000000000000000000000000000000" > "$ACK"
rc=0; fs_env bash "$FPGA_SEL" select web888-ng-hf --experimental --check >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ] && [ ! -e "$SNAP" ]; then cond=0; else cond=1; fi
check "fpga-select: --check with bad digest is refused, state untouched"

# 25c. --check requires --experimental too
rc=0; fs_env bash "$FPGA_SEL" select web888-ng-hf --check >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ]; then cond=0; else cond=1; fi
check "fpga-select: --check still requires --experimental"
echo "web888-ng-hf $OPEN_SHA" > "$ACK"

# 26. happy path: digest verified, snapshot persisted IMMUTABLY (regular
# file, not a symlink, mode 0444, exact content), selection persisted
out=$(fs_env bash "$FPGA_SEL" select web888-ng-hf --experimental 2>&1); rc=$?
st=$(fs_env bash "$FPGA_SEL" status 2>&1)
snap_mode=$(stat -c %a "$SNAP" 2>/dev/null || echo -)
if [ $rc = 0 ] && [ -f "$SNAP" ] && [ ! -L "$SNAP" ] \
    && cmp -s "$SNAP" "$SANDBOX/ngfw/websdr_hf.bit" \
    && [ "$snap_mode" = 444 ] \
    && printf '%s' "$out" | grep -q 'PL untouched' \
    && grep -q 'selected fpga: web888-ng-hf' <<< "$st"; then cond=0; else cond=1; fi
check "fpga-select: consent + --experimental stages immutable snapshot, persists selection"

# 27. FUTURE package digest: bitstream changed after consent -> refused,
# existing snapshot left untouched
echo "DUMMY-OPEN-HF-v2" > "$SANDBOX/ngfw/websdr_hf.bit"
rc=0; fs_env bash "$FPGA_SEL" select web888-ng-hf --experimental >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ] && [ "$(cat "$SNAP")" = "DUMMY-OPEN-HF" ]; then cond=0; else cond=1; fi
check "fpga-select: updated package digest rejected until re-consent (snapshot kept)"
echo "DUMMY-OPEN-HF" > "$SANDBOX/ngfw/websdr_hf.bit"   # restore consented artifact

# 28. select stock: persists stock and REMOVES the open snapshot, PL untouched
out=$(fs_env bash "$FPGA_SEL" select stock 2>&1); rc=$?
st=$(fs_env bash "$FPGA_SEL" status 2>&1)
if [ $rc = 0 ] && [ ! -e "$SNAP" ] \
    && grep -q 'selected fpga: stock' <<< "$st" \
    && printf '%s' "$out" | grep -q 'PL untouched'; then cond=0; else cond=1; fi
check "fpga-select: select stock removes snapshot and persists stock"

# 29. load: default (stock) selection loads the factory HF bitstream
: > "$SANDBOX/xdevcfg"
out=$(fs_env bash "$FPGA_SEL" load 2>&1); rc=$?
if [ $rc = 0 ] && [ "$(cat "$SANDBOX/xdevcfg")" = "DUMMY-FACTORY-HF" ] \
    && printf '%s' "$out" | grep -q 'prog_done=1'; then cond=0; else cond=1; fi
check "fpga-select load: stock selection loads factory HF to xdevcfg"

# 30. load: refuses while a conflicting SDR service (websdr) is active
: > "$SANDBOX/xdevcfg"
echo active > "$SANDBOX/state/websdr"
rc=0; fs_env bash "$FPGA_SEL" load >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ] && [ ! -s "$SANDBOX/xdevcfg" ]; then cond=0; else cond=1; fi
check "fpga-select load: refuses when websdr service is active (fail closed)"
echo inactive > "$SANDBOX/state/websdr"

# 31. load: prog_done timeout fails closed
echo 0 > "$SANDBOX/prog_done"
rc=0; FS_TIMEOUT=0.3 FS_INTERVAL=0.05 fs_env bash "$FPGA_SEL" load >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ]; then cond=0; else cond=1; fi
check "fpga-select load: prog_done timeout fails closed"
echo 1 > "$SANDBOX/prog_done"

# 32. load: persisted web888-ng-hf selection loads the root-owned snapshot
echo "web888-ng-hf $OPEN_SHA" > "$ACK"
fs_env bash "$FPGA_SEL" select web888-ng-hf --experimental >/dev/null 2>&1
: > "$SANDBOX/xdevcfg"
rc=0; fs_env bash "$FPGA_SEL" load >/dev/null 2>&1 || rc=$?
if [ $rc = 0 ] && [ "$(cat "$SANDBOX/xdevcfg")" = "DUMMY-OPEN-HF" ]; then cond=0; else cond=1; fi
check "fpga-select load: open selection loads the staged snapshot"

# 33. load: selection web888-ng-hf but snapshot missing -> fail closed
rm -f "$SNAP"
printf 'web888-ng-hf\n' > "$SANDBOX/fpga/selection"
: > "$SANDBOX/xdevcfg"
rc=0; fs_env bash "$FPGA_SEL" load >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ] && [ ! -s "$SANDBOX/xdevcfg" ]; then cond=0; else cond=1; fi
check "fpga-select load: missing snapshot fails closed"

# reset fpga state for the mode section: stock, no snapshot
fs_env bash "$FPGA_SEL" select stock >/dev/null 2>&1

echo "== web888-mode =="

# 10. switch to app: stop websdr + web888d + rpapp glob THEN start rpapp (ordered)
: > "$MOCK_LOG"
wm_env bash "$PKG/web888-mode" sdr_receiver >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(sed -n '1p;2p;3p;4p' "$MOCK_LOG")" = "systemctl stop web888-websdr.service
systemctl stop web888-web888d.service
systemctl stop web888-rpapp@*
systemctl start web888-rpapp@sdr_receiver.service" ]; then cond=0; else cond=1; fi
check "web888-mode <app>: stop all other stacks, then start rpapp@<app> (ordered)"

# 11. switch to websdr: stop everything THEN start websdr (ordered)
: > "$MOCK_LOG"
wm_env bash "$PKG/web888-mode" websdr >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(sed -n '1p;2p;3p;4p' "$MOCK_LOG")" = "systemctl stop web888-websdr.service
systemctl stop web888-web888d.service
systemctl stop web888-rpapp@*
systemctl start web888-websdr.service" ]; then cond=0; else cond=1; fi
check "web888-mode websdr: stop all stacks, then start websdr (ordered)"

# 12. stop: stops all three stacks
: > "$MOCK_LOG"
wm_env bash "$PKG/web888-mode" stop >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(sed -n '1p;2p;3p' "$MOCK_LOG")" = "systemctl stop web888-websdr.service
systemctl stop web888-web888d.service
systemctl stop web888-rpapp@*" ]; then cond=0; else cond=1; fi
check "web888-mode stop: stops websdr, web888d and rpapp glob"

# 13. list
out=$(wm_env bash "$PKG/web888-mode" list 2>&1)
if printf '%s' "$out" | grep -q 'sdr_receiver_hpsdr' && printf '%s' "$out" | grep -q 'led_blinker' \
    && printf '%s' "$out" | grep -q 'websdr' && printf '%s' "$out" | grep -q 'web888d'; then cond=0; else cond=1; fi
check "web888-mode list shows apps + special modes"

# 14a. status: websdr active
echo active > "$SANDBOX/state/websdr"
out=$(wm_env bash "$PKG/web888-mode" 2>&1)
if printf '%s' "$out" | grep -q 'current mode: websdr' \
    && printf '%s' "$out" | grep -q 'selected fpga: stock'; then cond=0; else cond=1; fi
check "status reports websdr when websdr active (with selected fpga)"
# 14b. status: rpapp active
echo inactive > "$SANDBOX/state/websdr"; echo active > "$SANDBOX/state/sdr_receiver_hpsdr"
out=$(wm_env bash "$PKG/web888-mode" 2>&1)
if printf '%s' "$out" | grep -q 'current mode: sdr_receiver_hpsdr'; then cond=0; else cond=1; fi
check "status reports rp app when rpapp instance active"
# 14c. status: web888d active
echo inactive > "$SANDBOX/state/sdr_receiver_hpsdr"; echo active > "$SANDBOX/state/web888d"
out=$(wm_env bash "$PKG/web888-mode" 2>&1)
if printf '%s' "$out" | grep -q 'current mode: web888d'; then cond=0; else cond=1; fi
check "status reports web888d when web888d active"
# 14d. status: none
echo inactive > "$SANDBOX/state/web888d"
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

# 34. switch to web888d: stop all stacks THEN start web888d (ordered)
: > "$MOCK_LOG"
wm_env bash "$PKG/web888-mode" web888d >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(sed -n '1p;2p;3p;4p' "$MOCK_LOG")" = "systemctl stop web888-websdr.service
systemctl stop web888-web888d.service
systemctl stop web888-rpapp@*
systemctl start web888-web888d.service" ]; then cond=0; else cond=1; fi
check "web888-mode web888d: stop all stacks, then start web888d (ordered)"

# 35. no change when same mode+FPGA already active: no systemctl calls at all
echo active > "$SANDBOX/state/websdr"
: > "$MOCK_LOG"
out=$(wm_env bash "$PKG/web888-mode" websdr 2>&1); rc=$?
if [ $rc = 0 ] && [ ! -s "$MOCK_LOG" ] && printf '%s' "$out" | grep -q 'no change'; then cond=0; else cond=1; fi
check "web888-mode: same mode+fpga already active is a no-op (no systemctl calls)"
echo inactive > "$SANDBOX/state/websdr"

# 36. same-mode FPGA change: consent/digest PREVALIDATED (select --check)
# before any stack is stopped, then stop-all, then the real select, then
# start — even though websdr stays the target
echo active > "$SANDBOX/state/websdr"
echo "web888-ng-hf $OPEN_SHA" > "$ACK"
: > "$MOCK_LOG"
out=$(wm_env bash "$PKG/web888-mode" websdr --fpga web888-ng-hf --experimental 2>&1); rc=$?
cond=1
if [ $rc = 0 ] && [ "$(cat "$MOCK_LOG")" = "fpga-select select web888-ng-hf --experimental --check
systemctl stop web888-websdr.service
systemctl stop web888-web888d.service
systemctl stop web888-rpapp@*
fpga-select select web888-ng-hf --experimental
systemctl start web888-websdr.service" ] \
    && [ -f "$SNAP" ] && [ ! -L "$SNAP" ]; then
    cond=0
    st=$(fs_env bash "$FPGA_SEL" status 2>&1)
    grep -q 'selected fpga: web888-ng-hf' <<< "$st" || cond=1
fi
check "web888-mode: same-mode FPGA change prevalidates, stops all, selects, restarts"

# 37. --fpga web888-ng-hf without --experimental -> refused, nothing stopped
: > "$MOCK_LOG"
rc=0; wm_env bash "$PKG/web888-mode" websdr --fpga web888-ng-hf >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ] && [ ! -s "$MOCK_LOG" ]; then cond=0; else cond=1; fi
check "web888-mode: --fpga web888-ng-hf without --experimental refused before any stop"

# 38. --fpga rejected for RP apps
: > "$MOCK_LOG"
rc=0; wm_env bash "$PKG/web888-mode" sdr_receiver --fpga stock >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ] && [ ! -s "$MOCK_LOG" ]; then cond=0; else cond=1; fi
check "web888-mode: --fpga rejected for RP apps"

# 39. bad --fpga value -> usage + exit 2
out=$(wm_env bash "$PKG/web888-mode" websdr --fpga bogus 2>&1); rc=$?
if [ $rc = 2 ] && printf '%s' "$out" | grep -qi 'usage'; then cond=0; else cond=1; fi
check "web888-mode: bad --fpga value -> usage + exit 2"

# reset selection to stock for the remaining sections
fs_env bash "$FPGA_SEL" select stock >/dev/null 2>&1

# 39b. regression: an INVALID ACK/digest must fail BEFORE any disruption —
# the previously running stack stays active, NO STOP is issued (the helper
# --check attempt may be logged), and neither selection nor snapshot changes
echo active > "$SANDBOX/state/websdr"
echo "web888-ng-hf 0000000000000000000000000000000000000000000000000000000000000000" > "$ACK"
: > "$MOCK_LOG"
rc=0; wm_env bash "$PKG/web888-mode" websdr --fpga web888-ng-hf --experimental >/dev/null 2>&1 || rc=$?
st=$(fs_env bash "$FPGA_SEL" status 2>&1)
if [ $rc != 0 ] && ! grep -q '^systemctl stop' "$MOCK_LOG" \
    && [ "$(cat "$SANDBOX/state/websdr")" = active ] \
    && [ ! -e "$SNAP" ] \
    && grep -q 'selected fpga: stock' <<< "$st"; then cond=0; else cond=1; fi
check "web888-mode: invalid ACK/digest leaves the running stack untouched (no stop)"
# 39c. same regression for a MISSING consent file
rm -f "$ACK"
: > "$MOCK_LOG"
rc=0; wm_env bash "$PKG/web888-mode" websdr --fpga web888-ng-hf --experimental >/dev/null 2>&1 || rc=$?
if [ $rc != 0 ] && ! grep -q '^systemctl stop' "$MOCK_LOG" \
    && [ "$(cat "$SANDBOX/state/websdr")" = active ] \
    && [ ! -e "$SNAP" ]; then cond=0; else cond=1; fi
check "web888-mode: missing consent file leaves the running stack untouched (no stop)"
echo inactive > "$SANDBOX/state/websdr"

echo "== web888-mode fpga + websdr lookup =="

# 40. websdr -> web888d -> RP -> websdr transition chain, checking status
# after each hop (every stack's status + stop honored)
wm_env bash "$PKG/web888-mode" web888d >/dev/null 2>&1; rc1=$?
echo active > "$SANDBOX/state/web888d"; echo inactive > "$SANDBOX/state/websdr"
out1=$(wm_env bash "$PKG/web888-mode")
: > "$MOCK_LOG"
wm_env bash "$PKG/web888-mode" stop >/dev/null 2>&1; rc2=$?
echo inactive > "$SANDBOX/state/web888d"
wm_env bash "$PKG/web888-mode" sdr_receiver_hpsdr >/dev/null 2>&1; rc3=$?
echo active > "$SANDBOX/state/sdr_receiver_hpsdr"
out3=$(wm_env bash "$PKG/web888-mode")
if [ $rc1 = 0 ] && [ $rc2 = 0 ] && [ $rc3 = 0 ] \
    && printf '%s' "$out1" | grep -q 'current mode: web888d' \
    && grep -q 'systemctl stop web888-rpapp@\*' "$MOCK_LOG" \
    && printf '%s' "$out3" | grep -q 'current mode: sdr_receiver_hpsdr'; then cond=0; else cond=1; fi
check "web888-mode: web888d->stop->RP transition chain with correct status"
echo inactive > "$SANDBOX/state/sdr_receiver_hpsdr"

# 41. open WebSDR firmware lookup (replica of patch 0005 shell logic):
# staged root-owned open HF snapshot preferred; state dir; factory.
LK=.tmp/test-redpitaya-mode/lookup
mkdir -p "$LK/snap" "$LK/state" "$LK/factory"
echo STATEDIR-HF  > "$LK/state/websdr_hf.bit"
echo FACTORY-HF   > "$LK/factory/websdr_hf.bit"
echo STATEDIR-VHF > "$LK/state/websdr_vhf.bit"
echo FACTORY-VHF  > "$LK/factory/websdr_vhf.bit"
echo OPEN-HF      > "$LK/snap/websdr_hf.bit"
# lk <bit> <uid> — replicates the lookup precedence of patch 0005
lk() { LOOKUP_STATE="$LK/state" LOOKUP_FACTORY="$LK/factory" LOOKUP_SNAP="$LK/snap" LOOKUP_UID="$2" bash -c '
    f="$LOOKUP_SNAP/websdr_$0.bit"
    if [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %u "$f")" = "$LOOKUP_UID" ]; then
        echo "$LOOKUP_SNAP"
    elif [ -f "$LOOKUP_STATE/websdr_$0.bit" ]; then
        echo "$LOOKUP_STATE"
    else
        echo "$LOOKUP_FACTORY"
    fi
' "$1"; }
MY_UID=$(id -u)
cond=0
[ "$(lk hf "$MY_UID")" = "$LK/snap" ]   || cond=1   # staged snapshot wins
[ "$(lk hf 0)"          = "$LK/state" ] || cond=1   # wrong uid -> state dir
[ "$(lk vhf "$MY_UID")" = "$LK/state" ] || cond=1   # VHF unaffected by HF snapshot
ln -sf websdr_hf.bit "$LK/snap/websdr_hf.bit"
[ "$(lk hf "$MY_UID")" = "$LK/state" ]  || cond=1   # symlink -> never used
rm -f "$LK/snap/websdr_hf.bit"                      # snapshot removed (= select stock)
[ "$(lk hf "$MY_UID")" = "$LK/state" ]  || cond=1   # falls back to state dir
rm "$LK/state/websdr_hf.bit"
[ "$(lk hf "$MY_UID")" = "$LK/factory" ] || cond=1  # falls back to factory
check "websdr lookup: staged open HF snapshot preferred (uid, symlink, VHF, fallback)"

echo "== rpapp-hold =="
# 17. rpapp-hold prints hold message then would sleep (run with timeout)
out=$(timeout 2 bash "$PKG/rpapp-hold" 2>&1); rc=$?
if [ $rc = 124 ] && printf '%s' "$out" | grep -q 'holding unit open'; then cond=0; else cond=1; fi
check "rpapp-hold prints message and holds (timeout 124 expected)"

echo
echo "== summary: $pass passed, $fail failed =="
[ "$fail" = 0 ]
