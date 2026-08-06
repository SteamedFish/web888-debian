# resources/ — non-generated build inputs (committed)

Everything the build needs that is NOT produced by the build itself and is NOT
reliably re-downloadable. The rest of the pipeline (kernel source, bootgen,
debootstrap packages) comes from the network at pinned sources/branches.

Verify integrity: `sha256sum -c SHA256SUMS`

## stock/web888-boot.bin (9,056,768 bytes)

The stock boot.bin, dd-copied from partition 1 of the original Web-888 TF card
(stock card itself kept untouched in storage as the rollback).

Why it is required: the build reuses the stock FSBL (does MIO/PS init, DDR
training) and the 52-byte stock SSBL stub — we do not ship our own FSBL or
U-Boot. `scripts/build-all.sh` step 4 extracts them to `work/stock/fsbl.bin`
(114,696 B @ 0x1700) and `work/stock/ssbl.bin` (52 B @ 0x1D740); offsets per
docs/research/bootbin-repack-spec.md. This file is the only build input that cannot be
obtained from the network at all.

Contains proprietary Xilinx FSBL — repo is local-only, do not push anywhere.

## busybox-static_1.38.0-3_armhf.deb (845,508 bytes)

Debian trixie armhf static busybox, used by `scripts/build-initramfs.sh`.
Vendored because Debian removes superseded versions from the pool, so the
pinned URL would eventually 404. Original source:
https://mirrors.tuna.tsinghua.edu.cn/debian/pool/main/b/busybox/
The script uses this copy when present and only downloads as a fallback.
