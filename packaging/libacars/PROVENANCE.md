# Provenance — libacars

- **Upstream**: https://github.com/szpajder/libacars (Tomasz Lemiech / szpajder)
- **Pinned version**: v2.2.1 (see `upstream.pin`)
- **License**: MIT
- **What we do**: fetch the upstream source tarball, overlay the `debian/`
  directory in this folder, and build armhf binary packages
  (`libacars2`, `libacars2-dev`, `libacars2-tools`) in a Debian trixie
  qemu chroot via `scripts/ci/build-thirdparty-deb.sh`.
- **Packaging adaptation source**: the `debian/` directory of
  https://github.com/ka9q/libacars (Phil Karn's fork), adjusted:
  - Source package name `libacars`, Section `libs`.
  - Build-Depends: debhelper-compat (= 13), cmake, zlib1g-dev,
    libxml2-dev, libjansson-dev.
  - Binary packages split per upstream install layout: shared library
    (`libacars-2.so.2`, SONAME/SOVERSION 2), development files
    (headers under `include/libacars-2/libacars/`, `libacars-2.pc`
    pkg-config file, linker symlink), and command-line tools.
  - All binary packages `Multi-Arch: same`.
  - Local version suffix `-1web888<pkgrev>` (optionally `+ci<N>` from
    `GITHUB_RUN_NUMBER`) marks this as local CI packaging, not an
    upstream Debian upload.
