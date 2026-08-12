# Debian kernel & firmware options — research

Status: **decision implemented**. Option 2 (own kernel .deb on Debian's 6.12
source + Debian config) ships as the default kernel build chain — see
`scripts/build-kernel-6.12.sh`, `config/kernel-web888-6.12.fragment`,
`docs/dev/kernel-update-sop.md`, and `docs/dev/TODO.md` step 6. This file is
the historical decision record; the §7 "Now: Option 3, then Option 2"
recommendation was superseded — Option 2 was taken directly (`KERNEL` defaults
to 6.12 in `scripts/build-all.sh`). The commissioned question and analysis
below are retained unchanged.
Commissioned question: the custom kernel still lacks many features and firmware
on real hardware; evaluate three options for closing the gap.

- **Option 1**: switch to Debian's native kernel package + firmware packages; our
  drivers become standalone .deb packages hard-pinned to the kernel version
  (no DKMS — CPU too weak).
- **Option 2**: build our own kernel package using Debian's kernel build options
  as the base, plus our drivers, plus firmware packages.
- **Option 3**: keep the current kernel tree, but complete the config by
  referencing Debian's kernel build options, plus firmware packages.

All externally load-bearing claims below were verified by
downloading and inspecting the actual Debian packages from
`deb.debian.org` (see §7 Evidence). Scratch copies: `.tmp/kernel-research/`.

---

## 1. Current state (verified in this repo)

**Kernel provenance.** `scripts/build-kernel.sh` builds
`linux-xlnx @ xlnx_rebase_v6.6_LTS` (6.6.80; the branch lags upstream 6.6.y,
which is past 6.6.110) with `xilinx_zynq_defconfig` + the 84-line
`config/kernel-web888.fragment`. Kernel release: `6.6.80-web888+`.
Two self-maintained drivers are materialized into the tree as modules:
`xilinx_devcfg.ko` (legacy `/dev/xdevcfg` PCAP char device, forward-ported by
us from Xilinx v2016.4 — the xlnx tree deleted it after v2018.3) and
`zynqsdr.ko` (our control+data plane, written from scratch). FPGA manager is
deliberately off (`FPGA_MGR_ZYNQ_FPGA=n`) because it would claim the same
`xlnx,zynq-devcfg-1.0` compatible before `xilinx_devcfg` can probe; websdr
uses `/dev/xdevcfg`, not fpga-manager.

**Feature gap, quantified.** Enabled symbols: ours **1243** vs Debian armmp
**6117**. Verified missing in `work/linux-xlnx/.config`:

| Area | Current kernel | Consequence |
|---|---|---|
| `NETFILTER` | **entirely off** | step 3.5 blocked: no iptables/nft at any layer |
| cgroups | `CGROUPS=y` but `MEMCG` off, `BPF_SYSCALL` off | reduced systemd/container semantics |
| Filesystems | no FUSE, exFAT, NTFS3, XFS, Btrfs | can't read common removable media |
| USB WiFi | no brcmfmac / rtl8xxxu / mt7601u / ath9k / rt2x00 / rtlwifi | USB WiFi dongles dead |
| USB serial | no ch341 / cp210x / ftdi | admin console accessories dead (step 3.5 wants `DeviceAllow=ttyUSB/ttyACM`) |
| USB net/audio/BT | no CDC-ETHER/NCM, no USB audio, no Bluetooth | tethering, audio dongles, BT dead |
| Security | no AppArmor, no AUDIT, no FANOTIFY, no MODULE_SIG | deviates from Debian userspace expectations |
| Misc | no WireGuard; squashfs/overlayfs =y (fine) | — |

Stock Alpine for comparison loaded `nf_tables`, `cfg80211`, `8021q`
(`docs/research/hardware-facts.md`) — the stock kernel was *more* featured than ours
in the networking/wifi area.

**Firmware state.** No `firmware-*` packages are installed; `/lib/firmware`
is essentially empty. Onboard peripherals need **no** firmware blobs
(RTL8211 PHY, Si5351 clock, ATGM336H GPS, ADC/FPGA — the FPGA bitstream is
user-provided `websdr_{hf,vhf}.bit`, not linux-firmware). Firmware only
matters for user-plugged USB WiFi/BT dongles.

**Boot-chain contract (recap, `docs/research/bootbin-repack-spec.md`).** Stock FSBL +
52-byte SSBL stub; gzip self-extracting zImage @ `0x02008000`; DTB @
`0x02000000` (our own `config/web888.dts` — kernel-version-agnostic);
optional initrd @ `0x03000000` whose size comes from **our own** bootargs
(`initrd=0x3000000,<size>`; the stock "≤ 4 MiB" is a bootargs value, not a
hardware limit). No initrd in the final flow today (SDHCI/EXT4/MACB built-in).

---

## 2. External finding #1 (decisive): Debian's armmp kernel has **no Zynq support**

Downloaded `linux-image-6.12.94+deb13-armmp_6.12.94-1_armhf.deb` (56 MB,
trixie main; security pocket has 6.12.100-1) and inspected
`boot/config-6.12.94+deb13-armmp`:

```
# CONFIG_ARCH_ZYNQ is not set
# CONFIG_MACB is not set
# CONFIG_XILINX_XADC is not set
# CONFIG_MMC_SDHCI_OF_ARASAN is not set
# CONFIG_SERIAL_XILINX_PS_UART is not set
```

The package ships **972 DTBs — zero zynq**. Enabled platforms: Virt,
ASPEED, BCM2835, Exynos, Highbank, i.MX, Meson, MMP, Mvebu, OMAP, Rockchip,
**Intel SoCFPGA** (Altera Cyclone V — the *other* ARM+FPGA SoC), STM32,
Sunxi, Tegra, Vexpress, VT8500, WM8850. Xilinx Zynq is simply not among them.

Community corroboration: `ikwzm/FPGA-SoC-Debian13` (Debian 13 images for
ZYBO / PYNQ-Z1 / DE10-Nano) ships a **custom-built** kernel
(`6.12.55-armv7-fpga`), not the Debian package — the Debian-on-Zynq
ecosystem builds its own kernels precisely because Debian's stock armhf
kernel doesn't cover Zynq.

## 3. External finding #2: what Debian's config *would* give us

From the same config — this is the realistic "full-featured" target matrix
(=m means module; Debian runs everything through an initramfs):

NETFILTER=y, NF_TABLES=m (+full xtables/iptables), AppArmor=y, AUDIT=y,
FANOTIFY=y, BPF_SYSCALL=y, MEMCG=y, FUSE=y, EXT4/XFS/Btrfs/NFS/CIFS=m,
brcmfmac/rtl8xxxu/mt7601u/ath9k/htc/rt2x00/rtlwifi all =m, USB serial
ch341/cp210x/ftdi =m, USB CDC-NCM/ACM =m, SND (incl. USB audio, ASoC) =m,
BT_HCIBTUSB=m, WireGuard=m, zram=m, NVMEM=y, PPS=y + PPS_CLIENT_GPIO=m,
USB_CHIPIDEA=m, CMA=y (**size 16 MB** — we need 64 for zynqsdr DMA),
MODULE_SIG=y but **not SIG_FORCE** (third-party modules load fine),
modules xz-compressed, `MODVERSIONS=y`.

Notable deviations from our needs (small override fragment handles all):
`CMA_SIZE_MBYTES=16` (we need 64), `PSTORE` off (our only blind-debug
channel — we need =y), `DEVTMPFS_MOUNT` off (initramfs assumed), default
governor schedutil (we pinned ondemand; websdr reads `scaling_cur_freq`),
`IKCONFIG` off, no fpga-manager for armmp at all (moot — we disable
zynq-fpga anyway). Kernel image format: standard ARM zImage — satisfies
the SSBL gzip-zImage contract.

## 4. External finding #3: packaging mechanics (pinned-deb scheme is sound)

- Trixie armhf kernel: upstream **6.12 LTS**; binary package name carries
  the ABI: `linux-image-6.12.94+deb13-armmp`, Debian revision `6.12.94-1`;
  metapackage `linux-image-armmp` Depends on the exact ABI package.
  Security updates keep the ABI name stable; an ABI bump produces a **new
  package name** (old kernel stays installed alongside).
- Therefore a module deb can hard-pin with
  `Depends: linux-image-6.12.94+deb13-armmp` — apt then refuses to install
  it on a mismatched kernel, which is exactly the desired behaviour for the
  no-DKMS strategy. On each ABI bump the module deb is rebuilt on the host
  against `linux-headers-<abi>-armmp` (exists in the archive, cross-builds
  with `ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-`).
- `linux-source-6.12` and `linux-config-6.12` are apt-installable — the
  full Debian kernel source + the exact config hierarchy used to build
  their packages, which is the raw material for Option 2.
- `MODULE_SIG` without `SIG_FORCE` + no secure boot on this platform ⇒
  unsigned third-party modules load without ceremony.

## 5. External finding #4: firmware packages (trixie)

Requires the `non-free-firmware` archive component in `sources.list`
(alongside `main contrib non-free`). Installed sizes (trixie 20250410-2):

| Package | Size | Need |
|---|---|---|
| firmware-linux-free (main) | 0.1 MB | yes (free misc) |
| firmware-brcm80211 | 18 MB | yes (brcmfmac USB/SDIO WiFi) |
| firmware-realtek | 19 MB | yes (RTL dongles + RTL PHY firmware) |
| firmware-misc-nonfree | 13 MB | yes (mt7601u, ralink, misc USB WiFi) |
| firmware-libertas | 11 MB | optional (old Marvell USB) |
| firmware-atheros | 97 MB | optional (ath9k dongles) |
| firmware-mediatek | 46 MB | optional (newer MT USB WiFi/BT) |
| firmware-iwlwifi | 114 MB | **no** (Intel PCIe only) |

Recommended baseline ≈ **50 MB**: linux-free + brcm80211 + realtek +
misc-nonfree. Add atheros/mediatek (+143 MB) if broad dongle coverage is
wanted — the ext4 card has the room.

---

## 6. Option analysis

### Option 1 — stock Debian kernel package + pinned driver debs → **NOT VIABLE today**

Blocker is §2: without `CONFIG_ARCH_ZYNQ` the stock kernel cannot boot the
board at all — no UART, no GEM, no SDHCI, no DTB. This is not something we
can patch downstream; the package is what it is.

(For the record, the secondary issues would all have been tractable: the
pinned kmod-deb mechanism is verified sound (§4); the
fpga-manager-vs-`/dev/xdevcfg` conflict is one modprobe blacklist line;
Debian's initramfs-mandatory flow conflicts with our initrd-less boot.bin
but the initrd size is our bootargs to set; per-update boot.bin repacking
needs a hook or the M4 U-Boot + FAT flow. None of this matters while §2
stands.)

**Variant 1b (long-term, optional):** file a wishlist bug against
`src:linux` asking to enable `ARCH_ZYNQ` + MACB/XADC/ARASAN-SDHCI/PS-UART/
GPIO-ZYNQ in armmp — precedent exists (`ARCH_INTEL_SOCFPGA` is enabled).
Timeline unknown, maintenance justification required, and even then
`FPGA_MGR_ZYNQ_FPGA` would likely come enabled and need blacklisting for
xdevcfg. Worth filing as upstream goodwill; not a plan.

### Option 2 — our own kernel .deb on Debian's 6.12 source + Debian config → **VIABLE; recommended target architecture**

- Base: `linux-source-6.12` (Debian-patched 6.12 LTS) or mainline 6.12.y.
  Config: Debian's armmp config + a small tracked fragment:
  `ARCH_ZYNQ=y`, our two drivers, `CMA_SIZE_MBYTES=64`, `PSTORE(_RAM)=y`,
  `DEVTMPFS_MOUNT=y`, governor ondemand, `FPGA_MGR_ZYNQ_FPGA=n`, and —
  if we keep the initrd-less flow — flip ~8 symbols to =y (SDHCI_ARASAN,
  EXT4, MACB, PS_UART, REALTEK_PHY, CHIPIDEA+PHY, NVMEM, OVERLAY/SQUASHFS).
- Platform risk is low: Zynq-7000 support is **fully mainline** (MACB,
  arasan SDHCI, cadence I2C/WDT, XADC, gpio/pinctrl/clk/SLCR). The xlnx
  tree adds nothing we use — proven by the fact that both "Xilinx" drivers
  we depend on are already self-ported fossils/rewrites.
- Driver port 6.6→6.12: both drivers are small char/platform drivers; the
  6.6 port already absorbed the modern API shape (1-arg `class_create`,
  regmap SLCR). Expect touch-ups, not a rewrite. Our `config/web888.dts`
  compiles standalone; minor dtsi drift to check.
- Build stays host-side and fast; package with `make bindeb-pkg` →
  linux-image + linux-headers debs installed by the image build; boot.bin
  repack pipeline unchanged. Update cadence: track Debian point releases,
  rebuild on host, ship new image/deb. No on-device compiling anywhere.
- Wins: a full-featured config curated by the Debian kernel team (the
  actual thing we wanted from Debian), a security-tracked LTS base, and a
  6.6→6.12 bump that better matches trixie userspace.

### Option 3 — current xlnx 6.6 tree + Debian-derived config → **VIABLE; recommended immediate step**

- Keep the hardware-proven tree; replace the hand-grown feature surface by
  importing Debian's armmp config onto it (whole-config + our fragment, or
  a large curated fragment — mechanics identical to Option 2's config work,
  zero platform risk).
- Immediately unblocks step 3.5 (netfilter for iptables/nft), USB serial,
  USB WiFi/BT, FUSE/exFAT, AppArmor, and the general "crippled kernel"
  complaint. Firmware packages land regardless of option.
- Respects the project's one-variable-at-a-time rule (recorded
  for exactly this kernel switch): same version, same tree, config only —
  regression comparison against the known-good build stays valid.
- Costs: still 6.6-based; the xlnx branch lags upstream (6.6.80 vs
  6.6.110+) — consider a branch bump or rebasing the fragment onto
  mainline `linux-6.6.y` in the same pass; security tracking stays manual
  until Option 2 lands.
- Bonus: ~95 % of the config work done here carries straight into Option 2.

---

## 7. Recommendation

1. **Now: Option 3.** Regenerate the kernel config from Debian's armmp config
   + our existing fragment (keep all current built-ins, initrd-less flow,
   `-web888` localversion), and add the firmware package set (§5) to the
   image with `non-free-firmware` enabled. This closes the user's actual
   complaint with the least risk and unblocks step 3.5.
2. **Next milestone (after step 3.5/4 are stable on hardware): Option 2.**
   Same config, re-based onto Debian `linux-source-6.12`; port the two
   drivers; QEMU gate + blind-boot gate. This is the durable answer to
   "apt-class maintenance for an internet-facing SDR" that motivated the
   earlier TODO item — updated by this research (that item assumed
   Debian's stock kernel was usable and DKMS was the delivery mechanism;
   both assumptions are now superseded).
3. **Option 1: park it.** Optionally file the upstream wishlist bug (1b);
   if Debian ever enables Zynq in armmp, Option 1 becomes strictly superior
   and the pinned kmod-deb design from §4 drops in unchanged.
4. **Firmware: option-independent** — do it in the same pass as Option 3.

### Pre-execution checklist (completed during the Option 2 implementation)

- [x] Generate candidate config (Debian armmp + fragment) on the current
      tree; `olddefconfig` resolve; diff-review the net delta vs today
      (`config/kernel-web888-6.12.fragment`)
- [x] Confirm every current `=y` boot-critical symbol survives (extend the
      build-kernel-6.12.sh verification list)
- [x] Rootfs budget: full Debian-style /lib/modules ≈ 100–200 MB xz — fine
- [x] Firmware: sources.list `non-free-firmware` + 4 packages (§5)
- [x] QEMU gate, blind boot, netfilter acceptance — all completed
- [x] (Option 2 only) drivers compile vs 6.12 headers; web888.dts vs 6.12
      dtsi; initrd-less vs initramfs-tools decision; update TODO item

## 8. Addendum: Debian-on-Zynq community projects — maintenance & trust

Question: how well maintained are the Debian-on-Zynq community projects
(ikwzm/FPGA-SoC-Debian13 et al.), can they be trusted, can we use them
directly? Verified against the GitHub repos.

**Who.** Ichiro Kawazome (@ikwzm), solo maintainer. `FPGA-SoC-Linux`
(since 2016, 172★, 57 forks), `ZynqMP-FPGA-Linux` (135★), plus the
out-of-tree drivers `udmabuf` / `fclkcfg` / `dtbocfg` — udmabuf is widely
used well beyond his own repos. A decade-long, still-active track record
in exactly this niche.

**Structure & cadence.** Per-Debian-release image repos (Debian12 v7.0.0
@2024-09, **Debian13 v1.0.0 @2025-10-30 — tagged as a prerelease**, repo
static since: 4 commits total) + per-kernel-series build repos
(`FPGA-SoC-Linux-Kernel-{6.1,6.6,6.12,6.18}`). Kernel snapshots are
per-image, not tracked: the 6.12 build is **6.12.55** (2025-10) while
trixie's security pocket is at 6.12.100 — **no continuous point-release /
security tracking**. Maintenance is real but hobbyist-grade: one person,
bursts around each Debian release.

**Engineering quality (trust as reference: YES).** Everything needed to
reproduce is published: `armv7_fpga_defconfig`, the resolved
`config-6.12.55-armv7-fpga-2`, exactly **three small patches** (Makefile
LOCALVERSION, zynq/socfpga DTS tweaks, a USB-ULPI fix for PYNQ-Z1), build
docs, scripts, and the resulting debs (`linux-image` 11.7 MB,
`linux-headers` 11.4 MB, `linux-libc-dev`) built with the standard
`bindeb-pkg` flow. Clean, auditable, minimal-delta work.

**Config character (direct use: NO).** His kernel is a *lean maker
kernel*, not a full-featured distro kernel — **1631 enabled symbols**
(≈ our current 1243, vs Debian armmp 6117). Verified in his shipped
config: Zynq core all =y (MACB/XADC/ARASAN/PS-UART), EXT4=y, initrd-less,
gzip zImage, IKCONFIG=y, some USB WiFi =m; **but `NETFILTER` is entirely
OFF**, and no zram/PSTORE/PPS/cpufreq-dt/FUSE/AppArmor/USB-serial/sound.
Two hard blockers for us specifically:

1. `CONFIG_FPGA_MGR_ZYNQ_FPGA=y` (**built-in**) + bridges/regions/DT
   overlays =y — his whole stack loads bitstreams via fpga-manager.
   Built-in means it **cannot be blacklisted**: it claims the
   `xlnx,zynq-devcfg-1.0` compatible first and `/dev/xdevcfg` is dead.
   Directly incompatible with our websdr contract.
2. NETFILTER off — the exact gap we're trying to close (step 3.5
   iptables/nft). Adopting his kernel would keep our core complaint.

Add the single-person supply chain, his own explicit disclaimer
("not official… modified to my liking, please handle with care"), the
prerelease tag, and no update stream: **do not ship his binaries/debs on
an internet-facing device.**

**Verdict.**
- Trust as **documentation and reference**: yes — highest-quality
  existing proof that **mainline 6.12 + Zynq-7010 boots initrd-less**
  (ZYBO is the same silicon as the Web-888), with a working defconfig,
  minimal patch set, and a standard deb packaging flow. Directly de-risks
  Option 2's 6.12 port (borrow: defconfig baseline, patch list to check,
  build-doc flow).
- Trust as a **kernel/binary vendor**: no — rebuild from source with our
  own config instead. Nothing he ships can be used as-is anyway (blockers
  above), and Option 2/3 give us a strictly more complete feature set with
  a security-tracked source base.

## Evidence appendix

- `linux-image-6.12.94+deb13-armmp_6.12.94-1_armhf.deb` (56,391,568 B)
  from `deb.debian.org/debian/pool/main/l/linux/` → config + 972-DTB list
  inspected (`.tmp/kernel-research/`).
- `dists/trixie/main/binary-armhf/Packages.xz` → package/ABI/headers/source
  metadata; `dists/trixie/non-free-firmware/binary-armhf/Packages.xz` →
  firmware versions + installed sizes.
- packages.debian.org: trixie `linux-image-armmp` = 6.12.94-1 (main),
  6.12.100-1 (security), 7.1.3-1~bpo13+1 (backports).
- `github.com/ikwzm/FPGA-SoC-Debian13` — custom-kernel evidence.
- Current-kernel facts: `work/linux-xlnx/.config` (6.6.80-web888+),
  `scripts/build-kernel.sh`, `config/kernel-web888.fragment`,
  `docs/research/hardware-facts.md`, `docs/research/bootbin-repack-spec.md`, `docs/dev/TODO.md`.
