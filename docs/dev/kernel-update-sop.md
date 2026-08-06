# Kernel update SOP (step 6, Debian-source 6.12)

How to move the Web-888 Debian image to a new trixie `linux-source-6.12`
point release (e.g. 6.12.100 → 6.12.101), from source fetch to a verified
ship. Assumes the step-6 chain: Debian-source kernel built as `.deb`s on the
Arch host, full U-Boot as SSBL, kernel/dtb on the FAT partition.

## Version pinning rules

- The **exact** Debian revision is pinned in `scripts/build-kernel-6.12.sh`
  (`KVER` / `-rev` variables at the top). Never build "whatever is newest" —
  bump the pin deliberately, in its own commit.
- Kernel ABI contract (must not change silently):
  - `xilinx_devcfg` module provides `/dev/xdevcfg` (char 240:0) and
    `fclk0`-`fclk3` under `/sys/class/fclk/` — see the dts override in
    `config/web888.dts` (mainline 6.12 lost fclk from the devcfg node; the
    override restores indices 15–18 per the stable zynq-7000 binding).
  - `zynqsdr` module provides `/dev/zynqsdr` (char 10:258).
  - `LOCALVERSION=-web888` → `uname -r` = `<KVER>-web888`.
- Driver patches live in `config/kernel/` (`xilinx_devcfg.c`, `zynqsdr.c`,
  `0001..0003-*.patch` — including the ikwzm ULPI patch). If the new point
  release breaks a patch hunk, fix the patch in the same commit as the pin
  bump.
- The kconfig baseline is Debian armmp via the snapshot at
  `work/kconfig-*-snapshot` (created by `build-kernel-6.12.sh`; the bindeb
  machinery regenerates `$KDIR/debian` and would clobber it — the script
  restores from the snapshot). Project deltas:
  `config/kernel-web888-6.12.fragment` + in-script fixups (MMC_SDHCI chain,
  governor, DEBUG_INFO off) + post-merge asserts. When bumping the pin,
  delete the old snapshot so a fresh one is taken from the new source.

## Procedure

1. **Bump the pin** in `scripts/build-kernel-6.12.sh` (and the orig/debian
   tarball names in `work/downloads/` handling if the layout changed).
2. **Build**: `bash scripts/build-kernel-6.12.sh`
   → `output/kernel/linux-image-<KVER>-web888_<KVER>-<rev>_armhf.deb`
   → `output/kernel/zImage-<KVER>-web888` and `output/zImage` (downstream
   contract — the image/boot scripts consume this fixed name).
   On Arch the script extracts debhelper project-locally and uses
   `make -f debian/rules binary-image` (NOT `bindeb-pkg`, NOT
   `dpkg-buildpackage`) — see the script header comments for why.
3. **DTB**: `KERNEL_DTS_TREE=work/linux-debian-6.12 bash scripts/write-dtb.sh`
   (compiles `config/web888.dts` against the new tree's dtsi — the dts
   compiles clean or the drift must be assessed; that is how the devcfg
   fclk0-3 regression was caught).
4. **Install into rootfs**: `bash scripts/install-kernel-deb.sh`
   (chroot `dpkg -i` under qemu-arm into `work/rootfs`).
5. **Boot chain**: `bash scripts/build-bootbin.sh uboot` then
   `KERNEL_DTS_TREE=work/linux-debian-6.12 bash scripts/build-image.sh uboot`
   → `output/web888-debian-uboot.img`.
6. **QEMU gate** (mandatory before any hardware flash):
   run the U-Boot chain from
   `-kernel output/u-boot.elf`, with a QEMU-variant dtb — phy@7 — swapped
   onto the FAT of a scratch copy of the image). Required results:
   boot.scr executes from FAT, `/proc/cmdline` matches `bootargs_base`,
   `uname -r` = new version, 0 failed systemd units, `modprobe
   xilinx_devcfg zynqsdr` → `/dev/xdevcfg` (240,0) + `/dev/zynqsdr` (10,258),
   cpufreq ondemand at a table frequency (no `BUG_ON` in cpufreq).
7. **Hardware gate**: flash, boot, same checks + `scripts/hw-test/` smoke.
   Discover the board by MAC prefix `ce:cf:3f:*` (see AGENTS.md).

## Shipping options

- **Full image** (default): flash the new `output/web888-debian-uboot.img`.
- **FAT swap** (field update of a running board): copy the new `zImage` and
  `web888.dtb` onto the FAT partition (mounted at `/boot` on the device —
  verify mountpoint first), and `dpkg -i` the matching
  `linux-image-<KVER>-web888_*.deb` on the device for `/lib/modules`.
  The kernel and its modules MUST travel together — a mismatched pair boots
  but has no modules.

## Rollback

- `boot.scr` falls back to `zImage.prev` if the primary `zImage` fails to
  load. Before a FAT swap, copy the current known-good kernel to
  `zImage.prev` on the FAT partition (and keep its modules under
  `/lib/modules/<old-KVER>-web888` — `dpkg` leaves the old tree intact
  unless the old deb is purged).
- The stub-chain images (`build-bootbin.sh test|final`) remain buildable as
  the pre-U-Boot rollback.
- The stock TF card stays untouched in storage as the last-resort rollback.

## Common traps (learned the hard way)

- `git apply` is broken on this host → patches use `patch -p1`.
- The kernel deb's modules ship compressed (`.ko.xz`) — checking for driver
  presence must account for that.
- Never open `/dev/xdevcfg` under QEMU: the stock Xilinx devcfg driver spins
  forever waiting for PCFG_INIT, which QEMU's devcfg stub never sets
  (soft-locks the guest). Hardware-only path.
- `pkill -f`/`pgrep -f` patterns match the invoking shell's own cmdline —
  use a regex character class (`qemu-system-ar[m]`).
