# Reference sources (read-only, do not edit)

- `driver/web888_sdr.h` — github.com/jeskko/web888-ng-hw @ tag **v0.3.0**
  (annotated tag `8b7ab5061ad6be5cd24322dd8912b6551e25350a` → commit
  `767030740a2fdecfebdd383efd23330e6455ff1b`), `driver/web888_sdr.h`,
  blob SHA-256 `2e0d9513ad6034b509a157a32418244b58f5a48144f3d670e725a9941d837f2d`
  (fetched 2026-10-31 from the release tarball
  `v0.3.0.tar.gz`, SHA-256
  `bec8db7da0fc1a251cbd2c6591d2c74057a10380bf040418a591d8b8300e2709`,
  re-verified against the blob at the pinned commit — identical).

  License: dual `(GPL-2.0-or-later WITH Linux-syscall-note) OR MIT`, per the
  SPDX identifier in the file header (copyright jeskko / web888-ng-hw project).

  Purpose: open-source UAPI of the web888-ng kernel driver. Its stock-ABI
  section (magic 'Z', commands 0-12 and 20-21, packed structs) is the
  fixed upstream reference that `config/kernel/zynqsdr_uapi.h` is drift-checked
  against by `scripts/ci/check-zynqsdr-abi.sh`. The extension ioctls
  ('Z', 0x20+) documented in this header are NOT implemented by our
  zynqsdr driver.

## Unmodified/modified inventory

- `driver/web888_sdr.h` — **unmodified** verbatim copy of the upstream file
  at the pinned commit. Nothing else from the repository is vendored here.

## Acknowledgement

Thanks to the web888-ng-hw authors (github.com/jeskko/web888-ng-hw) for
publishing the open driver and its UAPI header, which provides an
independent, authoritative cross-check of the stock Web-888 ioctl ABI that
the zynqsdr driver was originally reconstructed against from the closed
binary and RaspSDR/server userspace sources.
