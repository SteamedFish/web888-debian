# Kernel update SOP (step 6, Debian-source 6.12)

How to move the Web-888 Debian image to a new trixie `linux-source-6.12`
point release (e.g. 6.12.100 → 6.12.101), from source fetch to a verified
ship. Assumes the step-6 chain: Debian-source kernel built as `.deb`s on
the host, full U-Boot as SSBL. The kernel boots from the **ext4 rootfs**
(`/boot/zImage`, a symlink managed by the `zz-web888-zimage` kernel hook);
the FAT firmware partition (mounted at `/boot/firmware`) carries only
boot.bin/boot.scr/web888.dtb/uEnv.txt — a kernel update does **not**
touch it.

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
  `config/kernel-web888-6.12.fragment` + the generated lean fragment
  (`KERNEL_LEAN=1` default) + in-script fixups (MMC_SDHCI chain, governor,
  DEBUG_INFO off) + post-merge asserts. When bumping the pin, delete the
  old snapshot so a fresh one is taken from the new source.

## Procedure

1. **Bump the pin** in `scripts/build-kernel-6.12.sh` (and the orig/debian
   tarball names in `work/downloads/` handling if the layout changed).
2. **Build**: `bash scripts/build-kernel-6.12.sh`
   → `output/kernel/linux-image-<KVER>-web888_<KVER>-<rev>_armhf.deb`
   → `output/kernel/zImage-<KVER>-web888` and `output/zImage` (only the
   stub chain and the QEMU `-kernel` modes still consume the fixed-name
   zImage; the uboot chain boots the rootfs symlink).
   On Arch the script extracts debhelper project-locally and uses
   `make -f debian/rules binary-image` (NOT `bindeb-pkg`, NOT
   `dpkg-buildpackage`) — see the script header comments for why.
3. **DTB drift check**: `KERNEL_DTS_TREE=work/linux-debian-6.12 bash
   scripts/write-dtb.sh` — compiles `config/web888.dts` against the new
   tree's dtsi; the dts must compile clean or the drift must be assessed
   (that is how the devcfg fclk0-3 regression was caught). A kernel point
   release rarely changes the dtsi; if the dtb did change, the shipped dtb
   travels via a `web888-boot` deb rebuild (`scripts/build-boot-deb.sh`),
   not with the kernel deb.
4. **Install into rootfs**: `bash scripts/install-kernel-deb.sh`
   (chroot `dpkg -i` under qemu-arm into `work/rootfs`; the deb's
   `zz-web888-zimage` postinst hook creates/updates the `/boot/zImage`
   + `/boot/zImage.prev` symlinks inside the rootfs).
5. **Image**: `bash scripts/build-image.sh uboot`
   → `output/web888-debian-uboot.img` (asserts the rootfs `/boot/zImage`
   symlink exists). No boot.bin/boot.scr step is involved in a kernel-only
   update — the FAT payload is unchanged.
6. **QEMU gate** (mandatory before any hardware flash):
   `bash scripts/test-qemu.sh uboot` — boots the exact image through the
   real flow (QEMU direct-loads `output/u-boot.bin`, U-Boot runs `boot.scr`
   from the FAT partition, which ext4-loads `/boot/zImage` from the image
   rootfs). Pass = `web888 login:` on the serial log. Expected QEMU
   differences (do not "fix" for them): eth0 never probes (QEMU's GEM PHY
   sits at MDIO 7, no 24c64 EEPROM model), and the FSBL is never executed.
   On hardware, continue with: `uname -r` = new version, 0 failed systemd
   units, `modprobe xilinx_devcfg zynqsdr` → `/dev/xdevcfg` (240,0) +
   `/dev/zynqsdr` (10,258), cpufreq ondemand at a table frequency.
7. **Hardware gate**: flash, boot, checks above + `scripts/hw-test/` smoke.
   Find the board as `web888.local` (mDNS; MAC-prefix `ce:cf:3f:*` fallback,
   see AGENTS.md).

## Shipping

- **APT repo / Releases (default path)**: pushing the pin bump to GitHub
  `master` triggers `build-kernel-deb.yml` — CI rebuilds the deb, passes
  it through the pre-publish QEMU smoke gate, publishes it to the APT repo
  (auto-refreshing the Release image), and devices pick it up with
  `apt update && apt upgrade` + reboot.
- **Full image (local)**: flash the new `output/web888-debian-uboot.img`.
- **Field update of a running board without apt**: `dpkg -i` the
  `linux-image-<KVER>-web888_*.deb` on the device — the kernel hook
  repoints `/boot/zImage` (rotating the old kernel to `/boot/zImage.prev`)
  on the spot. The kernel and its modules MUST travel together — the deb
  carries both; a hand-copied zImage without matching `/lib/modules` boots
  but has no modules. `uEnv.txt` can override `kernel_file` (e.g.
  `kernel_file=vmlinuz-6.12.101-web888`) to pin one installed version.

## Rollback

- `boot.scr` falls back to `/boot/zImage.prev` (rootfs symlink, rotated by
  the kernel hook on every install) if the primary `zImage` fails to load.
  Keep the old version's modules under `/lib/modules/<old-KVER>-web888`
  (`dpkg` leaves the old tree intact unless the old deb is purged).
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
