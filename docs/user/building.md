# Building the Debian image

How to build the Web-888 Debian image from source, what you can configure,
and how to gate the result in QEMU before flashing. For the flashing
procedure itself see [flashing.md](flashing.md); for host prerequisites see
the **Building** section of the top-level `README.md`.

## Boot chains

| Chain | Build command | What it is |
|---|---|---|
| `uboot` (default, production) | `scripts/build-all.sh` | Source-built FSBL → full mainline U-Boot v2026.07 as SSBL → `boot.scr`/`uEnv.txt` on FAT → Debian-source 6.12 kernel |
| `stub` (rollback) | `CHAIN=stub KERNEL=6.6 scripts/build-all.sh` | Source-built FSBL → minimal stub SSBL → legacy linux-xlnx 6.6 kernel |

The U-Boot chain is what ships. The stub chain stays buildable as the
known-good rollback (that is the chain the first public release used).
Both chains pack the source-built FSBL by default; `FSBL=stock` swaps in
the blob extracted from the stock boot.bin (see the knobs table below).

## The one-command build

```sh
scripts/build-all.sh           # incremental — skips steps whose outputs exist
scripts/build-all.sh --clean   # delete work/ and output/ first (from-scratch)
```

The script prints each step as it runs and ends with the deliverable:

```
== DONE: output/web888-debian-uboot.img (chain=uboot kernel=6.12 fsbl=source) ==
```

`--clean` removes `work/` and `output/` but keeps `.tmp/` (stock-firmware
inputs and the kernel git cache).

## Configurable knobs

All knobs are environment variables; none are required.

### `build-all.sh`

| Variable | Values | Default | Effect |
|---|---|---|---|
| `CHAIN` | `uboot` \| `stub` | `uboot` | Boot chain to assemble (table above). `stub` maps to the legacy bootbin/image mode `final`. |
| `KERNEL` | `6.12` \| `6.6` | `6.12` | Kernel flow: `6.12` = Debian linux-source, pinned deb `6.12.100-web888`; `6.6` = legacy linux-xlnx tree. |
| `FSBL` | `source` \| `stock` | `source` | FSBL packed into boot.bin: `source` = built from the vendored embeddedsw zynq_fsbl tree via `build-fsbl.sh` (hardware-verified; needs `arm-none-eabi-gcc`); `stock` = blob extracted from the stock boot.bin (escape hatch). Also honored by `build-bootbin.sh` directly. |
| `DEBIAN_MIRROR` | URL | `mirrors.tuna.tsinghua.edu.cn/debian` | debootstrap/apt mirror for the rootfs. Also consumed by `env-setup.sh`, `build-initramfs.sh`, `mk-websdr-chroot.sh`. |

### Rootfs configuration (`configure-rootfs.sh`, runs as a build-all step)

| Variable | Default | Effect |
|---|---|---|
| `DEBIAN_SECURITY_MIRROR` | `mirrors.tuna.tsinghua.edu.cn/debian-security` | apt security mirror baked into the image |
| `GOVERNOR` | `ondemand` | CPU frequency governor configured in the rootfs |

### Development helpers

| Variable | Default | Effect |
|---|---|---|
| `KIWI_TREE` | `.tmp/repos/KiwiSDR` | Local KiwiSDR checkout used by `scripts/refresh-cherry-picks.sh` |

Parallelism is **not** a knob — every build script compiles with all cores
(`nproc`).

## QEMU gates (mandatory before flashing)

There is no serial adapter on this board — QEMU is the only pre-hardware
test. Gate the exact image you are about to flash:

| Mode | Command | What it verifies |
|---|---|---|
| `uboot` | `scripts/test-qemu.sh uboot` | The real boot flow: QEMU loads `output/u-boot.bin` (U-Boot + appended DTB) at `0x04000000`, U-Boot runs `boot.scr` from the image's FAT partition, which ext4-loads the kernel via the rootfs `/boot/zImage` symlink (+ dtb from FAT) and boots Linux from the ext4 rootfs. Pass = login prompt on the serial log. |
| `final` | `scripts/test-qemu.sh final` | Direct-kernel boot of the stub-chain image onto `/dev/mmcblk0p2`. |
| `test` | `scripts/test-qemu.sh test` | initramfs gate: must print `DEBIAN_ROOTFS_MOUNTED`. |

Known QEMU-vs-hardware differences (expected — do **not** "fix" the
production DTB to match QEMU):

- **eth0 never probes under QEMU.** The emulated `cadence_gem` PHY sits at
  a fixed MDIO address that does not match the board's `phy@1`, and QEMU
  emulates no 24c64 EEPROM, so the MAC NVMEM cell can never resolve and the
  driver defers forever. On hardware, U-Boot reads the factory MAC
  (`ce:cf:3f:*`) from the board EEPROM and plants it in `ethaddr` (and the
  kernel device tree) before probing. Verify networking on hardware, not in
  QEMU — this is why the `uboot` gate opens no ssh hostfwd.
- **The FSBL is not exercised.** QEMU direct-boots U-Boot (or the kernel),
  skipping BootROM+FSBL. The first hardware boot of a new bootloader build
  is therefore the real FSBL-handoff test — keep the stock TF card as the
  rollback.

## Artifacts

Everything lands in `output/` (gitignored):

| File | Produced by | Purpose |
|---|---|---|
| `web888-debian-uboot.img` | `build-image.sh uboot` | Flashable TF-card image (deliverable, U-Boot chain) |
| `web888-debian-final.img` | `build-image.sh final` | Flashable image, stub chain |
| `boot-uboot.bin` / `boot-final.bin` | `build-bootbin.sh` | FSBL + U-Boot (or FSBL + stub) — flashed to FAT as `boot.bin` |
| `u-boot.bin` | `build-uboot.sh` | U-Boot proper with appended DTB; packaged into `boot-uboot.bin`, also what the QEMU gate loads |
| `zImage` | kernel step | Feeds the stub chain (embedded in boot.bin) and the QEMU `-kernel` modes; the uboot chain boots the rootfs `/boot/zImage` symlink instead |
| `web888.dtb` | `build-boot-deb.sh` (write-dtb.sh; inside the web888-boot deb payload) | Loaded by `boot.scr` from the FAT partition |
| `initramfs.cpio.gz` | `build-initramfs.sh` | Used by the `test` gate |

The card image is plain MBR (the Zynq BootROM cannot parse GPT): partition
1 = FAT firmware (64 MiB, `/boot/firmware`: `boot.bin`, `boot.scr`,
`uEnv.txt`, `web888.dtb`), partition 2 = ext4 rootfs (kernels in `/boot`,
`zImage`/`zImage.prev` symlinks managed by the web888-boot kernel hook).

## Manual per-step builds

`build-all.sh` simply calls these in order; any step can be rerun directly
(steps 7–10 need sudo — run `sudo -v` first):

```sh
scripts/env-setup.sh             #  1. host toolchain check
#  2. kernel source → work/linux-xlnx (cached in .tmp/linux-xlnx)
#  3. bootgen       → work/tools/bootgen
#  4. stock FSBL/SSBL extracted from resources/stock/web888-boot.bin
scripts/build-kernel-6.12.sh     #  5. 6.12 kernel (KERNEL=6.6 → build-kernel.sh)
scripts/build-initramfs.sh       #  6. test-mode initramfs
#  7. debootstrap   → work/rootfs (trixie armhf)
scripts/configure-rootfs.sh      #  8. hostname/password/network/ssh/services
scripts/install-modules.sh       # 8b. kernel modules into rootfs
#       fetch-upstream-src.sh websdr|redpitaya|u-boot — auto-run by build-all.sh before
#       8c/8e: clones the pinned upstream tree (config/<name>/upstream.pin) into
#       work/<name>-src on first run; no-op when already at the pinned commit
scripts/build-websdr-deb.sh      # 8c. web888-websdr deb (armhf chroot)
scripts/install-websdr.sh        # 8d. install deb into rootfs
scripts/build-redpitaya-deb.sh   # 8e. web888-redpitaya deb
scripts/install-redpitaya.sh     # 8f. install deb (units disabled by default)
scripts/build-uboot.sh           # 8g. U-Boot v2026.07 (CHAIN=uboot only; auto-clones work/u-boot)
scripts/build-fsbl.sh            # 8h. source-built FSBL (FSBL=source only)
scripts/build-bootbin.sh uboot   #  9. boot.bin assembly (+ dtb)
scripts/build-image.sh uboot     # 10. final card image
```
