#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# build-web888-ng-bitstream-deb.sh — download the pinned open FPGA
# bitstream release assets (jeskko/web888-ng-hw v0.3.0) and build
# web888-ng-bitstream_<ver>_all.deb.
#
# Vivado is unavailable on this infrastructure, so — as permitted by the
# Phase 2 lane A spec — the upstream CI-built release assets are used. They
# are pinned by SHA256 in config/web888-ng/pins.env, cross-checked against
# the upstream SHA256SUMS release asset and the GitHub API asset digests,
# and re-verified by the package's postinst on every install/upgrade.
#
# Inputs:
#   config/web888-ng/pins.env   pinned asset names + SHA256
#   packaging/web888-ng-bitstream/  debian/ packaging metadata
#   /tmp/websdr-build (dir)     armhf trixie chroot (mk-websdr-chroot.sh)
#
# Output:
#   output/web888-ng/web888-ng-bitstream_<ver>_all.deb (+ .buildinfo/.changes)
#
# Idempotent: downloads are re-verified every run; existing files with a
# matching hash are reused. Never touches stock bitstreams or runtime state.

set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=../config/web888-ng/pins.env
. config/web888-ng/pins.env

CHROOT=${WEB888_BUILD_CHROOT:-/tmp/websdr-build}
DL=work/web888-ng/downloads
PKG=work/web888-ng-pkg/web888-ng-bitstream
OUT=output/web888-ng

PKG_VERSION=$(dpkg-parsechangelog -l packaging/web888-ng-bitstream/debian/changelog -S Version)
[[ $PKG_VERSION == "$WEB888_NGHW_VERSION"-* ]] \
  || { echo "error: package version $PKG_VERSION does not match web888-ng-hw pin $WEB888_NGHW_VERSION"; exit 1; }

[[ -d $CHROOT/usr/bin ]] || { echo "error: build chroot $CHROOT missing (run scripts/mk-websdr-chroot.sh)"; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 needed to read the release API"; exit 1; }

# Release assets are downloaded through the GitHub API asset endpoint (the
# browser_download_url host is not reachable from every build network). The
# API answer also carries per-asset sha256 digests to cross-check.
echo "==> resolving v$WEB888_NGHW_VERSION release assets"
API_JSON=$(curl -fsSL --retry 3 "$WEB888_NGHW_RELEASE_API")
asset_url() { # asset_url NAME -> api url
  python3 - "$API_JSON" "$1" <<'EOF'
import json, sys
d = json.loads(sys.argv[1])
for a in d.get("assets", []):
    if a["name"] == sys.argv[2]:
        print(a["url"]); sys.exit(0)
sys.exit(f"asset {sys.argv[2]!r} not in release")
EOF
}
asset_digest() { # asset_digest NAME -> sha256:... from the API
  python3 - "$API_JSON" "$1" <<'EOF'
import json, sys
d = json.loads(sys.argv[1])
for a in d.get("assets", []):
    if a["name"] == sys.argv[2]:
        print(a.get("digest", "")); sys.exit(0)
sys.exit(1)
EOF
}

fetch_asset() { # fetch_asset NAME EXPECTED_SHA256
  local name=$1 want=$2 url
  url=$(asset_url "$name")
  mkdir -p "$DL"
  if [[ -f $DL/$name ]]; then
    echo "==> have $name"
  else
    echo "==> downloading $name"
    curl -fsSL --retry 3 -H "Accept: application/octet-stream" -o "$DL/$name" "$url"
  fi
  # the API digest (when present) and our pinned hash must agree
  local api_d
  api_d=$(asset_digest "$name" || true)
  if [[ -n $api_d && $api_d != "sha256:$want" ]]; then
    echo "FATAL: API digest $api_d for $name does not match the pin sha256:$want"; exit 1
  fi
  echo "$want  $DL/$name" | sha256sum -c -
}

echo "==> downloading + verifying bitstream assets (commit $WEB888_NGHW_COMMIT)"
fetch_asset "$WEB888_BITSTREAM_HF"  "$WEB888_BITSTREAM_HF_SHA256"
fetch_asset "$WEB888_BITSTREAM_VHF" "$WEB888_BITSTREAM_VHF_SHA256"
fetch_asset "$WEB888_NGHW_SHA256SUMS" "$WEB888_NGHW_SHA256SUMS_SHA256"
fetch_asset "$WEB888_NGHW_WNS" "$WEB888_NGHW_WNS_SHA256"
fetch_asset "$WEB888_NGHW_LICENCE" "$WEB888_NGHW_LICENCE_SHA256"

# provenance: the hw source tarball itself, hash-pinned (not shipped)
if [[ ! -f $DL/$WEB888_NGHW_TARBALL ]]; then
  curl -fsSL --retry 3 -o "$DL/$WEB888_NGHW_TARBALL" "$WEB888_NGHW_TARBALL_URL"
fi
echo "$WEB888_NGHW_SHA256  $DL/$WEB888_NGHW_TARBALL" | sha256sum -c -

echo "==> cross-checking .bit hashes against upstream SHA256SUMS"
grep -E " (websdr_hf|websdr_vhf)\.bit$" "$DL/$WEB888_NGHW_SHA256SUMS" | \
  (cd "$DL" && sha256sum -c -)

echo "==> staging package tree"
rm -rf "$PKG"
mkdir -p "$PKG/firmware"
cp "$DL/$WEB888_BITSTREAM_HF"  "$PKG/firmware/"
cp "$DL/$WEB888_BITSTREAM_VHF" "$PKG/firmware/"
cp "$DL/$WEB888_NGHW_SHA256SUMS" "$PKG/firmware/SHA256SUMS.upstream"
cp "$DL/$WEB888_NGHW_WNS" "$PKG/firmware/wns.txt"
cp "$DL/$WEB888_NGHW_LICENCE" "$PKG/firmware/vivado-licence.txt"
# our own checksum file (only the shipped files; the upstream SHA256SUMS
# also lists websdr_pfb.bit, which this package deliberately does not ship)
(
  cd "$PKG/firmware"
  sha256sum "$WEB888_BITSTREAM_HF" "$WEB888_BITSTREAM_VHF" \
    > web888-ng-bitstream.sha256
)
cp -a packaging/web888-ng-bitstream/debian "$PKG"/
chmod 0755 "$PKG"/debian/rules

echo "==> copying into chroot"
for m in dev dev/pts proc sys; do
  sudo findmnt "$CHROOT/$m" >/dev/null 2>&1 || sudo mount --bind "/$m" "$CHROOT/$m"
done
trap 'for m in sys proc dev/pts dev; do sudo umount "$CHROOT/$m" 2>/dev/null || true; done' EXIT
sudo rm -rf "$CHROOT"/root/web888-ng-pkg
sudo rsync -a work/web888-ng-pkg/ "$CHROOT"/root/web888-ng-pkg/

echo "==> dpkg-buildpackage (chroot)"
sudo chroot "$CHROOT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  bash -c 'cd /root/web888-ng-pkg/web888-ng-bitstream && dpkg-buildpackage -us -uc -b' 2>&1 \
  | sudo tee "$CHROOT/web888-ng-bitstream-deb-build.log" | tail -20

echo "==> collecting artifacts"
mkdir -p "$OUT"
sudo bash -c "cp $CHROOT/root/web888-ng-pkg/web888-ng-bitstream_* '$OUT'/"
sudo chown -R "$USER":"$USER" "$OUT"

echo "==> artifact sentinels"
DEB=$(ls -t "$OUT"/web888-ng-bitstream_*_all.deb | head -1)
DEB_CONTENTS=$(dpkg-deb -c "$DEB")
for want in \
  "usr/share/web888-ng/firmware/$WEB888_BITSTREAM_HF\$" \
  "usr/share/web888-ng/firmware/$WEB888_BITSTREAM_VHF\$" \
  'usr/share/web888-ng/firmware/web888-ng-bitstream.sha256$' \
  'usr/share/web888-ng/firmware/SHA256SUMS.upstream$' \
  'usr/share/web888-ng/firmware/wns.txt$' \
  'usr/share/web888-ng/firmware/vivado-licence.txt$'; do
  printf '%s\n' "$DEB_CONTENTS" | grep -q "$want" \
    || { echo "FATAL: $want missing from deb"; exit 1; }
done
# the package must never touch the stock firmware directory
printf '%s\n' "$DEB_CONTENTS" | grep -q 'usr/share/web888/firmware/' \
  && { echo "FATAL: deb overlaps the stock firmware directory"; exit 1; }
sha256sum "$DEB"
ls -la "$OUT"
