#!/usr/bin/env bash
# build-qemu-web888.sh — fetch QEMU 11.1.2, add the vendored web888 machine
# model (resources/qemu-web888/qemu/{patches,files}, from jeskko/web888-ng-hw
# v0.3.0 — see resources/qemu-web888/PROVENANCE.md) and build
# qemu-system-arm (arm-softmmu only) into work/qemu-web888/.
#
# Never installs into the system: the only product is
#   work/qemu-web888/qemu-system-arm  ->  build/qemu-system-arm
# plus a self-check that `-machine help` lists `web888`.
#
#   ./scripts/build-qemu-web888.sh          # full build (incremental on re-run)
#   JOBS=4 ./scripts/build-qemu-web888.sh   # override parallelism
set -euo pipefail
cd "$(dirname "$0")/.."

QEMU_VER=11.1.2
# qemu-11.1.2.tar.xz from download.qemu.org
QEMU_SHA256=731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016
VENDOR=resources/qemu-web888
BUILD=work/qemu-web888
SRC=$BUILD/qemu-$QEMU_VER
TARBALL=qemu-$QEMU_VER.tar.xz
JOBS=${JOBS:-$(nproc)}

for tool in curl tar patch ninja cc pkg-config python3; do
    command -v "$tool" >/dev/null || { echo "Error: $tool not found (see scripts/env-setup.sh)" >&2; exit 1; }
done
[[ -d $VENDOR/qemu/patches && -d $VENDOR/qemu/files ]] || {
    echo "Error: $VENDOR missing (vendored model not checked out?)" >&2; exit 1; }

mkdir -p "$BUILD/dl"
if [[ ! -f $BUILD/dl/$TARBALL ]]; then
    echo ">> downloading $TARBALL"
    curl -fL -o "$BUILD/dl/$TARBALL.part" "https://download.qemu.org/$TARBALL"
    mv "$BUILD/dl/$TARBALL.part" "$BUILD/dl/$TARBALL"
fi
echo ">> verifying $TARBALL sha256"
echo "$QEMU_SHA256  $BUILD/dl/$TARBALL" | sha256sum -c --quiet

APPLIED=$SRC/.web888-patches
if [[ ! -d $SRC ]]; then
    echo ">> extracting"
    tar -C "$BUILD" -xf "$BUILD/dl/$TARBALL"
fi
if ! diff -qr "$VENDOR/qemu/patches" "$APPLIED" >/dev/null 2>&1; then
    # patch set changed: revert what was applied before, apply the new one
    if [[ -d $APPLIED ]]; then
        rev=()
        for p in "$APPLIED"/*.patch; do rev=("$p" "${rev[@]}"); done
        for p in "${rev[@]}"; do
            echo ">> reverting $(basename "$p")"
            patch -d "$SRC" -p1 -R --quiet < "$p"
        done
        rm -rf "$APPLIED"
    fi
    for p in "$VENDOR"/qemu/patches/*.patch; do
        echo ">> applying $(basename "$p")"
        patch -d "$SRC" -p1 --forward --quiet < "$p"
    done
    cp -r "$VENDOR/qemu/patches" "$APPLIED"
fi

# vendored model sources (copied every time so edits are picked up)
echo ">> syncing vendored model sources"
while IFS= read -r f; do
    if ! cmp -s "$VENDOR/qemu/files/$f" "$SRC/$f"; then
        install -D -m 644 "$VENDOR/qemu/files/$f" "$SRC/$f"
    fi
done < <(cd "$VENDOR/qemu/files" && find . -type f)

if [[ ! -f $SRC/build/build.ninja ]]; then
    echo ">> configuring (arm-softmmu only, system libslirp)"
    (cd "$SRC" && ./configure --target-list=arm-softmmu \
        --disable-docs --disable-werror --enable-slirp \
        --disable-gtk --disable-sdl --disable-opengl --disable-vnc \
        --disable-xen --disable-kvm --disable-tools --disable-guest-agent)
fi

echo ">> building qemu-system-arm (-j $JOBS)"
ninja -C "$SRC/build" -j "$JOBS" qemu-system-arm
ln -sf "$(realpath "$SRC/build/qemu-system-arm")" "$BUILD/qemu-system-arm"

echo ">> self-check: web888 machine present"
"$SRC/build/qemu-system-arm" -machine help | grep -E '^web888 ' || {
    echo "Error: web888 machine missing from built QEMU" >&2; exit 1; }
echo ">> done: $BUILD/qemu-system-arm"
