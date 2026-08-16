# Provenance — frpc

- **Upstream**: https://github.com/fatedier/frp
- **Pinned version**: v0.71.0 (see `upstream.pin`)
- **License**: Apache-2.0 (upstream `LICENSE` ships in
  `/usr/share/doc/frpc/LICENSE`)
- **What we do**: repack the **official static Go binary release**
  (`frp_<ver>_linux_arm_hf.tar.gz`) — no rebuild. The tarball sha256 is
  verified against `frp_sha256_checksums.txt` from the same GitHub
  release before anything is staged. We then build a minimal
  `frpc_<ver>-1web888<pkgrev>_armhf.deb` with plain `dpkg-deb` containing:
  - `/usr/bin/frpc` (upstream static binary)
  - `/etc/frp/frpc.toml` (upstream sample config, shipped as a conffile)
  - `/lib/systemd/system/frpc.service` (our unit, see `frpc.service`)
  - `/usr/share/doc/frpc/{LICENSE,copyright}`
- **No upstream debian/ packaging exists**; the DEBIAN control files here
  are written by this project.
