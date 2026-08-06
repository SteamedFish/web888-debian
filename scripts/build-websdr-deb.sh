#!/usr/bin/env bash
# Build web888-websdr_<ver>_armhf.deb inside the armhf build chroot.
#
# Inputs (all in git or network-fetchable):
#   work/websdr-src/            upstream RaspSDR/server checkout (pinned)
#   config/websdr/patches/      Debian patch series (canonical location)
#   packaging/web888-websdr/    debian/ packaging metadata
#   resources/stock-card/       websdr_{hf,vhf}.bit factory bitstreams
#   /tmp/websdr-build (dir)     armhf trixie chroot (mk-websdr-chroot.sh)
#
# Output:
#   output/websdr/web888-websdr_<ver>_armhf.deb (+ .buildinfo/.changes)
#
# Idempotent: rebuilds from scratch every run.
#
# Host quirks this script must survive:
# - Tool/shell sessions run in separate mount namespaces: tmpfs/bind mounts
#   made by one process are invisible (or gone) in the next. Never rely on a
#   mount made by a previous invocation; bind /dev,/proc,/sys fresh each run.
# - /tmp is mounted nodev: the chroot needs bind-mounted /dev for dpkg.

set -euo pipefail
cd "$(dirname "$0")/.."

SRC=work/websdr-src
CHROOT=${WEB888_BUILD_CHROOT:-/tmp/websdr-build}
PKG=work/websdr-pkg/web888-websdr
OUT=output
PIN=config/websdr/upstream.pin

[[ -d $SRC/.git ]] || { echo "error: $SRC missing (run upstream clone first)"; exit 1; }
[[ -d $CHROOT/usr/bin ]] || { echo "error: build chroot $CHROOT missing"; exit 1; }

# bind mounts must be (re)created in this process's namespace on every run
for m in dev dev/pts proc sys; do
  sudo findmnt "$CHROOT/$m" >/dev/null 2>&1 || sudo mount --bind "/$m" "$CHROOT/$m"
done
trap 'for m in sys proc dev/pts dev; do sudo umount "$CHROOT/$m" 2>/dev/null || true; done' EXIT

# verify upstream checkout matches the pin (commit recorded at clone time)
PIN_COMMIT=$(awk '/^commit: /{print $2}' "$PIN")
CUR_COMMIT=$(git -C "$SRC" rev-parse HEAD)
if [[ $PIN_COMMIT != "$CUR_COMMIT" ]]; then
  echo "error: $SRC at $CUR_COMMIT but pin says $PIN_COMMIT"
  exit 1
fi

echo "==> staging package tree"
sudo rm -rf work/websdr-pkg
mkdir -p "$PKG"
rsync -a --exclude=.git --exclude=build "$SRC"/ "$PKG"/
cp -a packaging/web888-websdr/debian "$PKG"/
cp config/websdr/patches/*.patch "$PKG"/debian/patches/
# KiwiSDR → Web-888 cherry-picks (config/websdr/cherry-picks/) are staged
# alongside the Debian patches; the quilt series below applies them in order
# (Debian set first, then cherry-picks). See cherry-picks/PROVENANCE.md.
cp config/websdr/cherry-picks/*.patch "$PKG"/debian/patches/ 2>/dev/null || true
# quilt series lives outside the patches dir so the patch dir stays a plain
# drop-in set; without debian/patches/series dpkg-source silently applies nothing.
cp config/websdr/debian-patches-series "$PKG"/debian/patches/series
mkdir -p "$PKG"/firmware
cp resources/stock-card/websdr_hf.bit resources/stock-card/websdr_vhf.bit "$PKG"/firmware/

echo "==> copying into chroot"
sudo rm -rf "$CHROOT"/root/websdr-pkg
sudo rsync -a work/websdr-pkg/ "$CHROOT"/root/websdr-pkg/

# anomaly guards: a stale quilt .pc dir makes dpkg-source skip applying patches
# (silently building a pristine tree), and staging steps can silently no-op on
# this host. Wipe .pc and verify the staged patch set before building.
sudo rm -rf "$CHROOT"/root/websdr-pkg/web888-websdr/.pc
# expected patch count comes from the committed series file, so adding a new
# patch never makes the sentinel stale (the take-38 false-fail lesson).
# Count non-comment, non-blank lines (the series now carries section comments).
N_PATCHES=$(awk '!/^[[:space:]]*(#|$)/' config/websdr/debian-patches-series | wc -l)
STAGED=$(sudo bash -c "ls '$CHROOT'/root/websdr-pkg/web888-websdr/debian/patches/"*.patch 2>/dev/null | wc -l)
[[ $STAGED -ge $N_PATCHES ]] || { echo "FATAL: only $STAGED/$N_PATCHES patches staged in chroot — staging anomaly, rerun"; exit 1; }

echo "==> dpkg-buildpackage (armhf chroot, qemu)"
sudo chroot "$CHROOT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  bash -c 'cd /root/websdr-pkg/web888-websdr && dpkg-buildpackage -us -uc -b' 2>&1 \
  | sudo tee "$CHROOT/websdr-build.log" | tail -40

# sentinel: every patch must appear in the build log's apply output. Grepping
# the source tree does not work — dpkg-source --after-build un-applies patches,
# so the tree is pristine again by the time the build finishes.
APPLIED=$(sudo grep -c "info: applying [0-9]" "$CHROOT/websdr-build.log" || true)
[[ $APPLIED -eq $N_PATCHES ]] || { echo "FATAL: only $APPLIED/$N_PATCHES patches applied per build log — refusing deb"; exit 1; }

echo "==> collecting artifacts"
mkdir -p "$OUT"/websdr
DEB=$(sudo bash -c "ls $CHROOT/root/websdr-pkg/web888-websdr_*_armhf.deb 2>/dev/null | head -1")
[[ -n $DEB ]] || { echo "error: no .deb produced"; exit 1; }
# globs must expand inside the root shell — the chroot dirs are root-owned and
# the unprivileged caller's glob silently fails (recurring collect-step bug)
sudo bash -c "cp $CHROOT/root/websdr-pkg/web888-websdr_*_armhf.deb $CHROOT/root/websdr-pkg/web888-websdr_*.buildinfo $CHROOT/root/websdr-pkg/web888-websdr_*.changes '$OUT'/websdr/"
sudo chown "$USER":"$USER" "$OUT"/websdr/web888-websdr_* 2>/dev/null || true

# artifact sentinels: factory dist bundle + vendored fdk lib must be inside
# layout is usr/share/web888/dist/config/dist.* (the old "dist/dist." pattern
# never matched and let broken debs through whenever it actually ran).
# The expected count is derived from the staged source — upstream's dist.* set
# has changed over time (was 8, now 7 at the pinned commit), so a hardcoded
# threshold goes stale; comparing deb-vs-source stays correct automatically.
# Capture the deb listing once: invoking dpkg-deb -c twice on a 30 MB deb in
# quick succession has raced ("tar subprocess killed by signal (Broken pipe)")
# when the host is still under load from the qemu build.
DEB_CONTENTS=$(dpkg-deb -c "$OUT"/websdr/web888-websdr_*_armhf.deb)
EXPECTED=$(ls -1 "$SRC"/unix_env/kiwi.config/dist.* 2>/dev/null | wc -l)
COUNT=$(printf '%s\n' "$DEB_CONTENTS" | grep -c "dist/config/dist\.")
[[ $COUNT -ge $EXPECTED ]] || { echo "FATAL: only $COUNT dist.* files in deb, expected ≥$EXPECTED — install mapping broken"; exit 1; }
printf '%s\n' "$DEB_CONTENTS" | grep -q "libfdk-aac.so.2.0.1" \
  || { echo "FATAL: vendored libfdk-aac.so.2.0.1 missing from deb"; exit 1; }
md5sum "$OUT"/websdr/web888-websdr_*_armhf.deb
ls -la "$OUT"/websdr/web888-websdr_*
