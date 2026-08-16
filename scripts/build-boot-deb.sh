#!/usr/bin/env bash
# Build web888-boot_*.deb from output/ (boot-uboot.bin + fsbl.bin +
# u-boot.bin + boot.scr + config/u-boot/uEnv.txt).
# Result: output/boot/web888-boot_2026.07-1_armhf.deb
#
# web888-boot ships the Debian (uboot-chain) bootloader: the packed
# boot.bin (source-built FSBL + mainline U-Boot SSBL) plus its
# components and the boot script; its postinst installs them onto the
# FAT /boot partition on upgrade. The stub chain embeds kernel+dtb in
# boot.bin and stays rollback-only — not packaged.
set -euo pipefail
cd "$(dirname "$0")/.."

PKG=web888-boot
OUT=output/boot
TREE=work/boot-pkg/$PKG
CHROOT=${WEB888_BUILD_CHROOT:-/tmp/websdr-build}

[[ -f $OUT/$PKG.deb-build-failed ]] && rm -f "$OUT/$PKG.deb-build-failed"

# --- inputs -------------------------------------------------------------
[[ -f output/boot-uboot.bin ]] || {
    echo "Error: output/boot-uboot.bin missing (run scripts/build-bootbin.sh uboot first)" >&2
    exit 1
}
[[ -f output/fsbl/fsbl.bin ]] || {
    echo "Error: output/fsbl/fsbl.bin missing (run scripts/build-fsbl.sh first)" >&2
    exit 1
}
[[ -f output/u-boot.bin ]] || {
    echo "Error: output/u-boot.bin missing (run scripts/build-uboot.sh first)" >&2
    exit 1
}
[[ -x work/u-boot/tools/mkimage ]] || {
    echo "Error: work/u-boot/tools/mkimage missing (run scripts/build-uboot.sh first)" >&2
    exit 1
}

# staleness guard: packed boot.bin must not be older than its inputs
if [[ output/fsbl/fsbl.bin -nt output/boot-uboot.bin \
   || output/u-boot.bin -nt output/boot-uboot.bin ]]; then
    echo "Error: output/boot-uboot.bin is older than fsbl.bin/u-boot.bin —" >&2
    echo "       rebuild it (scripts/build-bootbin.sh uboot) before packaging" >&2
    exit 1
fi

# sanity: Zynq boot header sync word 0xAA995566 (LE) at offset 0x20
python3 - <<'PY'
import sys
with open('output/boot-uboot.bin', 'rb') as f:
    f.seek(0x20)
    magic = f.read(4)
if magic != bytes.fromhex('665599aa'):
    sys.exit('Error: output/boot-uboot.bin has no Zynq boot header')
PY

# --- stage payload --------------------------------------------------------
rm -rf "$TREE"
mkdir -p "$TREE/boot"
install -m644 output/boot-uboot.bin "$TREE/boot/boot.bin"
install -m644 output/fsbl/fsbl.bin  "$TREE/boot/fsbl.bin"
install -m644 output/u-boot.bin     "$TREE/boot/u-boot.bin"
install -m644 config/u-boot/uEnv.txt "$TREE/boot/uEnv.txt"
work/u-boot/tools/mkimage -A arm -T script -C none -n web888-boot \
    -d config/u-boot/boot.cmd "$TREE/boot/boot.scr" >/dev/null

cp -a "packaging/$PKG/debian" "$TREE/debian"
chmod 0755 "$TREE/debian/rules"

# --- build in chroot --------------------------------------------------------
[[ -x $CHROOT/usr/bin/dpkg-buildpackage ]] || {
    echo "Error: build chroot $CHROOT not ready — run scripts/mk-websdr-chroot.sh first" >&2
    exit 1
}
for m in dev dev/pts proc sys; do
    sudo mkdir -p "$CHROOT/$m"
    sudo findmnt "$CHROOT/$m" >/dev/null 2>&1 || sudo mount --bind "/$m" "$CHROOT/$m"
done
trap 'for m in sys proc dev/pts dev; do sudo umount "$CHROOT/$m" 2>/dev/null || true; done' EXIT

sudo mkdir -p "$CHROOT/root"
sudo rsync -a --delete "$TREE/" "$CHROOT/root/boot-pkg/"
sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin bash -c \
    'cd /root/boot-pkg && dpkg-buildpackage -us -uc -b'

mkdir -p "$OUT"
# the globs must expand inside the chroot-side sudo shell — $CHROOT/root is
# drwx------ and unreadable to the build user on the host
sudo bash -c "rsync -a \"$CHROOT\"/root/${PKG}_*_armhf.deb \
                 \"$CHROOT\"/root/${PKG}_*_armhf.buildinfo \
                 \"$CHROOT\"/root/${PKG}_*_armhf.changes \
                 \"$OUT/\""
sudo chown -R "$USER":"$USER" "$OUT"
sudo bash -c "rm -rf \"$CHROOT/root/boot-pkg\" \"$CHROOT\"/root/${PKG}_*"

# --- sentinels ----------------------------------------------------------
DEB=$(ls "$OUT"/${PKG}_*_armhf.deb 2>/dev/null | head -1)
[[ -f $DEB ]] || { echo "Error: deb not produced" >&2; touch "$OUT/$PKG.deb-build-failed"; exit 1; }

fail=0
listing=$(dpkg-deb -c "$DEB")
for f in usr/lib/web888-boot/boot.bin usr/lib/web888-boot/fsbl.bin \
         usr/lib/web888-boot/u-boot.bin usr/lib/web888-boot/boot.scr \
         usr/lib/web888-boot/uEnv.txt; do
    grep -q "$f" <<<"$listing" || { echo "  missing in deb: $f"; fail=1; }
done
dpkg-deb -I "$DEB" | grep -q '^ Package: web888-boot' || { echo "  missing Package field"; fail=1; }
dpkg-deb -e "$DEB" "$TREE/debcontrol"
[[ -s $TREE/debcontrol/postinst ]] || { echo "  missing postinst"; fail=1; }
# the boot.bin in the deb must be byte-identical to the packed output
dpkg-deb --fsys-tarfile "$DEB" | tar -xOf - ./usr/lib/web888-boot/boot.bin > "$TREE/boot.bin.from-deb"
cmp -s output/boot-uboot.bin "$TREE/boot.bin.from-deb" || { echo "  boot.bin in deb differs from output/boot-uboot.bin"; fail=1; }
rm -rf "$TREE/debcontrol" "$TREE/boot.bin.from-deb"

if (( fail )); then
    echo "Error: sentinel check failed for $DEB" >&2
    touch "$OUT/$PKG.deb-build-failed"
    exit 1
fi
echo "OK: $DEB"
