#!/usr/bin/env bash
# build-redpitaya-deb.sh — build web888-redpitaya_<ver>_armhf.deb in the
# armhf chroot (step 4).
#
# Inputs (all in git or produced by build-redpitaya.sh):
#   work/redpitaya-build/bin/     prebuilt armhf binaries (build-redpitaya.sh)
#   resources/redpitaya-bits/     vendored bitstreams + index.html (P0)
#   packaging/web888-redpitaya/   debian/ + payload scripts/units
#   /tmp/websdr-build (dir)       armhf trixie chroot (mk-websdr-chroot.sh)
#
# Output:
#   output/redpitaya/web888-redpitaya_<ver>-1_armhf.deb (+ .buildinfo/.changes)
#
# Reproducible: dpkg-buildpackage derives SOURCE_DATE_EPOCH from the
# (committed, fixed) changelog timestamp — two builds produce identical debs.
# Idempotent: rebuilds from scratch every run.
# Host quirks: same mount-namespace discipline as build-websdr-deb.sh.

set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

CHROOT=${WEB888_BUILD_CHROOT:-/tmp/websdr-build}
PKG=work/redpitaya-pkg/web888-redpitaya
OUT=output/redpitaya

[[ -d $CHROOT/usr/bin ]] || { echo "error: build chroot $CHROOT missing (run scripts/mk-websdr-chroot.sh)"; exit 1; }
[[ -d work/redpitaya-build/bin ]] || { echo "error: work/redpitaya-build/bin missing (run scripts/build-redpitaya.sh first)"; exit 1; }

for m in dev dev/pts proc sys; do
  sudo findmnt "$CHROOT/$m" >/dev/null 2>&1 || sudo mount --bind "/$m" "$CHROOT/$m"
done
trap 'for m in sys proc dev/pts dev; do sudo umount "$CHROOT/$m" 2>/dev/null || true; done' EXIT

echo "==> staging package tree"
sudo rm -rf work/redpitaya-pkg
mkdir -p "$PKG"/bin "$PKG"/apps

# binaries, staged under their final shipped names (dh_install does not rename)
cp work/redpitaya-build/bin/sdr-receiver          "$PKG"/bin/sdr_receiver-server
cp work/redpitaya-build/bin/sdr-receiver-hpsdr    "$PKG"/bin/sdr_receiver_hpsdr-server
cp work/redpitaya-build/bin/sdr-transceiver-wide  "$PKG"/bin/sdr_transceiver_wide-server
cp work/redpitaya-build/bin/si5351-init           "$PKG"/bin/si5351-init

# bitstreams + landing pages
for app in led_blinker sdr_receiver sdr_receiver_hpsdr sdr_transceiver_wide; do
  mkdir -p "$PKG"/apps/"$app"
  cp "resources/redpitaya-bits/$app.bit"        "$PKG"/apps/"$app"/
  cp "resources/redpitaya-bits/$app.index.html" "$PKG"/apps/"$app"/index.html
done

# packaging metadata + payload (payload canonical in packaging/, staged under
# debian/ so debian/install can reference it)
cp -a packaging/web888-redpitaya/debian "$PKG"/
for f in load-bitstream web888-mode switch.conf rpapp-hold 'web888-rpapp@.service' 50-redpitaya.conf; do
  cp "packaging/web888-redpitaya/$f" "$PKG"/debian/
done
chmod 0755 "$PKG"/debian/rules

echo "==> copying into chroot"
sudo rm -rf "$CHROOT"/root/redpitaya-pkg
sudo rsync -a work/redpitaya-pkg/ "$CHROOT"/root/redpitaya-pkg/

echo "==> dpkg-buildpackage (armhf chroot, qemu)"
sudo chroot "$CHROOT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  bash -c 'cd /root/redpitaya-pkg/web888-redpitaya && dpkg-buildpackage -us -uc -b' 2>&1 \
  | sudo tee "$CHROOT/redpitaya-deb-build.log" | tail -20

echo "==> collecting artifacts"
mkdir -p "$OUT"
sudo bash -c "cp $CHROOT/root/redpitaya-pkg/web888-redpitaya_*_armhf.deb $CHROOT/root/redpitaya-pkg/web888-redpitaya_*.buildinfo $CHROOT/root/redpitaya-pkg/web888-redpitaya_*.changes '$OUT'/"
sudo chown -R "$USER":"$USER" "$OUT"

echo "==> artifact sentinels"
DEB=$(find "$OUT" -maxdepth 1 -name 'web888-redpitaya_*_armhf.deb' | head -1)
DEB_CONTENTS=$(dpkg-deb -c "$DEB")
for want in \
  'usr/lib/web888-redpitaya/bin/sdr_receiver-server$' \
  'usr/lib/web888-redpitaya/bin/sdr_receiver_hpsdr-server$' \
  'usr/lib/web888-redpitaya/bin/sdr_transceiver_wide-server$' \
  'usr/lib/web888-redpitaya/bin/led_blinker-server$' \
  'usr/lib/web888-redpitaya/si5351-init$' \
  'usr/lib/web888-redpitaya/load-bitstream$' \
  'usr/sbin/web888-mode$' \
  'etc/web888-redpitaya/switch.conf$' \
  'web888-rpapp@.service$' \
  'web888-websdr.service.d/50-redpitaya.conf$'; do
  printf '%s\n' "$DEB_CONTENTS" | grep -q "$want" \
    || { echo "FATAL: $want missing from deb"; exit 1; }
done
for app in led_blinker sdr_receiver sdr_receiver_hpsdr sdr_transceiver_wide; do
  printf '%s\n' "$DEB_CONTENTS" | grep -q "apps/$app/$app.bit$" \
    || { echo "FATAL: bitstream for $app missing from deb"; exit 1; }
done
md5sum "$DEB"
ls -la "$OUT"
