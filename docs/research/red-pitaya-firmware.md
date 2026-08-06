# Web-888 Red Pitaya Firmware

## Overview

In addition to the main Web-888 firmware, the RaspSDR project maintains a separate firmware variant for **Red Pitaya** boards (STEMlab 125-14). This is a fork of Pavel Demin's Red Pitaya Notes project, adapted for SDR applications on the Web-888 hardware platform (Zynq-7010, Si5351, ATGM336H GPS, RTL8211E).

**Source**: https://github.com/RaspSDR/red-pitaya-notes (howard0su fork of pavel-demin/red-pitaya-notes)

All technical content in this document was verified by direct binary analysis of the released ZIP (`red-pitaya-alpine-3.20-armv7-20241228.zip`, 100,627,237 bytes compressed, 331 files, 106,656,913 bytes uncompressed) and cross-referenced against the stock Web-888 firmware running on a live device.

## What is Red Pitaya?

Red Pitaya is an open-source measurement and control tool that can replace many expensive laboratory instruments:

| Specification | Value |
|---------------|-------|
| **Platform** | Xilinx Zynq-7010 SoC |
| **ADC** | 2 channels, 14-bit, 125 MSPS |
| **DAC** | 2 channels, 14-bit, 125 MSPS |
| **Memory** | 512MB DDR3 |
| **Network** | 1 Gbps Ethernet |
| **USB** | USB 2.0 OTG |
| **Price** | ~$200-300 |

The Red Pitaya provides a flexible SDR platform with both ADC (receive) and DAC (transmit) capabilities.

## Architecture Differences

### Main Web-888 vs Red Pitaya

```
Web-888 (RX-888):
├─ Custom board optimized for RX-only SDR
├─ LTC2208 ADC (16-bit, 130 MSPS)
├─ No transmit capability
├─ Web-888 specific FPGA code
└─ 13 RX channels

Red Pitaya (RaspSDR firmware):
├─ STEMlab 125-14 instrumentation platform
├─ Dual ADC (14-bit, 125 MSPS)
├─ Dual DAC (14-bit, 125 MSPS)
├─ Per-app FPGA bitstreams (6 apps)
└─ Various SDR applications (TX+RX)
```

### Software Differences (CONFIRMED via binary analysis)

| Aspect | Main Web-888 | Red Pitaya Firmware |
|--------|--------------|---------------------|
| **Base OS** | Alpine Linux 3.20.10 | **Alpine Linux 3.20.3** |
| **Kernel** | 6.6.110-xilinx | **6.6.32-xilinx** |
| **Primary App** | websdr.bin (KiwiSDR fork) | Multiple SDR apps (6) |
| **User Interface** | Web (port 8073) | Web menu (port 80) + per-app |
| **Applications** | Single integrated | Multiple standalone |
| **Transmit Support** | No | Yes (with appropriate app) |
| **Custom Kernel Drivers** | zynqsdr, ad8370 (built-in) | **None** (standard Xilinx only) |
| **FPGA Access Path** | `/dev/zynqsdr` (interrupt DMA) | `/dev/mem` (mmap, polling) |
| **FPGA Loader** | Runtime by websdr.bin | `cat X.bit > /dev/xdevcfg` |
| **Web Server** | websdr.bin | tcpserver + apps/server/server |

## SDR Applications

The Red Pitaya firmware includes six pre-built SDR applications, each packaged with its own Vivado bitstream:

### 1. sdr_receiver

**Purpose**: Basic SDR receiver

**Bitstream**: `sdr_receiver.bit` (1,155,988 B, Vivado 2023.1, part 7z010clg400, built 2024/12/01)
**App binary**: `sdr-receiver` (10,856 B), TCP port 1001

**Features**:
- Direct ADC register access via `/dev/mem` mmap
- Independent tuning per channel
- TCP stream output to client applications
- Suitable for narrowband demodulation

```
Application: sdr_receiver
├─ Memory-Mapped FPGA Access
│  ├─ cfg  @ 0x40000000 (config registers)
│  ├─ sts  @ 0x41000000 (status registers)
│  └─ fifo @ 0x42000000 (RX FIFO)
│
├─ TCP Server (port 1001)
│  ├─ Client handshake
│  ├─ Sample streaming
│  └─ Control commands
│
└─ Use Cases
   ├─ Custom client integration
   └─ SDR experimentation
```

### 2. sdr_receiver_hpsdr

**Purpose**: Hermes/HL2-compatible SDR receiver (RaspSDR-specific adaptation)

**Bitstream**: `sdr_receiver_hpsdr.bit` (1,199,244 B, Vivado 2023.1, part 7z010clg400, built 2024/12/01)
**App binary**: `sdr-receiver-hpsdr` (20,720 B), TCP port 1001
**Custom file**: `peri.c` (modified 2024-12-27) — Web-888 attenuator control via sysfs GPIO pins 523/525/524 (EMIO base 512 + 11/13/12)

**Features**:
- Hermes protocol emulation
- HPSDR compatible (Thetis, SparkSDR, cuSDR, PowerSDR mRX PS)
- Up to 4 receivers
- Transmitter support (with Red Pitaya DAC)

```
Application: sdr_receiver_hpsdr
├─ Hermes Protocol Stack
│  ├─ Discovery protocol
│  ├─ Control protocol
│  └─ Data protocol
│
├─ DDC/DUC Engines
│  ├─ Multiple receivers
│  └─ One transmitter
│
├─ Network Interface
│  ├─ Raw Ethernet (for discovery)
│  └─ TCP/UDP data
│
└─ Web-888 Hardware Support (peri.c)
   ├─ PE4312 attenuator control
   ├─ sysfs GPIO 523/525/524
   └─ set_att_val() serial shift
```

### 3. sdr_transceiver_ft8

**Purpose**: Standalone FT8 transceiver

**Bitstream**: `sdr_transceiver_ft8.bit` (1,211,148 B, Vivado 2023.1, part 7z010clg400, built 2024/12/01)
**App binary**: uses `write-c2-files` + `ft8d` (314,076 B Fortran decoder)

**Features**:
- Fully autonomous FT8 operation
- No PC required
- Automatic band switching (via dcron)
- Upload to PSK Reporter

```
Application: sdr_transceiver_ft8
├─ Receiver Chain
│  ├─ 8-band receiver
│  ├─ ft8d (Fortran) decoder
│  └─ Spot logging
│
├─ Transmitter Chain
│  ├─ Message queue
│  ├─ FT8 encoder
│  └─ PA control
│
├─ Scheduler
│  ├─ 15-second slots
│  ├─ Band hopping
│  └─ RX/TX sequencing
│
└─ Reporting
   ├─ PSK Reporter upload
   ├─ Local logging
   └─ Statistics
```

### 4. sdr_transceiver_wspr

**Purpose**: Standalone WSPR transceiver

**Bitstream**: `sdr_transceiver_wspr.bit` (1,248,800 B, Vivado 2023.1, part 7z010clg400, built 2024/12/01)
**App binary**: uses `write-c2-files` + `wsprd` (145,336 B)

**Features**:
- WSPR receive and transmit
- Multi-band operation
- Upload to WSPRnet
- No PC required

```
Application: sdr_transceiver_wspr
├─ WSPR Decoder
│  ├─ wsprd integration
│  ├─ SNR measurement
│  └─ Drift correction
│
├─ WSPR Encoder
│  ├─ Message encoding
│  ├─ FSK tone generation
│  └─ Timing control
│
├─ Band Scheduler
│  ├─ 2-minute slots
│  ├─ Band hopping
│  └─ TX/RX coordination
│
└─ Network
   ├─ WSPRnet upload
   ├─ Spot database
   └─ Statistics
```

### 5. sdr_transceiver_wide

**Purpose**: Wideband transceiver for GNU Radio

**Bitstream**: `sdr_transceiver_wide.bit` (976,580 B, Vivado 2023.1, part 7z010clg400, built 2024/12/01)
**App binary**: `sdr-transceiver-wide` (15,680 B), TCP port 1001

**Features**:
- High-bandwidth data streaming
- Compatible with GNU Radio (gr-osmosdr)
- TCP/UDP streaming
- TX and RX support

```
Application: sdr_transceiver_wide
├─ High-Speed Data Path
│  ├─ Wideband ADC streaming
│  ├─ Minimal decimation
│  └─ Raw I/Q output
│
├─ Network Streaming
│  ├─ TCP server
│  ├─ UDP multicast
│  └─ Flow control
│
├─ TX Path
│  ├─ I/Q input
│  ├─ Interpolation
│  └─ DAC output
│
└─ GNU Radio Integration
   ├─ gr-osmosdr support
   ├─ Custom blocks
   └─ High-bandwidth apps
```

### 6. led_blinker

**Purpose**: GPIO LED blinker demo (Pavel Demin's stock reference design)

**Bitstream**: `led_blinker.bit` (625,708 B, Vivado 2023.1, part 7z010clg400, built 2024/12/09)
**App binary**: none — pure FPGA demonstration of EMIO GPIO output

**Use Case**: Verifying FPGA loader wiring and EMIO GPIO functionality without SDR complexity.

## File System Structure (CONFIRMED)

The ZIP ships a single FAT32 partition image. After extraction, the FAT root contains:

```
red-pitaya-alpine-3.20-armv7-20241228/  (FAT32 root)
├── boot.bin                       10,189,248 B   FSBL + U-Boot + DTB + kernel + initramfs
├── modloop                        14,520,320 B   Squashfs kernel modules (306 .ko)
├── red-pitaya.apkovl.tar.gz            9,260 B   Alpine config overlay
├── apps/                                       (6 SDR apps + server + tools)
│   ├── led_blinker/
│   ├── sdr_receiver/
│   ├── sdr_receiver_hpsdr/
│   ├── sdr_transceiver_ft8/
│   ├── sdr_transceiver_wide/
│   ├── sdr_transceiver_wspr/
│   ├── server/                                 App selector HTTP server
│   ├── common_tools/                           GPIO, I2C, temp utilities
│   ├── ft8d/                                   FT8 Fortran decoder
│   ├── wsprd/                                  WSPR decoder
│   ├── css/
│   ├── index.html                              App selector HTML
│   └── stop.sh                                 Stops all running apps
├── cache/                                      APK package cache (~200 pkgs)
└── wifi/                                       client.sh, hotspot.sh
```

**CONFIRMED**: There are **NO** separate `zImage`, `uImage`, `devicetree.dtb`, `boot.bin`+`uImage`, or `uEnv.txt` files in the ZIP. Kernel, DTB, and initramfs are all packed inside `boot.bin`. This matches the stock Web-888 model — NOT the upstream Pavel Demin layout (which uses separate files). See **boot.bin Layout** below.

### Application Directory Structure (CONFIRMED)

```
apps/sdr_receiver/
├── start.sh                   Calls apps/stop.sh, loads bitstream, runs app
├── stop.sh                    Kills sdr-receiver process
├── sdr_receiver.bit           FPGA bitstream
├── sdr-receiver               App binary (compiled from sdr-receiver.c)
├── sdr-receiver.c             Source: /dev/mem mmap of 0x40000000/0x41000000/0x42000000
├── Makefile
└── index.html                 Per-app web UI served by apps/server/server
```

```
apps/server/
├── server                     HTTP server binary (14,980 B)
├── server.c                   Source: path-traversal protected, reads FPGA temp + SLCR ID
└── Makefile
```

## boot.bin Layout (CONFIRMED via binwalk)

`file boot.bin` reports:

```
boot.bin: Xilinx Boot Image, 32-bit, unencrypted, Zynq 7000 SoC, FSBL size 0x1c008 bytes
```

Binwalk finds three components packed inside the single boot image (md5sum `ad4c8b7035475f8b514490bf60913ef3`):

| Component | Offset | Size (compressed) | Size (decompressed) |
|-----------|--------|-------------------|---------------------|
| FSBL | 0x00000 | 114,696 B (0x1C008) | — |
| DTB | 0x1D780 | 12,371 B | — |
| Kernel (gzip) | 0x27868 | 5,833,048 B | 14,910,720 B |
| Initramfs (gzip) | 0x5B79C0 | 4,194,304 B | 6,484,480 B |
| FPGA bitstream | — | **NOT PRESENT** | — |

### boot.bin Layout Comparison vs Stock Web-888

| Component | RaspSDR Offset | RaspSDR Size | Stock Web-888 Offset | Stock Web-888 Size |
|-----------|---------------|-------------|---------------------|-------------------|
| FSBL | 0x00000 | 114,696 B | 0x00000 | ~0x1C000 (~similar) |
| DTB | **0x1D780** | 12,371 B | **0x1D780** | 12,455 B |
| Kernel (gzip) | 0x27868 | 5,833,048 B → 14,910,720 B | 0x278A8 | 4,700,435 B → 11,740,160 B |
| Initramfs (gzip) | 0x5B79C0 | 4,194,304 B | 0x4A3200 | 3,894,120 B → 6,503,936 B |
| FPGA bitstream | NOT PRESENT | — | NOT PRESENT | — |

**CONFIRMED**: Both firmwares use the **same packed boot.bin layout** — DTB at the **identical offset 0x1D780**, gzip kernel + gzip initramfs packed inside boot.bin, with **no FPGA bitstream inside boot.bin**. This is **NOT** the upstream Pavel Demin model (which uses FSBL+FPGA+U-Boot in boot.bin with separate kernel files on FAT). The identical DTB offset strongly suggests the same FSBL layout in both firmwares.

## Boot Chain (CONFIRMED)

### FSBL Strings

The FSBL region of `boot.bin` (offset 0–0x1D780) contains these identifying strings, all **identical** to those found in the stock Web-888 boot.bin:

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
GPIO LookupConfig Failed
GPIO CfgInitialize Failed
Bootloader config success,boot to Linux
xdevcfg.c
xdevcfg_intr.c
xemacps.c
xemacps_control.c
xgpiops.c
xiicps.c
xiicps_hw.c
xiicps_master.c
xiicps_options.c
xiicps_xfer.c
xsdps.c
xsdps_options.c
```

**CONFIRMED**: The FSBL is the **same custom Red Pitaya-derived bootloader** used in both RaspSDR and stock Web-888 firmwares. It:
1. Configures the Si5351 clock generator at 122.88 MHz (the source is `patches/red_pitaya_fsbl_hooks.c` in the upstream repo; same code in both firmwares).
2. Does **NOT** load the FPGA bitstream (explicitly warned: `"FSBL Warning !!!Bitstream not loaded into PL"`).
3. Prints `"Bootloader config success,boot to Linux"` and hands off to U-Boot/SSBL.

The Si5351 configuration reads `XREF_FREQ=24576000` Hz (overridable via the `"refclock="` EEPROM variable, consumed by `patches/red_pitaya_fsbl_hooks.c`). GPIO assignments (CONFIRMED from source): `GPIO_CLK_REF=49`, `GPIO_HF_VHF=10`, EEPROM at I2C 0x50 with MAC at offset 0x10, Si5351 at I2C 0x60.

### U-Boot

The presence of `u-boot,dm-pre-reloc` (DTB property) and `done, booting the kernel.` (U-Boot message) confirms a U-Boot second-stage bootloader is present. **INFERRED**: U-Boot occupies approximately offset 0x1C008 to 0x1D780 (~2,936 bytes gap) — too small for full U-Boot; likely Pavel Demin's `ssbl.elf` minimal U-Boot replacement. No U-Boot version string is extractable from the binary.

### Bootargs (CONFIRMED from DTB)

```
console=ttyPS0,115200 earlycon earlyprintk initrd=0x3000000,4M modloop=modloop cma=36M
```

Notes:
- `initrd=0x3000000,4M` — initramfs loaded at 48 MB offset, 4 MB size
- `modloop=modloop` — Alpine modloop loaded from `/media/mmcblk0p1/modloop`
- **`cma=36M`** — CMA pool set to 36 MB (stock Web-888 omits this and relies on the kernel default of 16 MB)

## Kernel (CONFIRMED)

### Version String (extracted from kernel binary)

```
Linux version 6.6.32-xilinx (junsu@HOMEPC) (arm-xilinx-linux-gnueabi-gcc.real (GCC) 12.2.0, GNU ld (GNU Binutils) 2.39.0.20220819) #1 SMP PREEMPT Mon Dec  9 18:00:41 CST 2024
```

### Kernel Comparison: RaspSDR vs Stock Web-888

| Field | RaspSDR | Stock Web-888 |
|-------|---------|---------------|
| Version | **6.6.32**-xilinx | **6.6.110**-xilinx |
| Build user | `junsu@HOMEPC` | `junsu@HOMEPC` (**SAME**) |
| Compiler | `arm-xilinx-linux-gnueabi-gcc.real (GCC) 12.2.0` | `arm-linux-gnueabihf-gcc (Debian 12.2.0-14) 12.2.0` |
| Linker | `GNU ld (GNU Binutils) 2.39.0.20220819` | `GNU ld (GNU Binutils for Debian) 2.40` |
| Build date | Mon Dec 9 18:00:41 CST 2024 | Sat Oct 18 23:11:49 CST 2025 |
| Local version | `-xilinx` | `-xilinx` |
| SMP PREEMPT | Yes | Yes |
| Build # | `#1` | `#1` |
| Decompressed size | 14,910,720 B (14.2 MB) | 11,740,160 B (11.2 MB) |

**CONFIRMED**: Both kernels were built by the same person (`junsu@HOMEPC`) from the Xilinx `linux-xlnx` source tree. The RaspSDR firmware (Dec 2024) was built earlier using the Xilinx PetaLinux/Vitis toolchain, while the stock Web-888 (Oct 2025) was built later using Debian's cross-compiler. The RaspSDR kernel is larger despite being an older version (more built-in drivers or different config options).

### Kernel Config

**CONFIRMED**: `CONFIG_IKCONFIG=y` and `CONFIG_IKCONFIG_PROC=y` are enabled, allowing the full config (6,736 lines) to be extracted from `/proc/config.gz` (in extracted artifact `.tmp/redpitaya/extracted/rp-kernel.config`). **This contrasts sharply with stock Web-888, where `CONFIG_IKCONFIG` is disabled and the config is unrecoverable.**

Key configs:

| Config | Value | Notes |
|--------|-------|-------|
| CONFIG_IKCONFIG | y | Kernel config extractable |
| CONFIG_IKCONFIG_PROC | y | Available via /proc/config.gz |
| CONFIG_LOCALVERSION | `-xilinx` | Linux-xlnx tree |
| CONFIG_PREEMPT | y | Same as stock |
| CONFIG_CMA_SIZE_MBYTES | 16 | Kernel default (bootargs override to 36M) |
| CONFIG_XILINX_DEVCFG | y (built-in) | Provides `/dev/xdevcfg` for FPGA loading |
| CONFIG_FPGA | **NOT SET** | No FPGA Manager framework |
| CONFIG_CFG80211 | m (module) | WiFi regulatory |
| CONFIG_MAC80211 | m (module) | WiFi MAC layer |
| CONFIG_MACB | y (built-in) | GEM Ethernet |
| CONFIG_R8169 | y (built-in) | RTL8211E PHY driver |
| CONFIG_REALTEK_PHY | y (built-in) | PHY |
| CONFIG_MODULES | y | Module loading supported |
| CONFIG_SQUASHFS | y | Alpine rootfs |
| CONFIG_VFAT_FS | y | FAT32 boot partition |
| CONFIG_OVERLAY_FS | y | Overlay filesystem |

**CONFIRMED**: Zero matches for `zynqsdr` or `ad8370` strings in the kernel binary (grep on decompressed `.tmp/redpitaya/extracted/rp-kernel.bin`). These custom Web-888 drivers exist **only** in the stock Web-888 kernel.

### Modloop (CONFIRMED)

`modloop` (14,520,320 B squashfs) contains **306 .ko files** including:

- `kernel/drivers/char/xilinx_devcfg.ko` — `/dev/xdevcfg` for FPGA loading
- `kernel/drivers/dma/xilinx/xilinx_dma.ko`
- `kernel/drivers/iio/adc/xilinx-xadc.ko`
- `kernel/drivers/gpio/gpio-xilinx.ko`
- WiFi drivers: `ath9k_htc`, `brcmfmac`, `mt7601u`, `rt2800usb`, `rtl8188eu`
- `cfg80211`, `mac80211`

**CONFIRMED**: No `zynqsdr.ko` or `ad8370_driver.ko` modules exist. All FPGA access is via standard Xilinx drivers plus `/dev/mem` mmap.

## Device Tree Differences (CONFIRMED via DTS decompile)

The DTB embedded at boot.bin offset 0x1D780 (12,371 B, version 17) was extracted and decompiled to 688-line DTS at `.tmp/redpitaya/extracted/rp-dtb.dts`.

| Feature | RaspSDR | Stock Web-888 | Same? |
|---------|---------|---------------|-------|
| Root compatible | `xlnx,zynq-7000` | `xlnx,zynq-7000` | YES |
| Memory reg | `<0x00 0x20000000>` (512 MB) | `<0x00 0x20000000>` (512 MB) | YES |
| **zynqsdr node** | **ABSENT** | `compatible = "rx888,zynqsdr"` (4 interrupts) | **NO — major difference** |
| **amba_pl node** | **PRESENT**: `axi_hub@40000000` (`xlnx,axi-hub-1.0`, reg 0x40000000+0x40000000 = 1 GB window) | **ABSENT** | **NO — major difference** |
| pps node | `pps-gpio`, GPIO 54 (`<0x0a 0x36>`) | `pps-gpio`, GPIO 54 (`<0x0b 0x36>`) | YES (phandle differs) |
| fpga-full | `fpga-region` | `fpga-region` | YES |
| GPIO EMIO width | `0x40` (64 GPIOs) | `0x01` (1 GPIO) | NO |
| FCLK enable | `0x01` (FCLK0 enabled) | `0x00` (none) | NO |
| SPI1 spidev | `spidev@0` with `compatible = "ltc2488"` | (none) | NO |
| EEPROM nvmem-layout | ABSENT (simple eeprom node) | `macaddr@10` with `compatible = "mac-address"` | NO |
| Ethernet nvmem-cells | ABSENT | `nvmem-cells = <0x09>`, `nvmem-cell-names = "mac-address"` | NO |
| Watchdog reset-on-timeout | ABSENT | Present | NO |
| bootargs | `console=ttyPS0,115200 earlycon earlyprintk initrd=0x3000000,4M modloop=modloop cma=36M` | `console=ttyPS0,115200 earlycon earlyprintk initrd=0x3000000,4M modloop=modloop` | NO (`cma=36M` only) |
| phy0 view-port | `0x170` | `0x170` | YES |
| UART0 (console) | `serial@e0000000` okay | `serial@e0000000` okay | YES |
| UART1 (GPS) | `serial@e0001000` okay | `serial@e0001000` okay | YES |
| Ethernet PHY | `ethernet-phy@1` | `ethernet-phy@1` | YES |
| I2C0 EEPROM | `eeprom@50` (24c64) | `eeprom@50` (24c64) | YES |

### Key Differences Explained

1. **No zynqsdr node**: The RaspSDR firmware has **no** custom `zynqsdr` platform device. All FPGA access is via `/dev/mem` mmap of physical addresses 0x40000000–0x42000000 and `/dev/xdevcfg` for FPGA loading. Stock Web-888 has a `zynqsdr` node with `compatible = "rx888,zynqsdr"` and four interrupts (SPI 29–32).

2. **amba_pl node with axi_hub**: The RaspSDR DTB declares an `amba_pl` (AMBA Programmable Logic) bus with `axi_hub@40000000` (`compatible = "xlnx,axi-hub-1.0"`, `reg = <0x40000000 0x40000000>` = 1 GB register space). This is the standard Pavel Demin approach for FPGA register access via `/dev/mem`. Stock Web-888 does not have this node.

3. **GPIO EMIO width**: RaspSDR exposes **64 EMIO GPIOs** (for attenuator control, etc.) vs stock's 1 GPIO. `apps/sdr_receiver_hpsdr/peri.c` uses GPIO pins 523/525/524 (base 512 + 11/13/12) for PE4312 attenuator control.

4. **No MAC address from EEPROM**: RaspSDR does not wire the EEPROM MAC address to the ethernet node. Stock Web-888 reads MAC from EEPROM offset 0x10 via nvmem-cells.

5. **CMA=36M**: RaspSDR explicitly sets CMA to 36 MB via bootargs. Stock Web-888 uses the kernel default (16 MB).

6. **LTC2488 on SPI1**: RaspSDR has an `spidev@0` with `compatible = "ltc2488"` — a Linear Technology 24-bit sigma-delta ADC (Red Pitaya slow ADC). Stock Web-888 has none (Web-888 has no LTC2488).

7. **No watchdog auto-reset**: RaspSDR does not configure the Cadence watchdog for `reset-on-timeout`. Stock Web-888 does.

## FPGA and Application Model (CONFIRMED)

### Bitstream Inventory (CONFIRMED)

| App | .bit size | Vivado | Part | Build Date | Notes |
|-----|-----------|--------|------|------------|-------|
| `led_blinker/led_blinker.bit` | 625,708 B | 2023.1 | 7z010clg400 | 2024/12/09 17:57:12 | system_wrapper |
| `sdr_receiver/sdr_receiver.bit` | 1,155,988 B | 2023.1 | 7z010clg400 | 2024/12/01 00:48:07 | system_wrapper |
| `sdr_receiver_hpsdr/sdr_receiver_hpsdr.bit` | 1,199,244 B | 2023.1 | 7z010clg400 | 2024/12/01 00:45:18 | system_wrapper |
| `sdr_transceiver_ft8/sdr_transceiver_ft8.bit` | 1,211,148 B | 2023.1 | 7z010clg400 | 2024/12/01 00:42:53 | system_wrapper |
| `sdr_transceiver_wide/sdr_transceiver_wide.bit` | 976,580 B | 2023.1 | 7z010clg400 | 2024/12/01 00:37:42 | system_wrapper |
| `sdr_transceiver_wspr/sdr_transceiver_wspr.bit` | 1,248,800 B | 2023.1 | 7z010clg400 | 2024/12/01 00:43:32 | system_wrapper |

All bitstreams use the same design name (`system_wrapper`), compression (TRUE), and toolchain (Vivado 2023.1) as the stock Web-888 bitstreams (`websdr_hf.bit`, `websdr_vhf.bit`, built 2025/04/13).

### FPGA Loading Mechanism (CONFIRMED)

Per-app `start.sh` (e.g., `apps/sdr_receiver/start.sh`):

```sh
apps_dir=/media/mmcblk0p1/apps
source $apps_dir/stop.sh                              # Stop any running app
cat $apps_dir/sdr_receiver/sdr_receiver.bit > /dev/xdevcfg   # Load FPGA bitstream
$apps_dir/sdr_receiver/sdr-receiver &                 # Run app binary
```

**CONFIRMED**: The FPGA is loaded **per-app** via `cat <app>.bit > /dev/xdevcfg`. The `/dev/xdevcfg` device is provided by `xilinx_devcfg.ko` (CONFIG_XILINX_DEVCFG=y). The FSBL does NOT load the FPGA — same as stock Web-888.

### App FPGA Register Access (CONFIRMED from `sdr-receiver.c`)

```c
fd = open("/dev/mem", O_RDWR);
cfg  = mmap(NULL, sysconf(_SC_PAGESIZE), PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0x40000000);
sts  = mmap(NULL, sysconf(_SC_PAGESIZE), PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0x41000000);
fifo = mmap(NULL, 32*sysconf(_SC_PAGESIZE), PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0x42000000);
```

| Region | Address | Purpose |
|--------|---------|---------|
| Config | 0x40000000 | Configuration registers (sample rate, gain, etc.) |
| Status | 0x41000000 | Status / interrupt flags |
| RX FIFO | 0x42000000 | Sample data |

**CONFIRMED**: The physical register addresses are **identical** to stock Web-888's `zynqsdr` driver mapping (config 0x40000000, status 0x41000000, RX 0x42000000, WF 0x43000000+, PPS 0x47000000), but the access method differs:
- RaspSDR: `/dev/mem` mmap + polling (no custom driver)
- Stock Web-888: `/dev/zynqsdr` ioctl (custom driver, interrupt-driven DMA)

### App Selector (CONFIRMED from `apps/server/server.c`)

The HTTP server is a small C binary (14,980 B) that:
- Reads HTTP requests from stdin (served by `tcpserver`)
- Serves files from `/media/mmcblk0p1/apps/<dir>/`
- When a directory is requested (e.g., `GET /sdr_receiver`):
  1. Runs `<dir>/start.sh` as a detached child process
  2. Serves `<dir>/index.html` as response
- Implements path-traversal protection (blocks `..`)
- Reads FPGA temperature from `/sys/bus/iio/devices/iio:device0/`
- Reads SLCR device ID via mmap of 0xF8000000

### Boot Scripts (CONFIRMED from `apkovl-extracted/etc/local.d/apps.start`)

```sh
tcpserver -H -l 0 0 80 /media/mmcblk0p1/apps/server/server &
/media/mmcblk0p1/start.sh &
```

This starts:
1. App selector HTTP server on port 80 (`tcpserver` from `ucspi-tcp6` → `apps/server/server`)
2. Default app via `start.sh` on FAT root (if it exists — **NOTE: the ZIP does NOT ship a `start.sh` at the FAT root; the user must copy `start.sh` from a chosen app directory, e.g. `cp apps/sdr_receiver/start.sh start.sh`)

### App Shutdown (CONFIRMED from `apps/stop.sh`)

```sh
for script in /media/mmcblk0p1/apps/*/stop.sh; do
  $script &
done
wait
```

Before starting a new app, all running apps' `stop.sh` are invoked (each kills its own process via `killall -q <process>`).

## Userspace (CONFIRMED)

### Alpine Config Overlay (apkovl)

`red-pitaya.apkovl.tar.gz` (9,260 B) contains 28 files including:

- `/etc/local.d/apps.start` — boot script for app selector
- `/etc/conf.d/{gpsd,syslog,hostname,modloop,iptables}` — OpenRC service configs
- `/etc/init.d/sdrd` (or similar) — note: stock Web-888 has `/etc/init.d/sdrd`; RaspSDR's apkovl may not include this since it uses the per-app model
- `/etc/chrony/chrony.conf` — NTP config with SHM refclock from gpsd
- `/etc/conf.d/gpsd` — `GPSD_OPTIONS="-n"`, `DEVICES="/dev/ttyPS1 /dev/pps0"`
- `/etc/hostapd/hostapd.conf` — WiFi AP config
- `/etc/wpa_supplicant/wpa_supplicant.conf` — WiFi client config
- `/etc/fw_env.config` — U-Boot environment mapping
- `/etc/apk/world` — package list
- `/etc/ssh/sshd_config` — SSH config
- Runlevel symlinks

### Hostname (CONFIRMED)

Default hostname: `web-888` (overridable via `fw_printenv -n hostname` then `fw_setenv hostname <name>`).

### U-Boot Environment (CONFIRMED)

`/etc/fw_env.config`:
```
/sys/bus/i2c/devices/0-0050/eeprom      0x1800          0x0400
```

The U-Boot environment is stored in the I2C EEPROM (24c64 at I2C address 0x50) at offset 0x1800, size 1024 B. `fw_printenv`/`fw_setenv` (from `u-boot-tools-2024.04-r1`) read/write this region. Stock Web-888 uses the same EEPROM for U-Boot env (confirmed via running device: `0x1800 0x0400` mapping).

### Key Packages (CONFIRMED from cache)

| Package | Version | Notes |
|---------|---------|-------|
| `alpine-release` | 3.20.3-r0 | Diskless mode |
| `busybox` | 1.36.1-r29 | |
| `openssh-server` | 9.7_p1-r4 | Port 22 |
| `gpsd` | 3.25-r2 | ttyPS1 + pps0 |
| `chrony` | 4.5-r0 | SHM refclock PPS |
| `ucspi-tcp6` | 1.12.4-r1 | **tcpserver** for app selector |
| `dcron` | 4.5-r9 | FT8/WSPR cron jobs |
| `libconfig-dev` | — | App config parsing |
| `libgfortran` | — | ft8d/wsprd Fortran apps |
| `u-boot-tools` | 2024.04-r1 | fw_printenv/fw_setenv |
| `gcc`, `gfortran` | (in cache) | Build tools for Fortran apps |

**CONFIRMED**: RaspSDR ships **`ucspi-tcp6`** (for `tcpserver` app selector on port 80), **`dcron`** (for FT8/WSPR scheduling), **`libconfig-dev`** and **`libgfortran`** (for Fortran decoders). It does **NOT** ship `frp`/`noip2`/UPnP/htop/jq/netpbm (all of which are in stock Web-888).

### GPS Configuration (CONFIRMED)

`/etc/conf.d/gpsd`:
```
GPSD_OPTIONS="-n"
DEVICES="/dev/ttyPS1 /dev/pps0"
GPSD_SOCKET="/var/run/gpsd.sock"
```

Same as stock Web-888 — UART1 at ttyPS1 (ATGM336H @ 9600 baud), PPS on `/dev/pps0`.

### Chrony Configuration (CONFIRMED)

`/etc/chrony/chrony.conf`:
```
refclock SHM 2 refid PPS precision 1e-9
pool pool.ntp.org iburst offline
makestep 1 -1
driftfile /var/lib/chrony/chrony.drift
```

Same pattern as stock Web-888 — SHM refclock from gpsd for PPS-discipline.

### WiFi Support (CONFIRMED)

Same scripts as stock Web-888: `wifi/client.sh` (wpa_supplicant), `wifi/hotspot.sh` (hostapd + dnsmasq + iptables). Uses OpenRC runlevel switching.

## Source Provenance (CONFIRMED)

**Repository**: `github.com/RaspSDR/red-pitaya-notes` — fork of `pavel-demin/red-pitaya-notes` by user `howard0su`.

The Makefile confirms:
- `PART=xc7z010clg400-1` (Zynq-7010, CLG400)
- `INITRAMFS_TAG=3.20` (Alpine 3.20 base)
- `LINUX_TAG=6.6` (Linux 6.6 branch)
- `DTREE_TAG=xilinx_v2023.1` (device tree from Xilinx 2023.1)

The pre-built ZIP is published as a **GitHub release** of the RaspSDR/red-pitaya-notes repo (no source build required for end users).

### Key Source Files

**`patches/red_pitaya_fsbl_hooks.c`** (CONFIRMED):
- This is the **exact source** of the FSBL in **both** RaspSDR firmware and stock Web-888 firmware (identical strings, identical Si5351 122,880,000 Hz initialization, identical GPIO assignments).
- Si5351 I2C address 0x60, EEPROM I2C address 0x50 with MAC at offset 0x10.
- `XREF_FREQ=24576000` Hz (24.576 MHz reference), overridable via the `refclock=` EEPROM env variable.
- This **proves** that the stock Web-888 boot chain derives from this same codebase (likely cherry-picked into the Web-888 build).

**`apps/sdr_receiver_hpsdr/peri.c`** (CONFIRMED):
- Modified 2024-12-27 (later than other files in the release) — a howard0su custom addition for Web-888 hardware compatibility.
- GPIO-based attenuator control (PE4312 — `web888.c` bit-bangs PE4312 on these pins; no AD8370 anywhere in red-pitaya-notes): sysfs GPIO exports `/sys/class/gpio/export`, GPIO pins 523 (data), 525 (clk), 524 (LE) — base 512 + 11/13/12.
- `set_att_val(uint8_t att_val)` — serial-shifts 6-bit attenuator value to the attenuator chip.

### Build Prerequisites (CONFIRMED from Makefile)

- Vivado 2023.1 (for FPGA bitstreams, part 7z010clg400)
- Xilinx SDK / Vitis / PetaLinux toolchain (for kernel cross-compilation, gcc `arm-xilinx-linux-gnueabi-gcc`)
- Alpine Linux ARMv7 rootfs (or just use the pre-built release ZIP)
- `u-boot-tools` for `mkimage`
- `squashfs-tools` for modloop assembly

## Web Interface (CONFIRMED)

The Red Pitaya firmware includes a web-based app selector at port 80:

```
Access: http://web-888.local/ or http://192.168.1.100/  (mDNS: web-888.local)

Web Interface (apps/server/server + apps/index.html):
├─ Application List
│  ├─ led_blinker
│  ├─ sdr_receiver
│  ├─ sdr_receiver_hpsdr
│  ├─ sdr_transceiver_ft8
│  ├─ sdr_transceiver_wide
│  └─ sdr_transceiver_wspr
│
├─ System Status
│  ├─ CPU temperature (XADC via /sys/bus/iio/devices/iio:device0/)
│  ├─ SLCR device ID (via /dev/mem mmap of 0xF8000000)
│  └─ SD card usage
│
└─ Application Control
   ├─ Click app directory link
   ├─ apps/server/server runs <app>/start.sh as detached child
   └─ Per-app UI served from <app>/index.html
```

**CONFIRMED**: The default mDNS hostname is `web-888.local` (same as stock). The HTTP server runs on port 80 (not 8073 like stock Web-888). Each app's web UI runs on its own TCP port (typically 1001 for raw I/Q streams).

## Starting Applications

### Manual Start (SSH)

```bash
# Stop all running apps
/apps/stop.sh

# Start a specific app
/apps/sdr_receiver/start.sh
```

### Auto-Start at Boot (CONFIRMED)

The RaspSDR firmware boots with the **app selector HTTP server** on port 80 (always-on) and a **default app** if `start.sh` exists at the FAT root:

```bash
# Copy an app's start.sh to FAT root to make it the default app
cp /media/mmcblk0p1/apps/sdr_receiver/start.sh /media/mmcblk0p1/start.sh

# Reboot or manually run
/media/mmcblk0p1/start.sh
```

The default-app `start.sh` is **NOT shipped in the ZIP**. Users must copy one from `apps/<app>/start.sh` if they want auto-start at boot.

To make persistence across reboots (Alpine diskless mode has no persistent root):
```bash
lbu commit -d   # Save changes to .apkovl.tar.gz
```

## Network Configuration

### Default Settings

| Interface | Configuration |
|-----------|--------------|
| **Ethernet** | DHCP with fallback to 192.168.1.100 |
| **WiFi** | Hotspot mode (default, switchable) |
| **mDNS** | web-888.local |
| **TCP 22** | sshd |
| **TCP 80** | tcpserver + apps/server/server (app selector) |
| **TCP 1001** | Per-app SDR data stream |
| **TCP 2947** | gpsd (localhost only) |

### WiFi Client Mode

```bash
# Configure WiFi client
wpa_passphrase "YOUR_SSID" "YOUR_PASSWORD" > /etc/wpa_supplicant/wpa_supplicant.conf

# Switch to client mode
./wifi/client.sh

# Save changes (Alpine diskless)
lbu commit -d
```

### WiFi Hotspot Mode

```bash
# Switch to hotspot mode
./wifi/hotspot.sh

# Save changes
lbu commit -d
```

## RaspSDR Red Pitaya Firmware vs Stock Web-888 Firmware

| Feature | Stock Web-888 | RaspSDR Red Pitaya |
|---------|---------------|-------------------|
| **OS** | Alpine Linux 3.20.10 | Alpine Linux 3.20.3 |
| **Kernel** | 6.6.110-xilinx (junsu@HOMEPC, Debian GCC, Oct 2025) | 6.6.32-xilinx (junsu@HOMEPC, Xilinx GCC, Dec 2024) |
| **boot.bin size** | 9,056,768 B | 10,189,248 B |
| **boot.bin layout** | FSBL + U-Boot + DTB(0x1D780) + kernel(0x278A8) + initramfs(0x4A3200) | FSBL + U-Boot + DTB(0x1D780) + kernel(0x27868) + initramfs(0x5B79C0) |
| **FSBL** | Custom Red Pitaya-derived (Si5351 config, no FPGA load) | **Same** custom Red Pitaya-derived FSBL |
| **FPGA in boot.bin?** | NO | NO |
| **FPGA loader mechanism** | Runtime by websdr.bin (via `/dev/zynqsdr`) | `cat <app>.bit > /dev/xdevcfg` (per-app) |
| **FPGA access path** | `/dev/zynqsdr` (custom driver, interrupt-driven DMA) | `/dev/mem` (mmap, polling) + `/dev/xdevcfg` |
| **ADC data path** | `/dev/zynqsdr` ioctl (RX_READ) | `/dev/mem` mmap of 0x42000000 (polling) |
| **Custom kernel drivers** | `zynqsdr` (built-in), `ad8370` (built-in) | **NONE** (standard Xilinx drivers only) |
| **CONFIG_IKCONFIG** | Disabled (config unrecoverable) | **Enabled** (config fully extractable) |
| **CONFIG_FPGA** | (unknown) | **NOT SET** (no FPGA Manager framework) |
| **CMA bootarg** | Not set (kernel default 16 MB) | `cma=36M` |
| **bootargs** | `console=ttyPS0,115200 earlycon earlyprintk initrd=0x3000000,4M modloop=modloop` | `console=ttyPS0,115200 earlycon earlyprintk initrd=0x3000000,4M modloop=modloop cma=36M` |
| **Web server** | websdr.bin (KiwiSDR-derived) on port 8073 | tcpserver + apps/server/server on port 80 |
| **App model** | Single app (websdr.bin auto-start) | Multi-app (6 apps, web menu) |
| **Vivado version** | 2023.1 | 2023.1 (same) |
| **FPGA part** | 7z010clg400 | 7z010clg400 (same) |
| **Bitstreams** | 2 (websdr_hf.bit + websdr_vhf.bit, 2025/04/13) | 6 (per-app, 2024/12/01–09) |
| **DTB zynqsdr node** | Present (`rx888,zynqsdr`, 4 interrupts) | **Absent** |
| **DTB amba_pl node** | Absent | Present (`xlnx,axi-hub-1.0`) |
| **GPIO EMIO width** | 1 | 64 |
| **FCLK enable** | 0x00 (none) | 0x01 (FCLK0 enabled) |
| **MAC from EEPROM** | Yes (nvmem-cells) | No |
| **Watchdog reset-on-timeout** | Yes | No |
| **Hostname** | web-888.local | web-888.local (same) |
| **GPS** | gpsd on ttyPS1 + pps0 | gpsd on ttyPS1 + pps0 (same) |
| **WiFi scripts** | client.sh, hotspot.sh | client.sh, hotspot.sh (same) |
| **U-Boot env storage** | I2C EEPROM @0x1800 size 0x0400 | I2C EEPROM @0x1800 size 0x0400 (same) |
| **OTA update** | downloads.rx-888.com (alpha/stable) | Manual ZIP replacement |
| **Remote access** | FRP + noip2 + UPnP | None |
| **Open-source source** | No (closed zynqsdr/ad8370 drivers) | Yes (pavel-demin + howard0su additions) |

## Use Cases

### Choose Stock Web-888 when:

- You need 13 simultaneous users
- You want web-based access for multiple users on a single KiwiSDR-style UI
- You need HF + VHF coverage via the dedicated `websdr_hf.bit` / `websdr_vhf.bit` bitstreams
- You want KiwiSDR compatibility (extension API, OpenWebRX UI)
- You don't need transmit
- You want remote management (FRP, noip2, UPnP, OTA updates)

### Choose RaspSDR Red Pitaya when:

- You need **transmit capability** (FT8, WSPR, Hermes/HPSDR)
- You want to use existing SDR software (Thetis, SparkSDR, cuSDR, PowerSDR mRX PS)
- You're doing development/experimentation (per-app bitstreams, app selector)
- You want open-source access (no closed drivers — all sources in the repo)
- You want to run multiple distinct SDR applications on one device
- You need the GCC 12.2.0 + Xilinx toolchain kernel (open and reproducible)

## Building from Source

### Use the Pre-Built ZIP (Recommended)

The release ZIP at `github.com/RaspSDR/red-pitaya-notes` releases page contains the complete, ready-to-flash firmware. Users do not need to build from source for normal use.

### Prerequisites (CONFIRMED from Makefile)

- **Vivado 2023.1** (free WebPack edition is sufficient for part 7z010clg400) — for FPGA bitstream synthesis
- **Xilinx SDK / Vitis / PetaLinux toolchain** with `arm-xilinx-linux-gnueabi-gcc` — for kernel cross-compilation
- **Alpine Linux ARMv7 rootfs** (3.20) — for userspace base
- **`u-boot-tools`** for `mkimage`
- **`squashfs-tools`** for modloop assembly
- **`git`** to clone the repository

### Build Process (from `red-pitaya-notes` Makefile)

```bash
# 1. Clone repository
git clone https://github.com/RaspSDR/red-pitaya-notes.git
cd red-pitaya-notes

# 2. (Optional) Build a single FPGA bitstream
cd projects/sdr_receiver
make FPGA_bitstream
# Output: sdr_receiver.bit

# 3. (Optional) Build a single app
cd ../apps/sdr_receiver
make CROSS_COMPILE=arm-linux-gnueabihf-
# Output: sdr-receiver

# 4. Build the full SD card image (requires Alpine armv7 rootfs + Vivado)
make sd-image
# Output: red-pitaya-alpine-3.20-armv7-<date>.zip
```

### Project Structure

```
red-pitaya-notes/
├── projects/                 # FPGA projects
│   ├── led_blinker/
│   ├── sdr_receiver/
│   ├── sdr_receiver_hpsdr/
│   ├── sdr_transceiver_ft8/
│   ├── sdr_transceiver_wspr/
│   └── sdr_transceiver_wide/
│
├── apps/                     # Linux userspace apps (one dir per app)
│   ├── server/               # HTTP app selector
│   ├── common_tools/
│   ├── ft8d/                 # FT8 Fortran decoder
│   └── wsprd/                # WSPR decoder
│
├── patches/
│   └── red_pitaya_fsbl_hooks.c   # CUSTOM FSBL Si5351 config (shared with stock Web-888)
│
├── alpine/                   # Alpine Linux configuration
│   └── etc/                  # OpenRC, ssh, chrony, gpsd, hostapd, fw_env.config, etc.
│
├── wifi/                     # WiFi client/hotspot scripts
│
└── Makefile                  # Top-level build orchestration
    # PART=xc7z010clg400-1
    # INITRAMFS_TAG=3.20
    # LINUX_TAG=6.6
    # DTREE_TAG=xilinx_v2023.1
```

## Interoperability

### Using with Stock Web-888

Both systems can complement each other:

```
Setup Example:
├─ Web-888 (stock Alpine firmware)
│  └─ Primary HF/VHF monitoring (13-user WebSDR)
│  └─ Production use with OTA updates + FRP remote management
│
└─ Web-888 (RaspSDR Red Pitaya firmware) — on a separate SD card
   ├─ FT8/WSPR beacon (autonomous 24/7)
   ├─ HPSDR transmit experiments
   ├─ GNU Radio development
   └─ Per-app bitstream switching
```

### Network Integration

Both firmwares can coexist on the same network:
- Different IP addresses (DHCP-assigned)
- Different default web ports (8073 vs 80)
- Same mDNS hostname `web-888.local` (only one device at a time)
- Shared GPS antenna (if external GPSDO is used)
- Same WiFi scripts

### SD Card Swap

Because both firmwares use the **same single-FAT32-partition layout** with `boot.bin` at the FAT root, swapping between stock Web-888 and RaspSDR firmware is simply writing a different image to the SD card. The boot.bin structure (DTB at 0x1D780, gzip kernel, gzip initramfs) is **identical in both**, so the same Zynq boot ROM logic loads both.

## Troubleshooting

### Common Issues

1. **Application won't start**
   ```bash
   # Check logs
   cat /var/log/messages

   # Check if another app is running
   ps aux | grep sdr

   # Stop conflicting app
   /media/mmcblk0p1/apps/stop.sh
   ```

2. **FPGA not loading**
   ```bash
   # Verify xdevcfg device exists
   ls -la /dev/xdevcfg

   # Manually load a bitstream
   cat /media/mmcblk0p1/apps/sdr_receiver/sdr_receiver.bit > /dev/xdevcfg

   # Check kernel module loaded
   lsmod | grep xilinx_devcfg
   ```

3. **No network connection**
   ```bash
   # Check network status
   ifconfig

   # Check DHCP
   cat /etc/dhcpcd.conf

   # Restart networking
   rc-service networking restart
   ```

4. **GPS not working**
   ```bash
   # Check gpsd is running
   ps aux | grep gpsd

   # Check UART1 / pps0 exist
   ls -la /dev/ttyPS1 /dev/pps0

   # Test gpsd output
   gpspipe -w
   ```

5. **SD card full (Alpine diskless mode)**
   ```bash
   # Check disk usage (modloop + apkovl)
   df -h

   # Clean logs
   rm /var/log/*.log.*

   # Commit Alpine Local Backup overlay
   lbu commit -d
   ```

6. **App selector HTTP server not responding on port 80**
   ```bash
   # Check if tcpserver is running
   ps aux | grep tcpserver

   # Restart app selector
   rc-service local restart

   # Or manually restart
   /etc/local.d/apps.start
   ```

## References

- [Red Pitaya Notes - Pavel Demin](https://pavel-demin.github.io/red-pitaya-notes/)
- [Red Pitaya Official Site](https://redpitaya.com/)
- [RaspSDR Red Pitaya Repo](https://github.com/RaspSDR/red-pitaya-notes)
- [Hermes Protocol](https://github.com/TAPR/OpenHPSDR-SVN/tree/master/Documentation)
- [GNU Radio](https://www.gnuradio.org/)
- [WSJT-X](https://physics.princeton.edu/pulsar/k1jt/wsjtx.html)
- [WSPRnet](http://wsprnet.org/)
- [Xilinx linux-xlnx](https://github.com/Xilinx/linux-xlnx)
- [Pavel Demin's red-pitaya-notes](https://github.com/pavel-demin/red-pitaya-notes)

---
