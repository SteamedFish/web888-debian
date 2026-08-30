#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Host-side unit tests for the web888-duc and web888-frpc root helpers
# (packaging/web888-websdr/debian/root-helpers/). Everything is mocked via
# PATH (curl/systemctl/frpc) and the helpers' WEB888_* overrides + DIRECT=1,
# so no network, no root, no systemd is touched. Run from the repo root:
#   scripts/test-duc-frpc-helpers.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT_HELPERS=packaging/web888-websdr/debian/root-helpers
DUC=$ROOT_HELPERS/web888-duc
FRPC=$ROOT_HELPERS/web888-frpc

fails=0
tmp=$(mktemp -d /tmp/web888-duc-frpc-test.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
MOCKBIN=$tmp/mockbin
mkdir -p "$MOCKBIN" "$tmp/duc-etc-default" "$tmp/frpc-etc" "$tmp/config"

pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# expect_exit <want-code> <name> <cmd...> — asserts the exit code, keeps stderr
expect_exit() { # <want> <name> <cmd...>
    local want=$1 name=$2
    shift 2
    local got=0
    "$@" 2>"$tmp/stderr" || got=$?
    if [[ $got -eq $want ]]; then
        pass "$name (exit $got)"
    else
        fail "$name: want exit $want, got $got; stderr: $(cat "$tmp/stderr")"
    fi
}

# ---- mocks -------------------------------------------------------------

cat >"$MOCKBIN/curl" <<'EOF'
#!/bin/sh
if [ -n "${MOCK_CURL_EXIT:-}" ]; then echo "curl: (7) mocked connection failure" >&2; exit "$MOCK_CURL_EXIT"; fi
printf '%s\n' "$MOCK_BODY"
printf '%s\n' "$MOCK_CODE"
EOF
cat >"$MOCKBIN/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_SYSCTL_LOG:?}"
EOF
cat >"$MOCKBIN/frpc" <<'EOF'
#!/bin/sh
[ "${MOCK_FRPC_VERIFY_FAIL:-}" = 1 ] && exit 1
if [ "${1:-}" = verify ] && grep -q '^garbage$' "${3:?}" 2>/dev/null; then
    echo "mock frpc: verify rejected" >&2
    exit 1
fi
exit 0
EOF
chmod +x "$MOCKBIN"/*

# Common test environments: override every path into the scratch dir and
# skip the systemd-run escape (mocked systemctl is reached directly).
duc_env() {
    env -i PATH="$MOCKBIN:/usr/bin:/bin" \
        WEB888_DUC_STATE="$tmp/duc-state" \
        WEB888_DUC_SELF="$DUC" \
        WEB888_DUC_ENVFILE="$tmp/duc-etc-default/noip-duc" \
        WEB888_DUC_DIRECT=1 \
        MOCK_SYSCTL_LOG="$tmp/duc-sysctl.log" \
        MOCK_BODY="${MOCK_BODY:-}" MOCK_CODE="${MOCK_CODE:-}" MOCK_CURL_EXIT="${MOCK_CURL_EXIT:-}" \
        "$@"
}
frpc_env() {
    env -i PATH="$MOCKBIN:/usr/bin:/bin" \
        WEB888_FRPC_STATE="$tmp/frpc-state" \
        WEB888_FRPC_SELF="$FRPC" \
        WEB888_FRPC_CONFIG="$tmp/config/frpc.toml" \
        WEB888_FRPC_INSTALLED="$tmp/frpc-etc/frpc.toml" \
        WEB888_FRPC_DIRECT=1 \
        MOCK_SYSCTL_LOG="$tmp/frpc-sysctl.log" \
        MOCK_FRPC_VERIFY_FAIL="${MOCK_FRPC_VERIFY_FAIL:-}" \
        "$@"
}

sh -n "$DUC" || fail "web888-duc: sh -n"
sh -n "$FRPC" || fail "web888-frpc: sh -n"

# ---- web888-duc: argument validation (exit codes = the UI status map) ----

expect_exit 1 "duc: usage (no args) -> 1" duc_env "$DUC"
expect_exit 102 "duc: missing host -> 102" duc_env "$DUC" -u user -p pass -U 5
expect_exit 100 "duc: empty user -> 100" duc_env "$DUC" -u '' -p pass -U 5 -H host.ddns.net
expect_exit 100 "duc: empty pass -> 100" duc_env "$DUC" -u user -p '' -U 5 -H host.ddns.net
expect_exit 102 "duc: empty host -> 102" duc_env "$DUC" -u user -p pass -U 5 -H ''
expect_exit 1 "duc: control char in password -> 1" duc_env "$DUC" -u user -p "$(printf 'pw\ttab')" -U 5 -H host.ddns.net
expect_exit 102 "duc: bad host charset -> 102" duc_env "$DUC" -u user -p pass -U 5 -H 'ho_st.ddns.net'
expect_exit 1 "duc: non-integer interval -> 1" duc_env "$DUC" -u user -p pass -U 5m -H host.ddns.net
expect_exit 1 "duc: interval out of range -> 1" duc_env "$DUC" -u user -p pass -U 2000 -H host.ddns.net

# ---- web888-duc: probe mapping ------------------------------------------

MOCK_BODY='good 203.0.113.7' MOCK_CODE=200 \
    expect_exit 0 "duc: probe good -> 0" duc_env "$DUC" -u user -p pass -U 5 -H Host.ddns.net
MOCK_BODY='nochg 203.0.113.7' MOCK_CODE=200 \
    expect_exit 0 "duc: probe nochg -> 0" duc_env "$DUC" -u user -p pass -U 5 -H host.ddns.net
MOCK_BODY='badauth' MOCK_CODE=401 \
    expect_exit 100 "duc: probe badauth -> 100" duc_env "$DUC" -u user -p pass -U 5 -H host.ddns.net
MOCK_BODY='nohost' MOCK_CODE=200 \
    expect_exit 103 "duc: probe nohost -> 103" duc_env "$DUC" -u user -p pass -U 5 -H host.ddns.net
MOCK_BODY='911' MOCK_CODE=200 \
    expect_exit 1 "duc: probe 911 -> 1" duc_env "$DUC" -u user -p pass -U 5 -H host.ddns.net
MOCK_BODY='!donator' MOCK_CODE=200 \
    expect_exit 1 "duc: probe !donator -> 1" duc_env "$DUC" -u user -p pass -U 5 -H host.ddns.net
MOCK_BODY='<!DOCTYPE html>' MOCK_CODE=502 \
    expect_exit 1 "duc: probe HTML error page -> 1" duc_env "$DUC" -u user -p pass -U 5 -H host.ddns.net
MOCK_CURL_EXIT=7 MOCK_BODY= MOCK_CODE= \
    expect_exit 1 "duc: curl connection failure -> 1" duc_env "$DUC" -u user -p pass -U 5 -H host.ddns.net

# A failed probe must not (re)install an env file or touch systemctl: from a
# clean slate, only the failing badauth probe runs in between.
rm -rf "$tmp/duc-etc-default/noip-duc" "$tmp/duc-state" "$tmp/duc-sysctl.log"
MOCK_BODY='badauth' MOCK_CODE=401 \
    expect_exit 100 "duc: failed probe from clean slate" duc_env "$DUC" -u user -p pass -U 5 -H host.ddns.net
if [[ ! -e $tmp/duc-etc-default/noip-duc && ! -s $tmp/duc-sysctl.log ]]; then
    pass "duc: failed probes install nothing, touch no unit"
else
    fail "duc: failed probe left env file or systemctl calls behind"
fi

# ---- web888-duc: happy path ---------------------------------------------

MOCK_SYSCTL_LOG=$tmp/duc-sysctl.log
MOCK_BODY='good 203.0.113.7' MOCK_CODE=200 \
    expect_exit 0 "duc: configure ok" duc_env "$DUC" -u 'us er' -p "pw s's\\d\"" -U 5 -H Host.ddns.net
if [[ -s $tmp/duc-sysctl.log ]]; then
    fail "duc: configure must not touch systemctl (that is start's job)"
else
    pass "duc: configure does not touch systemctl"
fi
staged=$tmp/duc-state/noip-duc.env
[[ $(stat -c %a "$staged") = 600 ]] && pass "duc: staged env file is 0600" || fail "duc: staged env file mode $(stat -c %a "$staged")"
installed=$tmp/duc-etc-default/noip-duc
[[ $(stat -c %a "$installed") = 600 ]] && pass "duc: installed env file is 0600" || fail "duc: installed env file mode $(stat -c %a "$installed")"
grep -q 'NOIP_CHECK_INTERVAL=5m' "$installed" && pass "duc: interval rendered" || fail "duc: interval missing"
# Host lowercased, single-quoted values survive sh parsing intact.
got_user=$(. "$installed"; printf '%s' "$NOIP_USERNAME")
got_pass=$(. "$installed"; printf '%s' "$NOIP_PASSWORD")
got_host=$(. "$installed"; printf '%s' "$NOIP_HOSTNAMES")
[[ $got_user = 'us er' ]] && pass "duc: username quoting round-trip" || fail "duc: username got '$got_user'"
[[ $got_pass = "pw s's\\d\"" ]] && pass "duc: password quoting round-trip" || fail "duc: password got '$got_pass'"
[[ $got_host = host.ddns.net ]] && pass "duc: host lowercased" || fail "duc: host got '$got_host'"

# Interval clamp to noip-duc's 2-minute minimum.
MOCK_BODY='good 203.0.113.7' MOCK_CODE=200 \
    expect_exit 0 "duc: configure -U 1 ok" duc_env "$DUC" -u user -p pass -U 1 -H host.ddns.net
grep -q 'NOIP_CHECK_INTERVAL=2m' "$installed" && pass "duc: interval clamped to 2m" || fail "duc: clamp failed ($(grep NOIP_CHECK_INTERVAL "$installed"))"

# start verb: requires the env file, then enables+restarts via systemctl.
rm -f "$tmp/duc-sysctl.log"
mv "$installed" "$tmp/duc-etc-default/noip-duc.bak"
expect_exit 1 "duc: start without env file -> 1" duc_env "$DUC" start
mv "$tmp/duc-etc-default/noip-duc.bak" "$installed"
expect_exit 0 "duc: start ok" duc_env "$DUC" start
grep -q 'enable noip-duc.service' "$tmp/duc-sysctl.log" && grep -q 'restart noip-duc.service' "$tmp/duc-sysctl.log" &&
    pass "duc: start enables+restarts noip-duc.service" || fail "duc: start systemctl calls: $(cat "$tmp/duc-sysctl.log")"

# Phase-2 re-validation: corrupt the staged file, apply must refuse.
printf 'EVIL=1\n' >>"$staged"
expect_exit 1 "duc: --apply configure rejects corrupted staged file" duc_env "$DUC" --apply configure

# ---- web888-frpc ---------------------------------------------------------

expect_exit 1 "frpc: missing config -> 1" frpc_env "$FRPC" restart
printf 'serverAddr = "x"\n' >"$tmp/config/frpc.toml"
expect_exit 1 "frpc: config without proxies -> 1" frpc_env "$FRPC" restart
cat >"$tmp/config/frpc.toml" <<'EOF'
serverAddr = "proxy.rx-888.com"
serverPort = 7000

user="myhost"
metadatas.token="TOKEN"

[[proxies]]
name = "myhost"
type = "http"
localIP = "127.0.0.1"
localPort = 8073
subdomain = "myhost"
EOF
MOCK_FRPC_VERIFY_FAIL=1 expect_exit 1 "frpc: frpc verify failure -> 1" frpc_env "$FRPC" restart

MOCK_SYSCTL_LOG=$tmp/frpc-sysctl.log
expect_exit 0 "frpc: restart ok (default verb)" frpc_env "$FRPC"
installed=$tmp/frpc-etc/frpc.toml
[[ $(stat -c %a "$installed") = 600 ]] && pass "frpc: installed config is 0600" || fail "frpc: installed config mode $(stat -c %a "$installed")"
cmp -s "$tmp/config/frpc.toml" "$installed" && pass "frpc: installed config content matches" || fail "frpc: installed config content differs"
grep -q 'enable frpc.service' "$tmp/frpc-sysctl.log" && grep -q 'restart frpc.service' "$tmp/frpc-sysctl.log" &&
    pass "frpc: enables+restarts frpc.service" || fail "frpc: systemctl calls: $(cat "$tmp/frpc-sysctl.log")"

# Phase-2 re-validation: corrupt the staged file, apply must refuse.
printf 'garbage\n' >>"$tmp/frpc-state/frpc.toml"
expect_exit 1 "frpc: --apply rejects corrupted staged file" frpc_env "$FRPC" --apply

# ---- summary -------------------------------------------------------------

echo
if [[ $fails -eq 0 ]]; then
    echo "all duc/frpc helper tests passed"
else
    echo "$fails test(s) FAILED" >&2
    exit 1
fi
