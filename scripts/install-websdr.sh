#!/usr/bin/env bash
# Install web888-websdr deb into work/rootfs/ (the image root filesystem).
#
# Installs via chroot apt so runtime dependencies resolve from the
# configured mirror. Service start is suppressed during install
# (policy-rc.d); the unit is left enabled for first boot.

set -euo pipefail
cd "$(dirname "$0")/.."

ROOTFS=work/rootfs
# output/websdr/ accumulates every built deb; plain `ls | head -1` sorts
# lexically and picks the OLDEST one (`-2` before `-5`…), silently installing
# a stale websdr. Version-sort and take the newest instead.
DEB=$(find output/websdr -maxdepth 1 -name 'web888-websdr_*_armhf.deb' 2>/dev/null | sort --version-sort | tail --lines=1)

[[ -n $DEB ]] || { echo "error: no output/websdr/web888-websdr_*_armhf.deb (run build-websdr-deb.sh first)"; exit 1; }
[[ -d $ROOTFS/usr/bin ]] || { echo "error: $ROOTFS missing (run debootstrap steps first)"; exit 1; }

echo "==> staging deb into rootfs"
sudo mkdir -p "$ROOTFS"/tmp/debs
sudo cp "$DEB" "$ROOTFS"/tmp/debs/

# suppress service start/restart inside the chroot, keep enablement
echo -e '#!/bin/sh\nexit 101' | sudo tee "$ROOTFS"/usr/sbin/policy-rc.d >/dev/null
sudo chmod +x "$ROOTFS"/usr/sbin/policy-rc.d

# dpkg -i, NOT apt-get install: apt is a silent no-op for a same-version deb
# (deb mtimes are SOURCE_DATE_EPOCH-normalized, version rarely bumps), which
# left a stale websdr.bin in the persistent work/rootfs — images built after
# a WF fix still shipped the older binary.
echo "==> dpkg install (deps fixed via apt-get -f if needed)"
sudo chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  bash -c 'dpkg -i /tmp/debs/web888-websdr_*_armhf.deb || { apt-get update -qq && apt-get install -f -y; }'

sudo rm -f "$ROOTFS"/usr/sbin/policy-rc.d
sudo rm -rf "$ROOTFS"/tmp/debs

echo "==> verify installed binary matches the deb (same-version no-op guard)"
DEB_MD5=$(dpkg-deb --fsys-tarfile "$DEB" | tar -xO ./usr/bin/websdr.bin | md5sum | awk '{print $1}')
ROOTFS_MD5=$(sudo md5sum "$ROOTFS"/usr/bin/websdr.bin | awk '{print $1}')
[[ $DEB_MD5 == "$ROOTFS_MD5" ]] || {
  echo "FATAL: rootfs websdr.bin ($ROOTFS_MD5) != deb websdr.bin ($DEB_MD5) — stale install" >&2
  exit 1
}

echo "==> verify install"
sudo chroot "$ROOTFS" bash -c \
  'dpkg -l web888-websdr | tail -1; systemctl is-enabled web888-websdr.service; ls -la /usr/bin/websdr.bin /usr/share/web888/firmware/ /var/lib/web888/config/ 2>&1'
