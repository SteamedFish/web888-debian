#!/bin/bash
# Usage: scripts/deploy-websdr-dev.sh <device-ip>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="${1:?usage: scripts/deploy-websdr-dev.sh <device-ip> (discover via the ce:cf:3f:* MAC prefix)}"
SSH="sshpass -p changeme ssh -o StrictHostKeyChecking=no -p22 root@$DEV"
# -O: legacy SCP protocol — simplest protocol, works with any sshd
SCP="sshpass -p changeme scp -O -o StrictHostKeyChecking=no -P22"

DEB="$(ls -t "$REPO_ROOT"/output/websdr/web888-websdr_*_armhf.deb 2>/dev/null | head -1)"
[ -n "$DEB" ] || { echo "ERROR: no deb in output/websdr/ — run scripts/build-websdr-deb.sh first"; exit 1; }
echo "==> deb: $DEB"

echo "==> sanity: target must be the Debian test unit"
echo "    (stock units share the same factory MAC — ARP may flap between units!)"
$SSH "hostname; grep PRETTY /etc/os-release; pgrep -a websdr || echo 'no websdr running (expected)'"

echo "==> copy deb to device"
# stream over ssh instead of scp/sftp (works with any sshd)
cat "$DEB" | $SSH "cat > /tmp/web888-websdr.deb && ls -la /tmp/web888-websdr.deb"

echo "==> dpkg install (always unpacks — apt-get install of a same-version"
echo "    deb is a silent no-op, which once left a stale binary running)"
$SSH "dpkg -i /tmp/web888-websdr.deb 2>&1 | tail -3 || DEBIAN_FRONTEND=noninteractive apt-get install -f -y 2>&1 | tail -5"

echo "==> restart + status"
$SSH "systemctl restart web888-websdr; sleep 4; systemctl is-active web888-websdr; systemctl status web888-websdr --no-pager | head -12"

echo "==> VERIFY XDG paths"
$SSH "ls -la /var/lib/web888/config /var/lib/web888/firmware /var/cache/web888 /usr/share/web888/firmware 2>&1"

echo "==> VERIFY runtime user + ports"
$SSH "ps -o user,pid,cmd -C websdr.bin; ss -tlnp | grep -E '8073|8074' || true"

echo "==> VERIFY local admin page"
$SSH "curl -s -o /dev/null -w 'admin:%{http_code}\n' http://localhost:8073/admin; curl -s -o /dev/null -w 'status:%{http_code}\n' http://localhost:8073/status"

echo "==> VERIFY no phone-home (rx-888 must NOT appear in new connections)"
$SSH "timeout 6 tcpdump -nn -i eth0 'host downloads.rx-888.com or host proxy.rx-888.com' 2>&1 | tail -3 || echo 'no rx-888 traffic observed'"

echo "==> VERIFY log shows patched paths (journal, last 30 lines)"
$SSH "journalctl -u web888-websdr --no-pager -n 30 | grep -E 'debian|update|bitstream|background' || journalctl -u web888-websdr --no-pager -n 12"

echo "DEPLOY-VERIFY-DONE"
