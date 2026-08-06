# Stock Web-888 Kernel Analysis

> **Status**: Analysis complete — based on direct SSH inspection of a stock-firmware device (two sessions), local binary analysis, and extensive public-source research  

---

## 1. Executive Summary

The Web-888 stock firmware runs a **custom/vendor kernel** named `6.6.110-xilinx`. It is **not** a mainline Linux kernel, nor is it an Alpine Linux distribution kernel. The kernel was cross-compiled on a Debian 12 host by a developer (`junsu@HOMEPC`) using the `arm-linux-gnueabihf` toolchain. It is almost certainly based on the **Xilinx `linux-xlnx` repository** (6.6 LTS branch) with additional vendor patches applied to reach 6.6.110.

**Key takeaways:**
- The kernel source tree is **not publicly released** by the vendor. No published source, config, or DTS accompanies the distributed binaries — a GPL violation.
- The running kernel **does not embed its `.config`** (`CONFIG_IKCONFIG` is disabled, zero `IKCFG_ST` markers in the binary), so the exact configuration cannot be retrieved directly.
- The kernel image, device tree, FSBL, and U-Boot are all packed into a single `boot.bin` file (9,056,768 bytes, dated Oct 18 2025).
- The FSBL is a **custom Red Pitaya-derived bootloader** that configures the Si5351 clock chip at boot and explicitly does NOT load the FPGA bitstream.
- The kernel includes **Web-888-specific built-in drivers** (`zynqsdr`, `ad8370`) that are absent from mainline and from `linux-xlnx`.
- **FPGA bitstreams** were built with **Vivado 2023.1** on April 13, 2025, targeting `7z010clg400` — confirming the ecosystem doc's earlier claim.
- **WiFi support** was eventually added: CFG80211/MAC80211 are loadable modules, with dongle drivers (ath9k, brcmfmac, mt76, rt2800usb, rtl8xxxu) available.
- **Critical discovery**: `iliasam/OpenZynqSDRApp` contains an open-source kernel driver (`sdrdma_main.c`) that is **architecturally identical** to the closed Web-888 `zynqsdr` driver — same ioctl magic (`'Z'`), same command numbers, and same DMA-based design. This is the closest public analog to the proprietary driver.
- The `/dev/zynqsdr` source is **intentionally withheld** by the vendor (Howard Su / RaspSDR), citing "hardware authentication / anti-clone logic" embedded in the driver.
- **Firmware evolution**: kernel versions 6.6.58 -> 6.6.71 -> 6.6.110 have been shipped over the product's lifetime. Updates are distributed via full ZIP (OS+firmware+server) or OTA auto-update (firmware+server only).

---

## 2. Kernel Identity (from Live System)

### 2.1 Version String
```
Linux version 6.6.110-xilinx (junsu@HOMEPC) (arm-linux-gnueabihf-gcc (Debian 12.2.0-14) 12.2.0, GNU ld (GNU Binutils for Debian) 2.40) #1 SMP PREEMPT Sat Oct 18 23:11:49 CST 2025
```

### 2.2 Build Metadata
| Attribute | Value |
|-----------|-------|
| **Version** | `6.6.110-xilinx` |
| **Local version suffix** | `-xilinx` |
| **Builder** | `junsu@HOMEPC` |
| **Build date** | `Sat Oct 18 23:11:49 CST 2025` (CST = China Standard Time, UTC+8) |
| **Compiler** | `arm-linux-gnueabihf-gcc (Debian 12.2.0-14) 12.2.0` |
| **Linker** | `GNU ld (GNU Binutils for Debian) 2.40` |
| **Architecture** | `armv7l` |
| **SMP** | Yes (`SMP PREEMPT`) |
| **Build #** | `#1` (first build) |
| **Vermagic** | `6.6.110-xilinx SMP preempt mod_unload modversions ARMv7 p2v8` |

### 2.3 Provenance Indicators

The build string proves this is a **personal build on the author's home PC** (`junsu@HOMEPC`), using Debian's GCC 12.2.0 cross-toolchain. This is **NOT** a PetaLinux or Yocto build — no PetaLinux markers exist anywhere in `/proc/kallsyms` (no `petalinux` strings, no PetaLinux-specific drivers).

### 2.4 Why This Is NOT Mainline
- Mainline Linux 6.6.110 exists, but it would report `6.6.110` without a `-xilinx` suffix.
- The `LOCALVERSION` string `-xilinx` is custom (Yocto `LINUX_VERSION_EXTENSION="-xilinx"` or manual `CONFIG_LOCALVERSION`).
- `LOCALVERSION_AUTO=n` — no git hash appended to the version string.
- The kernel was built with a **Debian cross-compiler**, not the Alpine/musl native toolchain.
- The kernel contains **vendor-specific platform drivers** (`zynqsdr`, `ad8370_driver`) that are not in mainline Linux.
- Alpine Linux ships **no Zynq-7000 kernel**, so the author definitely compiled his own kernel regardless.

---

## 3. Kernel Provenance Analysis

### 3.1 Xilinx `linux-xlnx` Branch Policy

The Xilinx/AMD kernel repository at `https://github.com/Xilinx/linux-xlnx` uses the following branch and tag conventions for the 6.6 LTS line:

| Branch / Tag | Description |
|--------------|-------------|
| `xlnx_rebase_v6.6_LTS` | Working branch; continuously rebased on upstream 6.6 stable |
| `xlnx_rebase_v6.6_LTS_2024.1` | Tag corresponding to PetaLinux 2024.1 (6.6.40 base) |
| `xlnx_rebase_v6.6_LTS_2024.2` | Tag corresponding to PetaLinux 2024.2 (6.6.40 base) |
| `xlnx_rebase_v6.6_LTS_merge_6.6.x` | LTS merge points (e.g., `merge_6.6.80`) |

**Key fact**: Upstream Linux 6.6.110 was released October 6, 2025 by Greg KH. **No public Xilinx merge tag exists for 6.6.110** — the latest public merge tag in the 6.6 LTS line is `v6.6.80` (March 2025).

### 3.2 PetaLinux Version Mapping

| PetaLinux Version | Kernel Base | Notes |
|-------------------|-------------|-------|
| 2023.2 | 6.1 | Pre-6.6 era |
| 2024.1 | 6.6 (6.6.40 base) | Tag: `xlnx_rebase_v6.6_LTS_2024.1` |
| 2024.2 | 6.6 (6.6.40 base) | Tag: `xlnx_rebase_v6.6_LTS_2024.2` |
| 2025.x | 6.12 | Moved to 6.12 base |

The stock kernel at 6.6.110 does **not** match any published PetaLinux tag, confirming it is a custom build, not a PetaLinux release.

### 3.3 Provenance Assessment

**Assessed likelihood** (moderate-high confidence, given the author's demonstrated skill level):

1. Cloned `Xilinx/linux-xlnx` branch `xlnx_rebase_v6.6_LTS` (or manually bumped `SUBLEVEL` to 110).
2. Based the `.config` on `xilinx_zynq_defconfig`.
3. Added the `zynqsdr` and `ad8370` vendor drivers as built-in platform drivers.
4. Added WiFi module support (CFG80211, MAC80211, dongle drivers).
5. Added Alpine-specific requirements (squashfs, loop, overlayfs as built-ins).
6. Set `CONFIG_LOCALVERSION="-xilinx"`, `LOCALVERSION_AUTO=n`.
7. Cross-compiled with Debian's `arm-linux-gnueabihf-gcc 12.2.0` on a personal machine.

### 3.4 Evidence Linking to Xilinx Tree
- The kernel enables many `CONFIG_XILINX_*` drivers (see Section 8).
- Rich `xilinx_*` and `zynq_*` symbol sets in `/proc/kallsyms` (146+ matching symbols) confirm a `linux-xlnx` source tree.
- The Zynq-7000 SoC support in Linux 6.6 is maintained primarily by Xilinx.
- The boot image format (`boot.bin`) and FSBL are Xilinx proprietary tooling outputs.
- The DMA, EMAC, UART, and I2C drivers are all Xilinx/Cadence IP bindings typical of `linux-xlnx`.

### 3.5 Absence of Public Vendor Source
- **No `RaspSDR/linux` or `RaspSDR/kernel` repository** exists on GitHub that contains the `zynqsdr` or `ad8370` driver source.
- GitHub searches for `"rx888,zynqsdr"`, `"zynqsdr_driver_init"`, and `"ad8370_driver"` return **zero results**.
- The `RaspSDR/server` repository contains only userspace code.
- Therefore, the stock kernel is a **closed vendor build** — the exact source tree and patch set for the vendor-specific drivers are not publicly available.

---

## 4. Boot Chain

### 4.1 SD Card Layout

The stock firmware uses a **single FAT32 partition** spanning the entire SD card:

```
Disk /dev/mmcblk0: 15 GB, 15931539456 bytes, 31116288 sectors
Device       Boot StartCHS    EndCHS        StartLBA     EndLBA    Sectors  Size  Id Type
/dev/mmcblk0p1    4,4,1       1023,254,2        2048   31115263   31113216 14.8G  c Win95 FAT32 (LBA)
```

No separate boot/root partitions. The FAT32 partition contains everything.

### 4.2 Boot Partition Contents

```
/media/mmcblk0p1/
├── boot.bin               9,056,768 bytes  Oct 18 2025  (FSBL + U-Boot + DTB + kernel + initramfs)
├── modloop               26,255,360 bytes  Jun  9 2025  (squashfs kernel modules)
├── websdr.bin             7,124,020 bytes  Jun  9 2025  (WebSDR application)
├── websdr_hf.bit          1,244,764 bytes  Jun  9 2025  (HF FPGA bitstream)
├── websdr_vhf.bit         1,249,832 bytes  Jun  9 2025  (VHF FPGA bitstream)
├── dumphfdl               2,601,800 bytes  Jun  9 2025  (HFDL decoder)
├── libfdk-aac.so          1,421,708 bytes  Jun  9 2025  (AAC library)
├── libliquid.so           2,660,680 bytes  Jun  9 2025  (liquid-dsp library)
├── web-888.apkovl.tar.gz      9,950 bytes  Jun  9 2025  (Alpine config overlay)
├── config/               (directory — SDR configuration)
├── cache/                (directory — APK package cache)
└── wifi/                 (directory — WiFi scripts)
```

**No separate `zImage`, `uImage`, `devicetree.dtb`, or `uEnv.txt` files** — everything is embedded in `boot.bin`. This contrasts with the ZIP-download firmware-analysis view, which shows separate files; the running device packs them into a single `boot.bin`.

### 4.3 Filesystem Mounts

```
/dev/mmcblk0p1 on /media/mmcblk0p1 type vfat (ro,relatime,fmask=0022,dmask=0022,...)
tmpfs on / type tmpfs (rw,relatime,mode=755)
tmpfs on /run type tmpfs (rw,nosuid,nodev,size=101896k,...)
/dev/loop0 on /.modloop type squashfs (ro,relatime,errors=continue)
```

**Alpine diskless mode:**
- Root filesystem: tmpfs (RAM-based)
- Modloop: squashfs via loop device from `/media/mmcblk0p1/modloop`
- Boot media: FAT32 partition mounted read-only at `/media/mmcblk0p1`
- Config overlay: `web-888.apkovl.tar.gz` loaded at boot

### 4.4 FSBL (Custom Red Pitaya-Derived Bootloader)

The FSBL (First Stage Boot Loader) embedded in `boot.bin` is a **custom Red Pitaya-derived bootloader**, NOT the standard Xilinx FSBL. Strings analysis reveals:

```
PS7 initialization successful
PS7 init Data Corrupted
PS7 init mask poll timeout
Mask Poll failed for DDR Init
Mask Poll failed for PLL Init
Mask Poll failed for DMA done bit
FSBL Warning !!!Bitstream not loaded into PL
User RedPitaya Bootloader start
Bootloader Si5351 config
refclock=
Bootloader config success,boot to Linux
```

Key characteristics:
- Configures the **Si5351 clock generator** before booting Linux (string: `Bootloader Si5351 config`)
- Explicitly does **NOT** load the FPGA bitstream (string: `FSBL Warning !!!Bitstream not loaded into PL`)
- FPGA bitstreams are loaded at runtime by `websdr.bin`, not by FSBL
- Contains standard Xilinx standalone library driver source files compiled in: `xdevcfg.c`, `xemacps.c`, `xiicps.c`, `xsdps.c`, etc.

### 4.5 U-Boot

U-Boot is present in `boot.bin`:
- `u-boot,dm-pre-reloc` string found
- `done, booting the kernel.` — U-Boot boot message
- **No recoverable U-Boot version string** found in the binary

### 4.6 Kernel Command Line

```
console=ttyPS0,115200 earlycon earlyprintk initrd=0x3000000,4M modloop=modloop
```

- `initrd=0x3000000,4M` — initramfs loaded at 48MB offset, 4MB size
- `modloop=modloop` — Alpine modloop from file named "modloop" on boot media
- CMA: 16 MiB reserved at `0x1f000000` (from dmesg: `cma: Reserved 16 MiB at 0x1f000000 on node -1`)

### 4.7 Early Boot Sequence

```
Booting Linux on physical CPU 0x0
Linux version 6.6.110-xilinx (junsu@HOMEPC) ...
CPU: ARMv7 Processor [413fc090] revision 0 (ARMv7), cr=18c5387d
OF: fdt: Machine model: xlnx,zynq-7000
earlycon: cdns0 at MMIO 0xe0000000 (options '115200n8')
cma: Reserved 16 MiB at 0x1f000000 on node -1
Memory: 487972K/524288K available (7168K kernel code, 233K rwdata, 1608K rodata, 1024K init, 144K bss, 19932K reserved, 16384K cma-reserved, 0K highmem)
SMP: Total of 2 processors activated (666.66 BogoMIPS).
```

Alpine init sequence:
```
Alpine Init 3.11.1-r0
Loading boot drivers...
Loading boot drivers: ok.
Mounting boot media...
Mounting boot media: ok.
Loading user settings from /media/mmcblk0p1/web-888.apkovl.tar.gz...
Loading user settings from /media/mmcblk0p1/web-888.apkovl.tar.gz: ok.
Installing packages to root filesystem...
Installing packages to root filesystem: ok.
```

---

## 5. Boot Image Structure

### 5.1 No Separate `/boot` Partition Files

On the stock firmware, the FAT32 partition (`/media/mmcblk0p1`) does **not** contain separate `uImage`, `zImage`, or `devicetree.dtb` files. Instead, everything is packed into a single Xilinx Boot Image:

```
/media/mmcblk0p1/boot.bin   (9,056,768 bytes, dated Oct 18 2025)
/media/mmcblk0p1/modloop    (26,255,360 bytes)
```

### 5.2 boot.bin Layout (binwalk Analysis)

`boot.bin` (9,056,768 bytes) was analyzed with `binwalk` and gzip-stream extraction. The confirmed layout:

| Component | Offset | Format | Size (compressed) | Size (decompressed) | Notes |
|-----------|--------|--------|---------------------|---------------------|-------|
| **BootROM Header / FSBL** | 0x0000 | Xilinx Boot Image | — | — | Custom Red Pitaya-derived FSBL |
| **Device Tree Blob** | 0x1D780 | Raw FDT | 12,455 bytes | — | Decompiles cleanly with `dtc` |
| **Linux Kernel Image** | 0x278A8 | gzip compressed | 4,700,435 bytes | 11,740,160 bytes | Decompresses to the 6.6.110-xilinx kernel |
| **Initramfs (initrd)** | 0x4A3200 | gzip -> cpio | 3,894,120 bytes | 6,503,936 bytes | Standard Alpine initramfs |

> **Note**: The extraction was performed by scanning for gzip magic signatures (`1f 8b 08`) inside `boot.bin` and decompressing the streams. The kernel image at offset `0x278A8` decompresses to the actual `6.6.110-xilinx` kernel binary.

### 5.3 FSBL Strings in boot.bin

The following significant strings were found in `boot.bin`:

```
User RedPitaya Bootloader start
Bootloader Si5351 config
refclock=
Bootloader config success,boot to Linux
FSBL Warning !!!Bitstream not loaded into PL
```

These confirm:
1. The FSBL is derived from the **Red Pitaya** bootloader project.
2. The Si5351 clock chip is configured **during boot**, before Linux starts.
3. The FPGA bitstream is **not loaded by FSBL** — it is loaded later at runtime by `websdr.bin`.

### 5.4 Initramfs Analysis
The initramfs extracted from `boot.bin` is a standard Alpine Linux initial ramdisk containing:
- `busybox`, `kmod`, `apk`
- `nlplug-findfs` (Alpine init helper)
- `libcryptsetup`, `libdevmapper`
- No kernel build artifacts, no `.config`, no source headers
- **No `zynqsdr` references** in the initrd (confirming the driver is built into the kernel image, not loaded from the rootfs).

---

## 6. Device Tree Analysis

The **Device Tree Blob (DTB)** was successfully extracted from `boot.bin` at offset `0x1d780` (12,455 bytes) and decompiled with `dtc`. Key findings:

### 6.1 Platform Identity
| Property | Value |
|----------|-------|
| **Root compatible** | `"xlnx,zynq-7000"` |
| **Model** | (empty string) |
| **CPU** | ARM Cortex-A9 dual-core |
| **Memory** | **512 MB** (`reg = <0x00 0x20000000>`) — confirmed |

### 6.2 Boot Arguments (`chosen` node)
```dts
chosen {
    bootargs = "console=ttyPS0,115200 earlycon earlyprintk initrd=0x3000000,4M modloop=modloop";
    stdout-path = "serial0:115200n8";
};
```

### 6.3 The `zynqsdr` Device Tree Node
This is the **critical Web-888-specific node** that binds the proprietary kernel driver:

```dts
zynqsdr {
    compatible = "rx888,zynqsdr";
    interrupt-parent = <0x04>;  /* GIC */
    interrupts = <0x00 0x1d 0x01   /* SPI 29, edge-rising */
                  0x00 0x1e 0x01   /* SPI 30, edge-rising */
                  0x00 0x1f 0x01   /* SPI 31, edge-rising */
                  0x00 0x20 0x01>; /* SPI 32, edge-rising */
    gpios = <0x0b 0x0a 0x01   /* MIO 10, active-high */
             0x0b 0x0d 0x01   /* MIO 13, active-high */
             0x0b 0x0c 0x01   /* MIO 12, active-high */
             0x0b 0x0b 0x01   /* MIO 11, active-high */
             0x0b 0x31 0x01>; /* MIO 49, active-high */
};
```

**Interpretation:**
- The driver binds to the compatible string `"rx888,zynqsdr"`.
- It uses **4 interrupts** (SPI 29-32) — likely for RX DMA, Waterfall-0 DMA, Waterfall-1 DMA, and PPS/1PPS.
- It uses **5 GPIOs** on `&gpio0` (MIO 10, 11, 12, 13, 49). The functions of these GPIOs are not documented in the DT, but they likely control antenna switching, clock selection, or mode toggles.

### 6.4 Other Notable Nodes
- **MAC address** stored in I2C EEPROM at `0x50` (`macaddr@10`)
- **PPS input** on GPIO MIO 54 (`0x36`) via `pps-gpio`
- **USB PHY reset** on GPIO MIO 48 (`0x30`)
- **Ethernet** on GEM0 (`e000b000`) with RGMII-ID PHY at address 1
- **fpga-full** node with `compatible = "fpga-region"` and phandle to devcfg
- **phy0** node: `compatible = "ulpi-phy"`, `view-port = 0xe0002000` (USB ULPI)

### 6.5 AXI Bus Nodes (Complete List)

```
adc@f8007100          (XADC)
cache-controller@f8f02000
can@e0008000          (CAN0)
can@e0009000          (CAN1)
devcfg@f8007000       (Device Config)
dma-controller@f8003000
efuse@f800d000
etb@f8801000          (CoreSight ETB)
ethernet@e000b000     (GEM0 — RTL8211E)
ethernet@e000c000     (GEM1)
funnel@f8804000       (CoreSight Funnel)
gpio@e000a000
i2c@e0004000          (I2C0 — EEPROM, Si5351)
i2c@e0005000          (I2C1)
interrupt-controller@f8f01000
memory-controller@e000e000
memory-controller@f8006000
mmc@e0100000          (SD0)
mmc@e0101000          (SD1)
ptm@f889c000          (CoreSight PTM0)
ptm@f889d000          (CoreSight PTM1)
serial@e0000000       (UART0 — console ttyPS0)
serial@e0001000       (UART1 — GPS ttyPS1)
slcr@f8000000         (SLCR)
spi@e0006000          (SPI0)
spi@e0007000          (SPI1)
spi@e000d000          (QSPI)
sram@fffc0000         (OCM)
timer@f8001000
timer@f8002000
timer@f8f00200
timer@f8f00600
tpiu@f8803000         (CoreSight TPIU)
usb@e0002000          (USB0)
usb@e0003000          (USB1)
watchdog@f8005000
```

---

## 7. Kernel Configuration Status

### 7.1 Embedded Config: NOT AVAILABLE
The stock kernel was built **without** `CONFIG_IKCONFIG` and `CONFIG_IKCONFIG_PROC`. Running `extract-ikconfig` on the extracted kernel image returns:

```
extract-ikconfig: Cannot find kernel config.
```

Likewise, `/proc/config.gz` does not exist on the running system. **Zero `IKCFG_ST` markers** were found in the extracted kernel image, definitively confirming `CONFIG_IKCONFIG` was disabled at build time.

### 7.2 Exact `.config` Is Lost
Because:
- `CONFIG_IKCONFIG` is disabled (confirmed: zero `IKCFG_ST` markers),
- No `config-*` file exists on the SD card,
- No kernel headers package is installed,
- No `/usr/src/linux` or `/lib/modules/$(uname -r)/build` symlink exists,

...the **exact `.config` used to build the stock kernel cannot be recovered** from the device or the binary. The kernel config is definitively unrecoverable.

---

## 8. Inferable Kernel Configuration

Despite the missing `.config`, we can reconstruct a large number of configuration options from four independent sources:

1. **`/lib/modules/$(uname -r)/modules.builtin`** (181 entries)
2. **`modloop` squashfs** (145 loadable `.ko` modules)
3. **Kernel command line + runtime behavior**
4. **Symbol table (`/proc/kallsyms`)**

### 8.1 Architecture & Platform
| Inferred Option | Evidence |
|-----------------|----------|
| `CONFIG_ARCH_ZYNQ=y` | Running on Zynq-7010 |
| `CONFIG_SMP=y` | `SMP` in version string, dual-core A9 |
| `CONFIG_PREEMPT=y` | `PREEMPT` in version string |
| `CONFIG_PREEMPT_RCU=y` | `rcu: Preemptible hierarchical RCU` in dmesg |
| `CONFIG_ARM_LPAE=y` | Likely enabled for DMA above 32-bit addressing |
| `CONFIG_HIGHMEM=y` | 512MB RAM requires highmem on some Zynq configs |

### 8.2 Boot & Init
| Inferred Option | Evidence |
|-----------------|----------|
| `CONFIG_BLK_DEV_INITRD=y` | `initrd=0x3000000,4M` in cmdline |
| `CONFIG_INITRAMFS_SOURCE=""` or external initrd | Initrd is loaded by U-Boot, not built-in |
| `CONFIG_CMDLINE="console=ttyPS0,115200 earlycon earlyprintk"` | `/proc/cmdline` shows these options |
| `CONFIG_OF=y`, `CONFIG_OF_FLATTREE=y` | Device tree is required for Zynq |
| `CONFIG_CMA=y` | `cma: Reserved 16 MiB at 0x1f000000` in dmesg |

### 8.3 Device Drivers — Built-In (`modules.builtin`)

The following drivers are compiled **into the kernel image** (not as loadable modules):

| Driver | Path in `modules.builtin` | Significance |
|--------|---------------------------|--------------|
| **zynqsdr** | `kernel/drivers/char/ad8370_driver.ko` | **Web-888 custom SDR DMA driver** — `ad8370_driver.ko` is the SOURCE-FILE name of the driver that registers as `zynqsdr`; disassembly CONFIRMS its probe prints "ad8370 loaded". No separate ad8370 driver exists (see [zynqsdr-port-notes.md](zynqsdr-port-notes.md) §12) |
| **Xilinx devcfg** | `kernel/drivers/char/xilinx_devcfg.ko` | FPGA bitstream loading (`/dev/xdevcfg`) |
| **Xilinx DMA** | `kernel/drivers/dma/xilinx/xilinx_dma.ko` | AXI DMA engine for RX/WF data |
| **Cadence MACB** | `kernel/drivers/net/ethernet/cadence/macb.ko` | Gigabit Ethernet |
| **Realtek r8169** | `kernel/drivers/net/ethernet/realtek/r8169.ko` | Ethernet PHY support |
| **Realtek PHY** | `kernel/drivers/net/phy/realtek.ko` | RTL8211E PHY driver |
| **Cadence I2C** | `kernel/drivers/i2c/busses/i2c-cadence.ko` | Si5351 clock control |
| **Xilinx UART** | `kernel/drivers/tty/serial/xilinx_uartps.ko` | GPS UART |
| **Xilinx GPIO** | `kernel/drivers/gpio/gpio-zynq.ko` | MIO/EMIO GPIO |
| **Zynq pin control** | `kernel/drivers/pinctrl/pinctrl-zynq.ko` | Pin muxing |
| **Xilinx XADC** | `kernel/drivers/iio/adc/xilinx-xadc.ko` | SoC temperature/voltage |
| **Cadence watchdog** | `kernel/drivers/watchdog/cadence_wdt.ko` | Hardware watchdog |
| **PPS core** | `kernel/drivers/pps/pps_core.ko` | GPS PPS timing |
| **OverlayFS** | `kernel/fs/overlayfs/overlay.ko` | Alpine overlay rootfs |
| **SquashFS** | `kernel/fs/squashfs/squashfs.ko` | `modloop` and rootfs base |
| **FAT/VFAT/MSDOS** | `kernel/fs/fat/*.ko` | Boot partition support |
| **NFS v2/v3** | `kernel/fs/nfs/*.ko` | Remote filesystem support |

### 8.4 The `zynqsdr` Driver
The `/dev/zynqsdr` character device driver is **built into the kernel** but does **not** appear in `modules.builtin`. This is because it is a **platform driver** that is not registered with the kernel module system — it is compiled directly into `vmlinux`.

Evidence from `/proc/kallsyms`:
```
c04871e8 t zynqsdr_remove
c0487228 t zynqsdr_probe
c048738c t zynqsdr_ioctl
c07a7828 t zynqsdr_open
c0a1fa14 t zynqsdr_driver_init
```

Additional strings found in the kernel binary:
```
"zynqsdr"                    /* driver name / device node name */
"rx888,zynqsdr"              /* device tree compatible string */
"zynqsdr-gpio"               /* likely a GPIO helper or sub-driver */
"zynqsdr: device is openning (%d)"
"zynqsdr: device is released (%d)"
```

The driver creates a **misc character device** (`major 10, minor 126`) at `/dev/zynqsdr`.

### 8.5 Loadable Modules (`modloop`)
The `modloop` squashfs image on the SD card contains **145 `.ko` modules** for functionality that is not built into the kernel image. Key loadable modules include:

| Category | Modules |
|----------|---------|
| **Crypto** | `aes_generic`, `sha256_generic`, `gcm`, `ccm`, `ctr`, `hmac`, etc. |
| **Wireless** | `ath9k_htc`, `brcmfmac`, `mt76`, `mt7921`, `rt2800usb`, `rtl8xxxu`, `zd1201`, `at76c50x-usb` |
| **USB Networking** | `asix`, `ax88179_178a`, `cdc_ether`, `qmi_wwan`, `usbnet`, etc. |
| **USB Gadget** | `g_ether`, `g_mass_storage`, `g_serial`, `usb_f_rndis`, etc. |
| **PPS Clients** | `pps-gpio`, `pps-ldisc` |
| **Misc** | `macvlan`, `tun`, `eeprom_93cx6`, `configfs` |

### 8.6 WiFi Support

WiFi support is provided via loadable modules (not built-in):

| Component | Status | Evidence |
|-----------|--------|----------|
| `CONFIG_CFG80211` | Module (`m`) | `net/wireless/cfg80211.o` in modules.order, NOT in modules.builtin |
| `CONFIG_MAC80211` | Module (`m`) | `net/mac80211/mac80211.o` in modules.order, NOT in modules.builtin |
| Dongle drivers | Modules | ath9k, brcmfmac, mt76/mt7921, rt2800usb, rtl8xxxu, at76c50x-usb, zd1201 |

The regulatory database is loaded at boot: `cfg80211: Loading compiled-in X.509 certificates for regulatory database`.

This contrasts with an earlier firmware state where WiFi support was absent — the author **did eventually add WiFi support** to the kernel.

### 8.7 Disabled / Missing Features
From the absence of modules and runtime behavior, we can infer the following are **not enabled** (or compiled as modules not loaded):

| Feature | Evidence |
|---------|----------|
| `CONFIG_IKCONFIG` | `extract-ikconfig` fails, no `/proc/config.gz`, zero `IKCFG_ST` markers |
| `CONFIG_DEBUG_FS` | `/sys/kernel/debug/` is empty or absent |
| `CONFIG_DYNAMIC_DEBUG` | No dynamic debug interface visible |
| Many DRM/GPU drivers | No display output on Web-888 |
| Sound card drivers | Audio is handled in userspace (WebSocket) |

---

## 9. FPGA Bitstream & Vivado Build Provenance

### 9.1 Bitstream Files

| File | Size | Location |
|------|------|----------|
| `websdr_hf.bit` | 1,244,764 bytes | `/media/mmcblk0p1/websdr_hf.bit` |
| `websdr_vhf.bit` | 1,249,832 bytes | `/media/mmcblk0p1/websdr_vhf.bit` |

### 9.2 Bitstream Headers

**HF bitstream:**
```
>system_wrapper;COMPRESS=TRUE;UserID=0XFFFFFFFF;Version=2023.1
7z010clg400
2025/04/13
    14:07:09
```

**VHF bitstream:**
```
>system_wrapper;COMPRESS=TRUE;UserID=0XFFFFFFFF;Version=2023.1
7z010clg400
2025/04/13
    14:21:08
```

### 9.3 Header Field Analysis

| Field | Value | Significance |
|------|-------|-------------|
| Design name | `system_wrapper` | Vivado block design wrapper (default name) |
| Compression | `TRUE` | Bitstream is compressed |
| Vivado version | **2023.1** | Xilinx Vivado 2023.1 — **confirmed** |
| Target part | `7z010clg400` | Zynq-7010, CLG400 package |
| Build date (HF) | 2025/04/13 14:07:09 | April 13, 2025 |
| Build date (VHF) | 2025/04/13 14:21:08 | April 13, 2025 (14 minutes later) |
| UserID | `0XFFFFFFFF` | Default (not set) |

### 9.4 Runtime FPGA Loading

From dmesg:
```
xdevcfg f8007000.devcfg: ioremap 0xf8007000 to (ptrval)
zynqsdr: device is openning (1643)
FPGA Signature: 0xaa55020c
Genuine Web-888 Detected
```

- FPGA bitstream is **NOT loaded by FSBL** (FSBL explicitly skips it).
- Bitstream is loaded at runtime by `websdr.bin` via `/dev/zynqsdr` or the devcfg interface.
- FPGA signature `0xaa55020c` is used for device authentication.
- "Genuine Web-888 Detected" — the software checks the FPGA signature to verify authentic hardware.

### 9.5 Vivado Version Confirmation

The bitstream header `Version=2023.1` definitively confirms **Vivado 2023.1** was used to build the FPGA bitstreams. This verifies the earlier claim in the ecosystem documentation. Both HF and VHF bitstreams were built on the same day (April 13, 2025), 14 minutes apart, suggesting they are generated from the same Vivado project with different configurations.

---

## 10. OpenZynqSDRApp — The Canonical Open-Source Analog

A critical finding from this research is the **`iliasam/OpenZynqSDRApp`** repository on GitHub. This project is an open-source Zynq SDR application forked from KiwiSDR, and it contains a kernel driver (`sdrdma_main.c`) that is **architecturally identical** to the closed Web-888 `zynqsdr` driver.

### 10.1 Source Location
- **Repository**: `https://github.com/iliasam/OpenZynqSDRApp`
- **Driver file**: `kernel_dma_driver/files/sdrdma_main.c`
- **Makefile**: `kernel_dma_driver/files/Makefile`
- **Yocto recipe**: `kernel_dma_driver/sdrdma.bb`

### 10.2 Architectural Similarities
| Feature | Web-888 `zynqsdr` | OpenZynqSDRApp `sdrdma` |
|---------|-------------------|-------------------------|
| **Ioctl magic** | `'Z'` | `'Z'` |
| **Command numbers** | 0-12, 20-21 | 0-12, 20-21 |
| **Device node** | `/dev/zynqsdr` | `/dev/sdrdma` |
| **Driver type** | Platform driver | Platform driver |
| **DTS compatible** | `"rx888,zynqsdr"` | `"openzynqsdr"` |
| **IRQ usage** | 4 IRQs (SPI 29-32) | 3 IRQs (Sound, WF0, WF1) |
| **DMA approach** | Memory-mapped AXI regions | `ioremap` + `memcpy_fromio` |

### 10.3 What `sdrdma_main.c` Reveals
The open-source driver implements:
- **RX_READ** (`ioctl 'Z', 6`) — reads sound/IQ data from FPGA memory
- **WF_READ** (`ioctl 'Z', 12`) — reads waterfall data from FPGA memory
- Workqueue-based deferred FIFO filling on sound IRQ
- 8-channel sound (8x2x4 bytes per burst)
- 2 waterfall channels (8192 words each)

**Important caveat**: OpenZynqSDRApp uses a **different physical memory map** (`0x1F400000` DDR scratchpad) compared to Web-888's AXI-mapped region (`0x40000000-0x47ffffff`). The ioctl interface, however, is identical.

### 10.4 Conclusion
While the **exact** `zynqsdr.c` source is closed, `sdrdma_main.c` provides a **production-quality reference implementation** for how the Web-888 driver likely works. Anyone reimplementing the Web-888 driver for the new Debian kernel can use this as a starting point for a clean-room rewrite.

---

## 11. RaspSDR Public Kernel Artifacts

The `RaspSDR` GitHub organization does **not** publish the `zynqsdr` or `ad8370` driver source. However, the `RaspSDR/red-pitaya-notes` repository contains a complete kernel patch set for building a Zynq kernel:

### 11.1 Files of Interest in `red-pitaya-notes/patches/`
| File | Size | Contents |
|------|------|----------|
| `linux-6.6.patch` | ~13.5 KB | Patches for `drivers/char`, `net/phy`, `wireless/realtek`, `pps`, `usb`, `phy` |
| `xilinx_devcfg.c` | ~56.8 KB | XDEVCFG FPGA bitstream loader kernel driver |
| `cma.c` | ~1.9 KB | `/dev/cma` contiguous memory allocator userspace interface |
| `xilinx_zynq_defconfig` | ~7.8 KB | Full Zynq kernel config with `CONFIG_LOCALVERSION="-xilinx"` |

### 11.2 What Is NOT There
- **No `zynqsdr.c`** or any reference to `rx888,zynqsdr`
- **No `ad8370` kernel driver**
- The build system downloads upstream Linux 6.6.32 from kernel.org and applies the patches above.

This confirms that the `zynqsdr` and `ad8370` drivers are **vendor-specific closed-source additions** not shared by the RaspSDR project.

---

## 12. GPL Compliance & Source Availability

### 12.1 Vendor Admission
Howard Su (author of RaspSDR and the Web-888 firmware) explicitly stated on the NextGenSDRs mailing list that the `/dev/zynqsdr` kernel driver source is **intentionally withheld** while the product is commercially active. The stated reason is:

> *"hardware authentication / anti-clone logic"* embedded in the driver.

### 12.2 GPL Concerns
The KiwiSDR author (John Seamons) raised GPL compliance concerns regarding:
- The proprietary FPGA Verilog bitstream
- The proprietary kernel module (`zynqsdr`)

No formal enforcement action is known to have been taken. The vendor's position appears to treat the driver as a trade-secret component necessary to prevent hardware cloning.

### 12.3 No Published Source
The kernel and U-Boot binaries are distributed with **NO published source, config, or DTS**. Specifically:
- GitHub searches for `"rx888,zynqsdr"`, `"zynqsdr_driver_init"`, and `"ad8370_driver"` return **zero results**.
- No `RaspSDR/linux` or `RaspSDR/kernel` repository exists.
- The `RaspSDR/server` repository contains only userspace code.
- The `RaspSDR/red-pitaya-notes` repository contains kernel patches but **not** the `zynqsdr` or `ad8370` drivers.

This constitutes a **GPL violation** — the Linux kernel is licensed under GPL-2.0, which requires that corresponding source code be made available to anyone who receives the binary. The vendor distributes the kernel binary (in `boot.bin`) without providing the source for the vendor-specific drivers compiled into it.

### 12.4 Practical Impact
Because the source is withheld, the closed drivers cannot simply be rebuilt from the vendor kernel. The new Debian kernel must either:
1. **Reverse-engineer** the driver from the binary, `ioctl` interface, and `sdrdma_main.c` reference, **or**
2. **Rewrite** a compatible driver from scratch using the documented `ioctl` API (see `docs/research/zynqsdr-port-notes.md`).

---

## 13. Firmware Evolution & Update Distribution

### 13.1 Kernel Version History

The Web-888 firmware has shipped with three kernel versions over the product's lifetime (from RX-888 changelog research):

| Kernel Version | Era | Notes |
|----------------|-----|-------|
| 6.6.58 | Early firmware | Initial release |
| 6.6.71 | Mid firmware | Intermediate update |
| 6.6.110 | Current (Oct 2025) | Latest, built by `junsu@HOMEPC` |

### 13.2 Update Distribution Channels

| Channel | Contents | When Used |
|---------|----------|-----------|
| **Full ZIP** | OS + firmware + server | Kernel upgrades (requires SD reflash) |
| **OTA auto-update** | Firmware + server only | Routine updates (no kernel change) |

The distinction is important: kernel upgrades require a full ZIP reflash because the kernel is embedded in `boot.bin` on the FAT32 partition. OTA auto-updates only replace `websdr.bin` and related files, not the kernel.

### 13.3 OTA Version Files

The `websdr.bin` binary contains URLs for OTA firmware updates:
- **Alpha channel**: `https://downloads.rx-888.com/web-888/alpha/version.txt`
- **Stable channel**: `https://downloads.rx-888.com/web-888/stable/version.txt`
- **General downloads**: `https://downloads.rx-888.com/%s` and `web888/%s/%s`

Admin config (`admin.json`) controls update behavior:
```json
{
  "update_check": true,
  "update_install": true
}
```

---

## 14. Live Hardware Validation Details

Through direct SSH access to a stock Web-888 device (investigated on two separate occasions), the following runtime behavior was confirmed:

### 14.1 Operating System

```
NAME="Alpine Linux"
ID=alpine
VERSION_ID=3.20.10
PRETTY_NAME="Alpine Linux v3.20"
```

**Alpine release**: 3.20.10 (updated from 3.20.9 in the prior investigation).

### 14.2 `/dev/zynqsdr` Device Properties
| Property | Value |
|----------|-------|
| **Device path** | `/dev/zynqsdr` |
| **Major/Minor** | `10:126` (misc character device) |
| **Driver binding** | Platform driver `zynqsdr` bound to `"rx888,zynqsdr"` DT node |
| **Shared fd** | All WebSDR threads open and share a single file descriptor |

### 14.3 `RX_READ` Behavior
- **Requested buffer size**: **19,456 bytes**
- **Actual returned size**: Often partial reads (e.g., 11,776 bytes)
- The driver returns whatever DMA data is currently available; userspace must handle partial reads.

### 14.4 `PPS_READ` Behavior
- Returns **`EBUSY`** when no GPS fix is available.
- This confirms the PPS logic in the driver expects a valid 1PPS signal from the GPSDO.

### 14.5 Kernel Symbol Visibility
All expected symbols are present in `/proc/kallsyms`:
```
zynqsdr_probe
zynqsdr_remove
zynqsdr_ioctl
zynqsdr_open
zynqsdr_driver_init
```

Additionally, 146+ `xilinx_*` and `zynq_*` symbols confirm the `linux-xlnx` source tree.

### 14.6 Memory

```
              total        used        free      shared  buff/cache   available
Mem:            498          43         249          92         206         352
Swap:             0           0           0
```

- **Total**: 498 MB (512MB physical, 14MB reserved by kernel/CMA)
- **Swap**: 0 (no swap configured)

### 14.7 Network Ports

| Port | Service | Binding |
|------|---------|---------|
| 22 | SSH | All interfaces |
| 2947 | GPSD | Localhost only |
| 8073 | WebSDR web interface | All interfaces |

---

## 15. Where to Obtain a Comparable Kernel Source

If you need to build a kernel that is **as close as possible** to the stock image, the recommended source trees are:

### 15.1 Option A: Xilinx `linux-xlnx` (Closest Match — what this project uses)
```bash
git clone https://github.com/Xilinx/linux-xlnx.git
cd linux-xlnx
git checkout xlnx_rebase_v6.6_LTS  # latest public merge: v6.6.80
# Then apply mainline stable patches 6.6.80 -> 6.6.110
```
This is the tree the parent project builds from (`xlnx_rebase_v6.6_LTS` + a config
fragment — see `config/kernel-web888.fragment` and `scripts/build-kernel.sh`). Note
`linux-xlnx` dropped the legacy `xilinx_devcfg` driver after v2018.3; the project
forward-ports the v2016.4 source itself (tracked in `config/kernel/`).

### 15.2 Option B: Mainline Linux 6.6.110 + Zynq Patches
```bash
git clone https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
cd linux
git checkout v6.6.110
# Apply Xilinx Zynq patches from linux-xlnx if needed
```
> Note: Mainline 6.6.110 has good Zynq-7000 support, but may lack some Xilinx-specific driver patches present in `linux-xlnx`.

### 15.3 Option C: OpenZynqSDRApp `sdrdma_main.c` (Driver Reference)
```bash
git clone https://github.com/iliasam/OpenZynqSDRApp.git
cd OpenZynqSDRApp/kernel_dma_driver/files
# Use sdrdma_main.c as a reference for rewriting zynqsdr
```

---

## 17. Raw Data Archives

The following artifacts were extracted from the stock device and are available locally for further analysis:

### 17.1 From 2026-04-13 Investigation

```
output/stock-analysis/
├── boot.bin                  # Original Zynq boot image (9 MB)
├── modloop                   # Squashfs module image (26 MB)
├── modloop-extract/          # Unpacked modules (145 .ko files)
├── extract1.gz               # Kernel image gzip stream from boot.bin
├── extract1_raw              # Decompressed kernel binary
├── extract2.gz               # Initrd gzip stream from boot.bin
├── extract2_raw              # Decompressed initrd (cpio)
├── initrd-extract/           # Unpacked initramfs contents
├── devicetree.dtb            # Extracted DTB from boot.bin offset 0x1d780
└── devicetree.dts            # Decompiled device tree source
```

### 17.2 From the Live-Device Investigation

```
.tmp/
├── web888-boot.bin           # boot.bin copy (9,056,768 bytes)
├── web888-websdr_hf.bit      # HF FPGA bitstream (1,244,764 bytes)
├── web888-websdr_vhf.bit     # VHF FPGA bitstream (1,249,832 bytes)
├── web888-dmesg.txt          # Full dmesg output (222 lines)
├── web888-boot-bin.dts       # Decompiled device tree from boot.bin
└── web888-kallsyms.txt       # Full /proc/kallsyms (998 KB)
```

These artifacts are extraction outputs, reproducible from the stock card with
the commands in this document; they are not distributed with the repository.
The primary-source investigation report based on them has been folded into
this document, [`hardware-facts.md`](hardware-facts.md), and
[`zynqsdr-port-notes.md`](zynqsdr-port-notes.md) Appendix A.

---

## 18. Conclusions

1. **The stock Web-888 kernel is a vendor-custom build** based on the Xilinx `linux-xlnx` 6.6 LTS branch, not mainline Linux and not an Alpine distribution kernel. The builder (`junsu@HOMEPC`) compiled it privately using Debian's cross-GCC 12.2.0 on a personal machine.
2. **The exact source tree is not public.** No published source, config, or DTS accompanies the distributed binaries. GitHub searches for the vendor-specific drivers return zero results. This is a GPL violation.
3. **The exact `.config` is unrecoverable** because `CONFIG_IKCONFIG` was disabled at build time (confirmed: zero `IKCFG_ST` markers in the binary).
4. **The Device Tree Blob was successfully extracted and decompiled**, revealing the exact `zynqsdr` node bindings (`"rx888,zynqsdr"`, SPI interrupts 29-32, GPIOs MIO 10/11/12/13/49).
5. **The boot chain uses a custom Red Pitaya-derived FSBL** that configures the Si5351 clock chip at boot and does NOT load the FPGA bitstream. U-Boot is present but its version string is not recoverable.
6. **FPGA bitstreams were built with Vivado 2023.1** on April 13, 2025, targeting `7z010clg400`. Bitstreams are loaded at runtime by `websdr.bin`, not by FSBL.
7. **WiFi support was eventually added** — CFG80211/MAC80211 and multiple dongle drivers are available as loadable modules.
8. **A close functional analog to the closed driver exists**: `iliasam/OpenZynqSDRApp/kernel_dma_driver/files/sdrdma_main.c` uses the **identical ioctl magic and command numbers** and can serve as the foundation for a clean-room rewrite.
9. **The missing vendor drivers** (`zynqsdr` and `ad8370`) are the primary blockers for a 1:1 reproduction of the stock kernel. These must be reverse-engineered or rewritten for the new Debian kernel.
10. **The vendor has explicitly stated** that the `zynqsdr` source is withheld for commercial anti-cloning reasons, making a source drop unlikely in the near term.
11. **Firmware has evolved** through kernel versions 6.6.58 -> 6.6.71 -> 6.6.110, with full ZIP updates required for kernel changes and OTA auto-updates for firmware/server-only changes.

---

## 19. References

- **Xilinx Kernel Repository**: https://github.com/Xilinx/linux-xlnx
- **Xilinx `linux-xlnx` 6.6 LTS Branch**: `xlnx_rebase_v6.6_LTS` (latest public merge: v6.6.80)
- **Xilinx `linux-xlnx` Branch Tags**: `xlnx_rebase_v6.6_LTS_2024.1`, `xlnx_rebase_v6.6_LTS_2024.2`, `xlnx_rebase_v6.6_LTS_merge_6.6.x`
- **PetaLinux Version Mapping**: 2023.2=6.1, 2024.x=6.6, 2025.x=6.12
- **Upstream Linux 6.6.110**: Released October 6, 2025 by Greg KH
- **OpenZynqSDRApp (Canonical Open-Source Analog)**: https://github.com/iliasam/OpenZynqSDRApp
  - Driver source: `kernel_dma_driver/files/sdrdma_main.c`
  - IOCTL header: `zynq/ioctl.h`
  - Userspace glue: `zynq/peri.cpp`
- **RaspSDR/server (Userspace Code)**: https://github.com/RaspSDR/server
- **RaspSDR/red-pitaya-notes (Kernel Patches)**: https://github.com/RaspSDR/red-pitaya-notes/tree/master/patches
- **Project kernel config**: `config/kernel-web888.fragment` (on `xlnx_rebase_v6.6_LTS`)
- **ZynqSDR Driver port notes**: `docs/research/zynqsdr-port-notes.md`
- **Firmware Downloads**: https://rx-888.com/
- **OTA Version Files**: `https://downloads.rx-888.com/web-888/{alpha,stable}/version.txt`

---

*Document version: 3.0 (adds boot chain analysis, FPGA/Vivado provenance, kernel provenance assessment, firmware evolution, WiFi support, GPL compliance update, and Alpine 3.20.10 correction)*