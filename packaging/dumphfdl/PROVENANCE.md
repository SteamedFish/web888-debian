# Provenance — dumphfdl

- **Upstream**: https://github.com/szpajder/dumphfdl (Tomasz Lemiech / szpajder)
- **Pinned version**: v1.7.0 (see `upstream.pin`)
- **License**: GPL-3.0
- **What we do**: fetch the upstream source tarball, overlay the `debian/`
  directory in this folder, and build the armhf `dumphfdl` binary package
  in a Debian trixie qemu chroot via `scripts/ci/build-thirdparty-deb.sh`.
  The build installs the previously built `libacars2`/`libacars2-dev` debs
  into the chroot first (build libacars before dumphfdl).
- **Packaging adaptation source**: the `debian/` directory of upstream
  master at commit 7b78d5b (Phil Karn's packaging), **fixed**:
  - Upstream listed the `-dev` build dependency packages in the binary
    package `Depends:`; ours uses `${shlibs:Depends}, ${misc:Depends}` so
    runtime dependencies are computed correctly.
  - Build-Depends: debhelper-compat (= 13), cmake, pkg-config,
    libfftw3-dev, libglib2.0-dev, libacars2-dev, libconfig++-dev,
    libsoapysdr-dev, libzmq3-dev, librdkafka-dev, libliquid-dev,
    libsqlite3-dev.
  - Section `hamradio`.
  - Local version suffix `-1web888<pkgrev>` (optionally `+ci<N>` from
    `GITHUB_RUN_NUMBER`) marks this as local CI packaging.
