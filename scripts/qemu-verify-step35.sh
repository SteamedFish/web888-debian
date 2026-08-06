#!/usr/bin/env bash
# qemu-verify-step35.sh — post-boot verification for the step-3.5 websdr
# Debian-compat fixes, run against a QEMU-booted final image (test-qemu.sh
# final already exposes ssh on 127.0.0.1:12222). NOT a brick test: the
# netconfig round-trip below only installs/removes drop-in FILES — websdr
# applies network changes on reboot, and we never reboot QEMU between
# static and dhcp, so the running network is never disturbed.
set -uo pipefail
cd "$(dirname "$0")/.."

SSH="sshpass -p changeme ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p 12222 root@127.0.0.1"
fail=0
check() { # name, expected-nonempty?, command...
    local name="$1"; shift
    local out rc
    out=$($SSH "$*" 2>&1); rc=$?
    printf '== %s\n%s\n' "$name" "$out"
    if [ $rc -ne 0 ]; then echo "!! $name: ssh rc=$rc"; fail=1; fi
}

check "units active" 'systemctl is-active ssh; systemctl --failed --no-legend | head'
check "packages present" 'dpkg -l iptables miniupnpc netcat-openbsd sudo openssh-server 2>/dev/null | grep "^ii" | awk "{print \$2}"'
check "dropbear gone" 'dpkg -l 2>/dev/null | grep -c dropbear || echo 0'
check "sudoers + helpers perms" 'stat -c "%a %U:%G %n" /etc/sudoers.d/web888 /usr/lib/web888/root-helpers/web888-netconfig /usr/lib/web888/root-helpers/web888-poweroff'
check "sudo -n -l as web888" 'sudo -u web888 sudo -n -l 2>&1 | grep -A3 "may run"'
check "nft kernel backend" 'iptables -L -n 2>&1 | head -6; lsmod | grep -E "nf_tables|nft_compat" || modprobe nft_compat && lsmod | grep -E "nf_tables|nft_compat"'

# websdr itself cannot run under QEMU: the startup probe of the Si5351 clock
# generator (zynq/peri.cpp) finds no i2c slave and SYS_PANICs, so the service
# crash-loops. Checks that need a running websdr are hardware-only; treat them
# as SKIP here instead of FAIL.
websdr_state=$($SSH 'systemctl is-active web888-websdr' 2>/dev/null)
if [ "$websdr_state" = "active" ]; then
    check "KIWI chain (websdr)" 'iptables -L KIWI -n 2>&1 | head -4'
    check "websdr listening" 'ss -tlnp | grep 8073'
else
    panic=$($SSH 'journalctl -u web888-websdr -b --no-pager | grep -c "si5351 is not found"' 2>/dev/null)
    echo "== SKIP: websdr runtime checks (state=$websdr_state, si5351-panics=$panic) — QEMU has no Si5351; KIWI chain + listening are hardware-gate checks"
fi
check "upnpc present" 'command -v upnpc && upnpc 2>&1 | head -2'
check "interfaces main untouched" 'cat /etc/network/interfaces'

echo "== netconfig round-trip (file-level, no reboot) =="
$SSH 'sudo -u web888 mkdir -p /var/lib/web888/netconfig && sudo -u web888 tee /var/lib/web888/netconfig/90-websdr-static.conf >/dev/null <<EOF
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet static
    address 192.0.2.5
    netmask 255.255.255.0
    gateway 192.0.2.1
EOF
sudo -u web888 sudo -n /usr/lib/web888/root-helpers/web888-netconfig static && ls /etc/network/interfaces.d/'
$SSH 'sudo -u web888 tee /var/lib/web888/netconfig/resolv.conf >/dev/null <<EOF
nameserver 192.0.2.53
EOF
sudo -u web888 sudo -n /usr/lib/web888/root-helpers/web888-netconfig dns && cat /etc/resolv.conf'
$SSH 'sudo -u web888 sudo -n /usr/lib/web888/root-helpers/web888-netconfig dhcp && ls /etc/network/interfaces.d/ && cat /etc/network/interfaces.d/eth0'
echo "== netconfig injection rejection =="
$SSH 'sudo -u web888 tee /var/lib/web888/netconfig/90-websdr-static.conf >/dev/null <<EOF
auto eth0
iface eth0 inet static
    address 192.0.2.5
    up rm -rf /
EOF
if sudo -u web888 sudo -n /usr/lib/web888/root-helpers/web888-netconfig static 2>&1; then echo "INJECTION ACCEPTED - FAIL"; else echo "rejected OK"; fi; ls /etc/network/interfaces.d/'
check "websdr journal errors" 'journalctl -u web888-websdr -b --no-pager | grep -iE "lbu|noip2|fw_printenv|chpasswd|cannot|error" | grep -v si5351 | head -8; echo "(end)"'
check "gpsd/chrony unaffected" 'systemctl is-active gpsd chrony'

echo "QEMU-VERIFY-DONE fail=$fail"
exit $fail
