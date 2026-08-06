#!/usr/bin/env bash
# build-redpitaya.sh — armhf build of the Web-888 Red Pitaya app servers
# (step 4) inside the qemu chroot (mk-websdr-chroot.sh).
#
# Inputs (all in git):
#   work/redpitaya-src/         RaspSDR/red-pitaya-notes checkout (pinned)
#   config/redpitaya/upstream.pin
#   scripts/hw-test/si5351/     si5351-init C++ sources (provenance: hw-test README)
#   /tmp/websdr-build (dir)     armhf trixie chroot
#
# Output:
#   work/redpitaya-build/bin/   sdr-receiver, sdr-receiver-hpsdr,
#                               sdr-transceiver-wide (if it compiles cleanly),
#                               si5351-init
#   work/redpitaya-build/build.log
#
# Idempotent: rebuilds from scratch every run. led_blinker has no server
# binary (bitstream-only smoke app) — nothing to build for it.
#
# Host quirks (same as build-websdr-deb.sh): mount namespaces are per-process,
# so /dev /dev/pts /proc /sys are bind-mounted fresh each run with an EXIT trap.

set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

SRC=work/redpitaya-src
CHROOT=${WEB888_BUILD_CHROOT:-/tmp/websdr-build}
OUT=work/redpitaya-build
PIN=config/redpitaya/upstream.pin

[[ -d $SRC/.git ]] || { echo "error: $SRC missing (run the P0 clone first)"; exit 1; }
[[ -d $CHROOT/usr/bin ]] || { echo "error: build chroot $CHROOT missing (run scripts/mk-websdr-chroot.sh)"; exit 1; }

PIN_COMMIT=$(awk '/^commit: /{print $2}' "$PIN")
CUR_COMMIT=$(git -C "$SRC" rev-parse HEAD)
[[ $PIN_COMMIT == "$CUR_COMMIT" ]] || { echo "error: $SRC at $CUR_COMMIT but pin says $PIN_COMMIT"; exit 1; }

for m in dev dev/pts proc sys; do
  sudo findmnt "$CHROOT/$m" >/dev/null 2>&1 || sudo mount --bind "/$m" "$CHROOT/$m"
done
trap 'for m in sys proc dev/pts dev; do sudo umount "$CHROOT/$m" 2>/dev/null || true; done' EXIT

echo "==> staging sources into chroot"
sudo rm -rf "$CHROOT"/root/redpitaya-src
sudo mkdir -p "$CHROOT"/root/redpitaya-src/projects "$CHROOT"/root/redpitaya-src/si5351
for app in sdr_receiver sdr_receiver_hpsdr sdr_transceiver_wide; do
  sudo mkdir -p "$CHROOT/root/redpitaya-src/projects/$app"
  sudo rsync -a "$SRC/projects/$app/server/" "$CHROOT/root/redpitaya-src/projects/$app/server/"
done
sudo rsync -a scripts/hw-test/si5351/ "$CHROOT/root/redpitaya-src/si5351/"

echo "==> applying Debian patch series (config/redpitaya/patches/series)"
sudo rm -rf "$CHROOT"/root/redpitaya-patches
sudo rsync -a config/redpitaya/patches/ "$CHROOT"/root/redpitaya-patches/
# patches are git-diff format against the repo root; -p1 strips a/, b/
sudo chroot "$CHROOT" bash -c '
    cd /root/redpitaya-src
    while read -r p; do
        case $p in ""|\#*) continue ;; esac
        patch -p1 --no-backup-if-mismatch < "/root/redpitaya-patches/$p" || exit 1
    done < /root/redpitaya-patches/series
'
# sentinel: the peri.c ioctl patch must be in the staged tree (silent
# patch-skip would ship a binary that SEGVs on the DSA export — the hardware-gate bug)
sudo grep -q ZYNQSDR_AD8370_SET "$CHROOT/root/redpitaya-src/projects/sdr_receiver_hpsdr/server/peri.c" \
  || { echo "FATAL: 0001-peri-use-zynqsdr-ioctl.patch not applied in staged tree"; exit 1; }

echo "==> building (armhf chroot, qemu)"
sudo chroot "$CHROOT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin bash -c '
    set -x
    cd /root/redpitaya-src
    for app in sdr_receiver sdr_receiver_hpsdr sdr_transceiver_wide; do
        make -C "projects/$app/server" clean
        make -C "projects/$app/server"
    done
    g++ -O2 -o si5351-init si5351/main.cpp si5351/si5351.cpp si5351/i2c.cpp
' 2>&1 | sudo tee "$CHROOT/redpitaya-build.log"

echo "==> collecting artifacts"
sudo rm -rf "$OUT"
mkdir -p "$OUT"/bin
sudo cp "$CHROOT"/redpitaya-build.log "$OUT"/build.log
for app in sdr_receiver sdr_receiver_hpsdr sdr_transceiver_wide; do
  bin=$(awk -v app="$app" '{print app}' <<<"$app" | tr '_' '-')
  sudo cp "$CHROOT/root/redpitaya-src/projects/$app/server/$bin" "$OUT/bin/" 2>/dev/null \
    || echo "note: $app produced no binary (skipped)"
done
sudo cp "$CHROOT/root/redpitaya-src/si5351-init" "$OUT/bin/"
sudo chown -R "$USER":"$USER" "$OUT"

echo "==> results"
for f in "$OUT"/bin/*; do
  file "$f"
  arm-linux-gnueabihf-readelf -d "$f" | grep NEEDED || true
done
ls -la "$OUT"/bin
