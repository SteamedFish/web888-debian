# resources/ — non-generated build inputs (committed)

Everything the build needs that is NOT produced by the build itself and is NOT
reliably re-downloadable. The rest of the pipeline (kernel source, bootgen,
debootstrap packages) comes from the network at pinned sources/branches.

Verify integrity: `sha256sum -c SHA256SUMS`

## stock/web888-boot.bin (9,056,768 bytes)

The stock boot.bin, dd-copied from partition 1 of the original Web-888 TF card
(stock card itself kept untouched in storage as the rollback).

Why it is required: the FSBL is now built from source by default
(`FSBL=source` — vendored embeddedsw @ `xilinx_v2023.1` + RaspSDR hooks,
ps7_init arrays extracted from this binary; see
`docs/dev/fsbl-source-build-plan.md`). The stock boot.bin is still needed as
the SSBL-stub extraction source, the ps7_init-array extraction source, and
the `FSBL=stock` escape hatch. `scripts/build-all.sh` step 4 extracts them to
`work/stock/fsbl.bin` (114,696 B @ 0x1700) and `work/stock/ssbl.bin`
(52 B @ 0x1D740); offsets per docs/research/bootbin-repack-spec.md. This file
is the only build input that cannot be obtained from the network at all.

Contains proprietary Xilinx FSBL — repo is local-only, do not push anywhere.

## busybox-static_1.38.0-3_armhf.deb (845,508 bytes)

Debian trixie armhf static busybox, used by `scripts/build-initramfs.sh`.
Vendored because Debian removes superseded versions from the pool, so the
pinned URL would eventually 404. Original source:
https://mirrors.tuna.tsinghua.edu.cn/debian/pool/main/b/busybox/
The script uses this copy when present and only downloads as a fallback.
