#!/usr/bin/env bash
# install-redpitaya.sh — install the web888-redpitaya deb into work/rootfs/
# (the image root filesystem), mirroring install-websdr.sh.
#
# dpkg -i (NOT apt: same-version debs are a silent apt no-op, and deb mtimes
# are SOURCE_DATE_EPOCH-normalized). policy-rc.d suppresses service starts
# during install; the units are never enabled anyway (user requirement 2).

set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

ROOTFS=work/rootfs
# Multiple built debs accumulate here; `find | head -1` returns directory
# order (arbitrary) and can pick a stale deb — version-sort, take the newest.
DEB=$(find output/redpitaya -maxdepth 1 -name 'web888-redpitaya_*_armhf.deb' 2>/dev/null | sort --version-sort | tail --lines=1)

[[ -n $DEB ]] || { echo "error: no output/redpitaya/web888-redpitaya_*_armhf.deb (run build-redpitaya-deb.sh first)"; exit 1; }
[[ -d $ROOTFS/usr/bin ]] || { echo "error: $ROOTFS missing (run debootstrap steps first)"; exit 1; }

echo "==> staging deb into rootfs"
sudo mkdir -p "$ROOTFS"/tmp/debs
sudo cp "$DEB" "$ROOTFS"/tmp/debs/

echo -e '#!/bin/sh\nexit 101' | sudo tee "$ROOTFS"/usr/sbin/policy-rc.d >/dev/null
sudo chmod +x "$ROOTFS"/usr/sbin/policy-rc.d

echo "==> dpkg install"
sudo chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  bash -c 'dpkg -i /tmp/debs/web888-redpitaya_*_armhf.deb || { apt-get update -qq && apt-get install -f -y; }'

sudo rm -f "$ROOTFS"/usr/sbin/policy-rc.d
sudo rm -rf "$ROOTFS"/tmp/debs

echo "==> verify installed payload matches the deb (same-version no-op guard)"
DEB_MD5=$(dpkg-deb --fsys-tarfile "$DEB" | tar -xO ./usr/sbin/web888-mode | md5sum | awk '{print $1}')
ROOTFS_MD5=$(sudo md5sum "$ROOTFS"/usr/sbin/web888-mode | awk '{print $1}')
[[ $DEB_MD5 == "$ROOTFS_MD5" ]] || {
  echo "FATAL: rootfs web888-mode ($ROOTFS_MD5) != deb ($DEB_MD5) — stale install" >&2
  exit 1
}

echo "==> verify install: units present + disabled, websdr enablement untouched"
sudo chroot "$ROOTFS" bash -c '
  dpkg -l web888-redpitaya | tail -1
  systemctl is-enabled web888-rpapp@sdr_receiver_hpsdr.service 2>&1 || true
  systemctl is-enabled web888-websdr.service
  ls /usr/lib/systemd/system/web888-rpapp@.service \
     /usr/lib/systemd/system/web888-websdr.service.d/50-redpitaya.conf \
     /usr/share/web888-redpitaya/apps/*/
'
