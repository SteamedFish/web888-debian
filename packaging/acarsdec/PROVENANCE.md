# Provenance — acarsdec

- **Upstream**: https://github.com/f00b4r0/acarsdec (Thierry Leconte /
  Thibaut Varene)
- **Pinned version**: v4.6 (see `upstream.pin`)
- **License**: GPL-2.0
- **What we do**: fetch the upstream source tarball, overlay the `debian/`
  directory in this folder, and build the armhf `acarsdec` binary package
  in a Debian trixie qemu chroot via `scripts/ci/build-thirdparty-deb.sh`.
- **Why we package it**: Debian trixie ships no acarsdec package (verified
  2026-10-12: `apt-cache search acars` empty). web888-websdr's ACARS
  extension needs an `acarsdec` binary that decodes raw 12 kHz mono S16LE
  PCM from stdin; upstream supports exactly this via
  `--sndfile file=/dev/stdin,subtype=0x02` (README documents `/dev/stdin`
  pipes), so no vendored fork is needed. Before this package existed the
  websdr deb shipped a vendored build of RaspSDR's `externals/acarsdec`
  submodule at `/usr/lib/web888/acarsdec`; the submodule pin (0b7ba27b)
  is v4.6 + one sdrplay-backend commit, i.e. decoder-identical to v4.6.
- **Build configuration** (`debian/rules`): `-DCJSON=OFF -DALSA=OFF
  -DLIBACARS=OFF -DSNDFILE=ON -DRTLSDR=OFF -DAIRSPY=OFF -DSDRPLAY=OFF
  -DSOAPYSDR=OFF` — only the libsndfile input frontend remains, so the
  binary package's runtime dependency is just `libsndfile1` (+ libc).
  LIBACARS is deliberately off to keep the `full` text output byte-format
  identical to what the websdr ACARS.js parser expects.
- **Section** `hamradio`.
- Local version suffix `-1web888<pkgrev>` (optionally `+ci<N>` from
  `GITHUB_RUN_NUMBER`) marks this as local CI packaging.
