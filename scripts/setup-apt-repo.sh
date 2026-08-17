#!/usr/bin/env bash
# setup-apt-repo.sh — configure the web888 APT repo (CI-built debs: kernel,
# websdr, redpitaya, boot + third-party tools) inside work/rootfs.
# Idempotent; safe to run on every configure-rootfs.sh pass so every image
# ships repo-ready (on-device upgrades via apt, no reflash).
#
# Repo docs: docs/dev/github-ci-apt-repo.md. Key: resources/apt-repo/pubkey.asc
# (PROVENANCE.md next to it). Override the URL for testing via WEB888_APT_REPO.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOTFS=work/rootfs
KEY_SRC=resources/apt-repo/pubkey.asc
REPO_URL="${WEB888_APT_REPO:-https://web888.steamedfish.org/apt}"

[[ -f $KEY_SRC ]] || {
    echo "Error: $KEY_SRC missing (APT repo signing pubkey — see resources/apt-repo/PROVENANCE.md)" >&2
    exit 1
}
[[ -d $ROOTFS/usr/bin ]] || {
    echo "Error: $ROOTFS missing (run debootstrap steps first)" >&2
    exit 1
}

# ASCII-armored keyring: apt (>= 1.4; trixie ships 3.x) accepts armored keys
# in signed-by, so no gpg --dearmor host dependency.
sudo -n install -D -m 0644 "$KEY_SRC" "$ROOTFS/usr/share/keyrings/web888.asc"
sudo -n tee "$ROOTFS/etc/apt/sources.list.d/web888.list" >/dev/null <<EOF
deb [arch=armhf signed-by=/usr/share/keyrings/web888.asc] $REPO_URL ./
EOF

echo "==> APT repo configured in rootfs: $REPO_URL"
