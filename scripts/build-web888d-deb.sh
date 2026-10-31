#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# build-web888d-deb.sh — build web888-web888d_<ver>_armhf.deb from the
# source-built daemon + UI produced by scripts/build-web888d.sh.
#
# Inputs:
#   work/web888d-build/            bin/web888d, ui/, VERSION (build-web888d.sh)
#   packaging/web888-web888d/      debian/ + payload (service, default config)
#   /tmp/websdr-build (dir)        armhf trixie chroot (mk-websdr-chroot.sh)
#
# Output:
#   output/web888d/web888-web888d_<ver>_armhf.deb (+ .buildinfo/.changes)
#
# The package is data-only from dpkg's perspective (static binary + UI), so
# the deb is assembled in the standard build chroot like the other web888-*
# packages. Reproducible: dpkg-buildpackage derives SOURCE_DATE_EPOCH from
# the (committed, fixed) changelog timestamp.

set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=../config/web888-ng/pins.env
. config/web888-ng/pins.env

CHROOT=${WEB888_BUILD_CHROOT:-/tmp/websdr-build}
BUILD=work/web888d-build
PKG=work/web888d-pkg/web888-web888d
OUT=output/web888d

PKG_VERSION=$(dpkg-parsechangelog -l packaging/web888-web888d/debian/changelog -S Version)
[[ $PKG_VERSION == "$WEB888_NG_VERSION"-* ]] \
  || { echo "error: package version $PKG_VERSION does not match web888-ng pin $WEB888_NG_VERSION"; exit 1; }

[[ -d $CHROOT/usr/bin ]] || { echo "error: build chroot $CHROOT missing (run scripts/mk-websdr-chroot.sh)"; exit 1; }
[[ -x $BUILD/bin/web888d ]] || { echo "error: $BUILD/bin/web888d missing (run scripts/build-web888d.sh)"; exit 1; }
[[ -f $BUILD/ui/index.html ]] || { echo "error: $BUILD/ui missing (run scripts/build-web888d.sh)"; exit 1; }

echo "==> staging package tree"
rm -rf "$PKG"
mkdir -p "$PKG/bin" "$PKG/ui"
cp "$BUILD/bin/web888d" "$PKG/bin/"
cp -a "$BUILD/ui/." "$PKG/ui/"
cp -a packaging/web888-web888d/debian "$PKG"/
# payload files referenced by debian/install
cp packaging/web888-web888d/debian/web888-web888d.service "$PKG"/
cp packaging/web888-web888d/debian/web888-web888d-pl.service "$PKG"/
cp packaging/web888-web888d/debian/web888d.toml.default "$PKG"/
chmod 0755 "$PKG"/debian/rules

echo "==> copying into chroot"
for m in dev dev/pts proc sys; do
  sudo findmnt "$CHROOT/$m" >/dev/null 2>&1 || sudo mount --bind "/$m" "$CHROOT/$m"
done
trap 'for m in sys proc dev/pts dev; do sudo umount "$CHROOT/$m" 2>/dev/null || true; done' EXIT
sudo rm -rf "$CHROOT"/root/web888d-pkg
sudo rsync -a work/web888d-pkg/ "$CHROOT"/root/web888d-pkg/

echo "==> dpkg-buildpackage (chroot)"
sudo chroot "$CHROOT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  bash -c 'cd /root/web888d-pkg/web888-web888d && dpkg-buildpackage -us -uc -b' 2>&1 \
  | sudo tee "$CHROOT/web888d-deb-build.log" | tail -20

echo "==> collecting artifacts"
mkdir -p "$OUT"
sudo bash -c "cp $CHROOT/root/web888d-pkg/web888-web888d_* '$OUT'/"
sudo chown -R "$USER":"$USER" "$OUT"

echo "==> artifact sentinels"
DEB=$(ls -t "$OUT"/web888-web888d_*_armhf.deb | head -1)
DEB_CONTENTS=$(dpkg-deb -c "$DEB")
for want in \
  'usr/bin/web888d$' \
  'usr/share/web888d/ui/index.html$' \
  'usr/share/web888d/ui/app.js$' \
  'usr/share/web888d/web888d.toml.default$' \
  'lib/systemd/system/web888-web888d.service$' \
  'lib/systemd/system/web888-web888d-pl.service$'; do
  printf '%s\n' "$DEB_CONTENTS" | grep -q "$want" \
    || { echo "FATAL: $want missing from deb"; exit 1; }
done
# the service must be default-off and never xdevcfg-capable
if printf '%s\n' "$DEB_CONTENTS" | grep -q 'etc/systemd/system/.*wants'; then
  echo "FATAL: deb enables the service via a wants symlink"; exit 1
fi
# the main unit must have no xdevcfg access and no privileged ExecStartPre
MAIN_UNIT=$(mktemp)
PL_UNIT=$(mktemp)
dpkg-deb --fsys-tarfile "$DEB" | tar -xOf - ./lib/systemd/system/web888-web888d.service > "$MAIN_UNIT"
dpkg-deb --fsys-tarfile "$DEB" | tar -xOf - ./lib/systemd/system/web888-web888d-pl.service > "$PL_UNIT"
grep -q 'DeviceAllow=/dev/xdevcfg' "$MAIN_UNIT" \
  && { echo "FATAL: main unit grants /dev/xdevcfg"; exit 1; }
grep -q '^ExecStartPre=+' "$MAIN_UNIT" \
  && { echo "FATAL: main unit still has a privileged ExecStartPre"; exit 1; }
grep -q 'Requires=web888-web888d-pl.service' "$MAIN_UNIT" \
  || { echo "FATAL: main unit does not require the PL unit"; exit 1; }
grep -q '^ExecStart=/usr/lib/web888/web888-fpga-select load$' "$PL_UNIT" \
  || { echo "FATAL: PL unit does not run web888-fpga-select load"; exit 1; }
grep -q 'DeviceAllow=/dev/xdevcfg rw' "$PL_UNIT" \
  || { echo "FATAL: PL unit lacks the xdevcg device allowance"; exit 1; }
# ProtectSystem=strict makes /run read-only too; the helper creates its
# lock file under /run/lock itself, so the lock directory must be writable
grep -q '^ReadWritePaths=.* /run/lock\|^ReadWritePaths=/run/lock' "$PL_UNIT" \
  || { echo "FATAL: PL unit cannot write its /run/lock lock file"; exit 1; }
rm -f "$MAIN_UNIT" "$PL_UNIT"
dpkg-deb -I "$DEB" | grep -q 'web888-redpitaya (>= 2025.430-3)' \
  || { echo "FATAL: web888-redpitaya floor missing from Depends"; exit 1; }
dpkg-deb -I "$DEB" | grep -q 'web888-websdr (>= 2026.1020-2)' \
  || { echo "FATAL: web888-websdr floor missing from Depends"; exit 1; }
sha256sum "$DEB"
ls -la "$OUT"
