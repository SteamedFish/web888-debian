# Provenance — noip-duc

- **Upstream**: No-IP Dynamic Update Client (DUC) 3,
  https://www.noip.com/download?page=linux (tarball served from
  dmej8g5cpdyqd.cloudfront.net)
- **Pinned version**: 3.3.0 (see `upstream.pin`, includes tarball sha256)
- **License**: PROPRIETARY (No-IP). **Redistribution rights unverified; we
  republish No-IP's official armhf deb verbatim pending confirmation —
  tracked as an open item.**
- **What we do**: download the official source/binary tarball, verify its
  sha256 against `upstream.pin`, extract the official prebuilt
  `binaries/noip-duc_<ver>_armhf.deb`, and copy it **verbatim** into the
  output directory. No rebuild, no repack, no modification — the package
  name, version (`3.3.0`), maintainer scripts, and systemd unit are
  exactly No-IP's.
- **Verified facts** (checked against the downloaded artifacts,
  2026-08-16):
  - tarball `noip-duc_3.3.0.tar.gz` sha256 =
    `7b9d16bf4745e3ff33a7fcf65e9f71e1861621b01c43c53c397a0d004ff50030`
  - inner deb `noip-duc_3.3.0_armhf.deb`: Package `noip-duc`,
    Version `3.3.0`, Architecture `armhf`, Section `net`,
    Maintainer `No-IP Team <support@noip.com>`, no Depends;
    ships `/usr/bin/noip-duc` and
    `/lib/systemd/system/noip-duc.service`.
