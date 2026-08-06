# Web-888 / RX-888 Firmware Analysis

## Overview

The Web-888 firmware consists of multiple components working together to provide a complete SDR system. This document analyzes the firmware structure, components, and update mechanisms.

## Firmware Variants

### 1. Main Web-888 Firmware

**Repository**: RaspSDR/server
**Base OS**: Alpine Linux 3.20 (3.20.10 confirmed on a live device)
**Target**: RX-888 hardware (Zynq XC7Z010)

### 2. Red Pitaya Firmware

**Repository**: RaspSDR/red-pitaya-notes
**Base OS**: Alpine Linux (fork of pavel-demin's work)
**Target**: Red Pitaya STEMlab boards

This document primarily focuses on the main Web-888 firmware.

## Firmware Package Structure

The firmware is distributed as a ZIP file containing all necessary components:

```
web-888-alpine-3.20-armv7-20260205.zip (101 MB)
│
├── boot/                           # Boot partition contents
│   ├── boot.bin                   # First-stage boot loader
│   ├── devicetree.dtb             # Device tree blob
│   ├── uImage                     # Linux kernel image
│   ├── websdr_hf.bit              # FPGA bitstream (HF mode)
│   └── websdr_vhf.bit             # FPGA bitstream (VHF mode)
│
├── config/                        # Configuration files
│   ├── admin.json                 # Admin settings
│   ├── config.js                  # JavaScript configuration
│   ├── dx.json                    # DX station database
│   ├── dx_config.json             # DX configuration
│   ├── dx_community.json          # Community DX data
│   ├── dx_community_config.json   # Community DX config
│   ├── frpc.template.ini          # FRP proxy template
│   ├── samples/                   # Sample audio files
│   ├── v.sed                      # Version sed script
│   └── websdr.json                # Main WebSDR config
│
├── cache/                         # APK package cache
│   └── armv7/                     # ARMv7 packages
│       ├── apk-tools-*.apk
│       ├── musl-*.apk
│       ├── busybox-*.apk
│       └── [100+ packages...]
│
├── lib/                           # System libraries
│   ├── ld-musl-armhf.so.1        # Musl dynamic linker
│   ├── libc.so                    # C library
│   └── [other libraries...]
│
├── sbin/                          # System binaries
│   └── apk                        # Package manager
│
├── websdr.bin                     # Main SDR application (static binary)
├── update.sh                      # Update script
├── version.txt                    # Version information
└── README.txt                     # Installation instructions
```

## Distribution Forms: ZIP Package vs. Live On-Device Layout

> **Clarification (live-device investigation):** The ZIP update package structure shown above is the *distribution* form. On a live device, the boot partition layout is different: the kernel, device tree, and initramfs are **packed inside `boot.bin`** — there are no separate `uImage` or `devicetree.dtb` files on the FAT partition. The two forms are summarized below.

### (a) ZIP Update Package (Distribution Form)

The downloadable ZIP (`web-888-alpine-3.20-armv7-*.zip`) presents boot files as separate artifacts (`boot.bin`, `devicetree.dtb`, `uImage`, bitstreams) as documented in the previous section. This is the view used by the update mechanism.

### (b) Live On-Device Layout (Confirmed by binwalk analysis)

On the live device, `/dev/mmcblk0p1` is a **single FAT32 partition (14.8GB)** containing:

```
/media/mmcblk0p1/
├── boot.bin               9,056,768 B  (Oct 18 2025 — FSBL + U-Boot + DTB + kernel + initramfs)
├── modloop               26,255,360 B  (Alpine squashfs kernel modules)
├── websdr.bin             7,124,020 B  (WebSDR application)
├── websdr_hf.bit          1,244,764 B  (HF FPGA bitstream)
├── websdr_vhf.bit         1,249,832 B  (VHF FPGA bitstream)
├── dumphfdl               2,601,800 B  (HFDL decoder)
├── libfdk-aac.so          1,421,708 B  (AAC library)
├── libliquid.so           2,660,680 B  (liquid-dsp library)
├── web-888.apkovl.tar.gz      9,950 B  (Alpine config overlay)
├── config/                               (SDR configuration)
├── cache/                                (APK package cache)
└── wifi/                                 (WiFi scripts)
```

**boot.bin internal layout (binwalk-verified offsets):**

| Offset | Component | Size |
|--------|-----------|------|
| 0x1D780 | Device tree blob (DTB) | 12,455 B |
| 0x278A8 | gzip Linux kernel | 4,700,435 B compressed → 11,740,160 B |
| 0x4A3200 | gzip initramfs | 3,894,120 B compressed → 6,503,936 B |

**FSBL characteristics (confirmed from strings):** The FSBL is **Red Pitaya-derived**, not a standard Xilinx FSBL. It prints `User RedPitaya Bootloader start` and `Bootloader Si5351 config`, configures the Si5351 clock generator before booting Linux, and explicitly does **not** load the FPGA bitstream (`FSBL Warning !!!Bitstream not loaded into PL`). No U-Boot version string is recoverable from the binary.

**Live kernel command line:**
```
console=ttyPS0,115200 earlycon earlyprintk initrd=0x3000000,4M modloop=modloop
```
(The `root=/dev/mmcblk0p2` cmdline shown later in this document reflects the ZIP-package assumption; the live device boots Alpine diskless mode from tmpfs + modloop with CMA 16 MiB reserved at 0x1f000000.)

### Kernel Version Evolution

Observed kernel versions across firmware releases (from firmware changelogs and live inspection):

| Firmware era | Kernel |
|--------------|--------|
| Earlier releases | 6.6.58-xilinx |
| Intermediate | 6.6.71-xilinx |
| Current (live, Oct 18 2025 build) | 6.6.110-xilinx |

Update channels: a full ZIP update replaces OS + firmware + server; the OTA auto-update mechanism replaces firmware + server only. OTA version checks query `downloads.rx-888.com/web-888/{alpha,stable}/version.txt`.

## Boot Components

### boot.bin

The `boot.bin` file is a combined boot image containing:

```
boot.bin Structure:
┌─────────────────────────────────────┐
│  FSBL (First Stage Boot Loader)     │ ← Xilinx Zynq BootROM loads this
│  - Initializes DDR                  │
│  - Configures MIO                   │
│  - Loads U-Boot                     │
├─────────────────────────────────────┤
│  U-Boot (Universal Boot Loader)     │ ← Second-stage bootloader
│  - Device initialization            │
│  - Loads kernel and devicetree      │
│  - Boot command execution           │
├─────────────────────────────────────┤
│  FPGA Bitstream (optional)          │ ← Can be loaded at boot
│  - Partial or full reconfiguration  │
└─────────────────────────────────────┘
```

**Generation**: Created using Xilinx bootgen tool

### Device Tree (devicetree.dtb)

The device tree describes hardware to the Linux kernel:

```dts
// Simplified device tree excerpt
/ {
    model = "RaspSDR Web-888";
    compatible = "xlnx,zynq-7000";
    
    cpus {
        cpu@0 { compatible = "arm,cortex-a9"; };
        cpu@1 { compatible = "arm,cortex-a9"; };
    };
    
    memory {
        device_type = "memory";
        reg = <0x0 0x20000000>;  // 512MB
    };
    
    amba_pl: amba_pl {
        // FPGA peripherals via AXI
        rx888_dma: dma@40400000 {
            compatible = "xlnx,axi-dma-1.00.a";
            reg = <0x40400000 0x10000>;
            interrupts = <0 29 4>;
        };
        
        rx888_spi: spi@41e00000 {
            compatible = "xlnx,axi-quad-spi-3.2";
            reg = <0x41e00000 0x10000>;
        };
    };
    
    // GPS UART
    uart1: serial@e0001000 {
        compatible = "xlnx,xuartps";
        status = "okay";
        current-speed = <9600>;
    };
};
```

### Linux Kernel (uImage)

**Version**: Linux 6.6 (LTS)
**Format**: uImage (U-Boot image format with header)
**Compression**: gzip

**Key Kernel Features**:
- Zynq-7000 SoC support
- Custom FPGA interface driver
- GPS/PPS subsystem
- Network drivers
- DMA engine support

**Kernel Command Line**:
```
console=ttyPS0,115200 root=/dev/mmcblk0p2 rw rootwait earlyprintk
```

## Main Application (websdr.bin)

### Binary Analysis

```bash
# File information
$ file websdr.bin
websdr.bin: ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), 
            statically linked, stripped

# Size
$ ls -lh websdr.bin
-rwxr-xr-x 1 root root 15M Feb  5 2026 websdr.bin

# Dependencies (statically linked - none)
$ ldd websdr.bin
    not a dynamic executable
```

### Internal Structure

The `websdr.bin` is a monolithic static binary containing:

```
websdr.bin (~7.7MB)
├─ Text Section (Code)
│  ├─ HTTP server
│  ├─ WebSocket server
│  ├─ Signal processing (DSP)
│  ├─ Extension modules
│  └─ FPGA interface
│
├─ Data Section
│  ├─ Static strings
│  ├─ Default configurations
│  └─ HTML/JS/CSS (embedded)
│
├─ BSS Section (Uninitialized data)
│  ├─ Global variables
│  ├─ Buffers
│  └─ State information
│
└─ Debug Info (stripped)
```

### Embedded Resources

The binary embeds web resources for the UI:

```
Embedded Files:
├── index.html           # Main web interface
├── kiwi.js              # Core JavaScript
├── kiwi.css             # Stylesheets
├── extensions/
│   ├── FT8/             # FT8 extension files
│   ├── WSPR/            # WSPR extension files
│   └── [20+ extensions] # Other decoder UIs
└── images/
    ├── favicon.ico
    ├── waterfall_palettes/
    └── ui_icons/
```

## FPGA Bitstreams

### websdr_hf.bit

**Purpose**: HF mode bitstream (0-62 MHz operation)
**Size**: ~2-3 MB
**Configuration**: Full FPGA configuration

**Contents**:
```
HF Bitstream:
├─ ADC Interface
│  └─ LTC2208 parallel data capture
│  └─ Clock domain crossing
│
├─ DDC Channels (13)
│  ├─ NCO (13 instances)
│  ├─ Mixer (13 instances)
│  ├─ CIC Decimator (13 instances)
│  └─ FIR Filter (13 instances)
│
├─ Waterfall Channels (2 hardware → 13 virtual)
│  ├─ FFT Engine (2 instances)
│  ├─ Magnitude Calc (2 instances)
│  └─ Time Multiplexer
│
├─ DMA Controllers
│  ├─ RX DMA (AXI4-Stream to memory)
│  └─ WF DMA (AXI4-Stream to memory)
│
└─ Control/Status Registers
   ├─ Frequency registers
   ├─ Mode control
   └─ Status readback
```

### websdr_vhf.bit

**Purpose**: VHF mode bitstream (118-150 MHz operation)
**Size**: ~2-3 MB

Similar structure to HF bitstream but:
- Optimized for higher frequency range
- Different decimation ratios
- Possibly different FIR coefficients

## Configuration System

### websdr.json

Main configuration file (JSON format):

```json
{
  "version": 2,
  "server": {
    "port": 8073,
    "port_ssl": 8074,
    "name": "Web-888 SDR",
    "description": "Web accessible SDR",
    "admin_email": "admin@example.com",
    "location": "JJ00aa",
    "antenna": "Long Wire",
    "snr": 60
  },
  "receiver": {
    "adc_clock": 130000000,
    "hf_attn": 0,
    "vhf_attn": 0,
    "gpsdo_enabled": true,
    "gpsdo_correction": 0.0
  },
  "users": {
    "max_users": 13,
    "timeout": 300,
    "password": "",
    "admin_password": ""
  },
  "network": {
    "dhcp": true,
    "ip": "",
    "netmask": "",
    "gateway": "",
    "dns": ""
  },
  "extensions": {
    "enabled": [
      "FT8", "WSPR", "DRM", "FAX", "SSTV",
      "HFDL", "TDoA", "CW_decoder", "noise_blank"
    ],
    "FT8": {
      "auto_upload": true,
      "callsign": "",
      "grid": ""
    },
    "WSPR": {
      "auto_upload": true,
      "callsign": "",
      "grid": ""
    }
  },
  "dx": {
    "enabled": true,
    "url": "",
    "update_interval": 3600
  },
  "update": {
    "channel": "stable",
    "auto_check": true,
    "auto_install": false
  }
}
```

### config.js

JavaScript configuration for UI defaults:

```javascript
// Simplified config.js structure
var kiwi_config = {
    // Waterfall settings
    wf_speed: 1,
    wf_size: 2,
    
    // Audio settings
    audio_compression: true,
    audio_rate: 12000,
    
    // Initial frequency
    init_freq: 10000000,  // 10 MHz
    init_mode: 'am',
    init_zoom: 0,
    
    // Default extensions
    init_ext: null,
    
    // Color scheme
    colormap: 1,
    
    // User preferences
    show_help: true,
    show_users: true
};
```

### DX Databases

```
dx.json Structure:
{
  "stations": [
    {
      "freq": 10000000,
      "mode": "AM",
      "ident": "WWV",
      "type": "time",
      "loc": "FN31",
      "notes": "Time station"
    },
    ...
  ]
}
```

## Package Cache

### APK Package Structure

The firmware includes a cache of Alpine Linux packages for offline installation:

```
cache/armv7/ (~80MB)
├── alpine-base-*.apk          # Base system
├── busybox-*.apk              # Core utilities
├── musl-*.apk                 # C library
├── linux-firmware-*.apk       # Firmware blobs
├── openssh-*.apk              # SSH server (optional)
├── dnsmasq-*.apk              # DHCP/DNS
├── hostapd-*.apk              # WiFi AP (optional)
├── chrony-*.apk               # NTP client
└── [80+ additional packages]
```

### Package Installation

Packages can be installed offline:
```bash
# Install from cache
apk add --cache-dir /boot/cache openssh

# Commit changes (make persistent)
lbu commit -d
```

## Update System

### Update Mechanism

The Web-888 uses a binary update system significantly faster than KiwiSDR's source-based updates.

```
Update Flow:
┌────────────────────────────────────────────────────────────┐
│  1. Check for Updates                                        │
│     - Query update server (alpha or stable channel)          │
│     - Compare local version with remote                      │
│     - Download update info                                   │
├────────────────────────────────────────────────────────────┤
│  2. Download Update                                          │
│     - Download .zip package                                  │
│     - Verify checksum (SHA256)                               │
│     - Verify signature (optional)                            │
├────────────────────────────────────────────────────────────┤
│  3. Prepare Update                                           │
│     - Mount root filesystem read-write                       │
│     - Backup current configuration                           │
│     - Extract update to temporary location                   │
├────────────────────────────────────────────────────────────┤
│  4. Apply Update (~10 seconds)                               │
│     - Stop websdr.bin                                        │
│     - Replace websdr.bin                                     │
│     - Update kernel/modules (if needed)                      │
│     - Update FPGA bitstreams (if needed)                     │
│     - Merge configuration changes                            │
├────────────────────────────────────────────────────────────┤
│  5. Finalize                                                 │
│     - Remount root read-only                                 │
│     - Restart websdr.bin                                     │
│     - Verify operation                                       │
└────────────────────────────────────────────────────────────┘
```

### Update Channels

```
Update Channels:
├── stable/                    # Production releases
│   ├── web-888-alpine-3.20-armv7-latest.zip
│   └── web-888-alpine-3.20-armv7-20260205.zip
│
└── alpha/                     # Development/beta releases
    ├── web-888-alpine-3.20-armv7-alpha.zip
    └── web-888-alpine-3.20-armv7-20260128.zip
```

### Version Tracking

**version.txt format**:
```
Version: 20260205
Channel: stable
Kernel: 6.6.0
Alpine: 3.20.0
Changes:
- Added MQTT support
- Improved GPSDO stability
- Fixed HFDL decoder
```

## Filesystem Layout (Runtime)

### Boot Partition (FAT32)

Mounted at `/boot`:

```
/boot/
├── boot.bin                   # Boot image
├── devicetree.dtb            # Device tree
├── uImage                    # Kernel
├── websdr_hf.bit            # HF FPGA config
├── websdr_vhf.bit           # VHF FPGA config
├── config/                  # Configuration
├── cache/                   # APK packages
├── lib/                     # Libraries
├── sbin/                    # Binaries
├── websdr.bin              # Main application
├── update.sh               # Update script
└── version.txt             # Version info
```

### Root Filesystem (SquashFS + Overlay)

```
/ (overlayfs)
│
├── lower/ (SquashFS - read-only base)
│   ├── bin/
│   ├── etc/
│   ├── lib/
│   ├── sbin/
│   ├── usr/
│   └── var/
│
└── upper/ (tmpfs - read-write overlay)
    ├── etc/config/          # Live config
    ├── tmp/                 # Temporary files
    └── var/log/             # Logs
```

**Benefits of OverlayFS**:
- Base system is read-only (SD card protection)
- Changes are in RAM (tmpfs)
- Changes can be committed with `lbu commit`
- Rollback to known state on reboot (if not committed)

## Changelog Analysis

Recent firmware changes show active development:

### 2026-02-05 (Latest Stable)
```
- Added MQTT client support for IoT integration
- New HFDL decoder with improved aircraft tracking
- CW Skimmer extension added
- Configurable bandwidth: 12kHz, 24kHz, 36kHz
- GPSDO improvements (faster convergence)
- Security updates for Alpine packages
```

### 2026-01-28
```
- Beta release with new UI improvements
- Added noise filter extension
- FT8 decoder optimizations
- Memory usage improvements
```

### 2025-12-15
```
- Stable release for holiday season
- WSPR auto-upload fixes
- DRM decoder improvements
- Documentation updates
```

## Security Analysis

### Boot Security

**Current State**:
- No secure boot implemented
- U-Boot has no password protection
- Physical access = full control

**Recommendations**:
- Enable U-Boot password if exposed
- Use signed updates
- Restrict physical access

### Network Security

**Current State**:
- HTTP by default (HTTPS optional)
- Optional password protection
- No rate limiting on authentication

**Attack Vectors**:
1. Default/no passwords
2. Information disclosure in UI
3. WebSocket injection
4. Buffer overflows in websdr.bin

**Mitigations**:
- Use strong admin passwords
- Enable HTTPS if possible
- Firewall rules for access control
- Regular updates

### Firmware Integrity

**Checksums**:
- SHA256 provided for updates
- No GPG signatures (currently)

**Recommendations**:
- Verify checksums before update
- Use official sources only
- Monitor for unauthorized changes

## Build Reproducibility

### From Source

The firmware can theoretically be built from source:

```bash
# 1. Get source
git clone https://github.com/RaspSDR/server.git
cd server

# 2. Setup cross-compilation
cd build
mkdir alpine-rootfs
# Download Alpine ARM rootfs...

# 3. Configure
cmake -DCMAKE_TOOLCHAIN_FILE=toolchain.cmake \
      -DCMAKE_SYSROOT=alpine-rootfs \
      -DPLATFORM=armv7 ..

# 4. Build
make -j$(nproc)

# 5. Package
make package
```

**Note**: The build process requires:
- Alpine Linux ARM rootfs
- ARM cross-compiler (musl-based)
- Xilinx tools (for FPGA bitstream)

## Storage Requirements

### SD Card Layout

```
/dev/mmcblk0 (8GB minimum recommended)
├─ /dev/mmcblk0p1 (FAT32, 256MB)
│  └─ /boot (firmware files)
│
└─ /dev/mmcblk0p2 (ext4, remaining)
   ├─ / (root filesystem)
   ├─ /etc/config (persistent config)
   └─ /var (logs, data)
```

### Space Usage

| Component | Size |
|-----------|------|
| Boot partition | ~150 MB |
| Root filesystem (SquashFS) | ~300 MB |
| Free space (data/config) | ~7 GB |
| Total (8GB card) | ~7.5 GB used |

**Recommendations**:
- Minimum: 4GB SD card
- Recommended: 8GB+ SD card
- High endurance SD card for 24/7 operation

## Diagnostics and Troubleshooting

### Log Locations

```
/var/log/
├── messages          # System messages
├── websdr.log        # WebSDR application log
├── kernel.log        # Kernel messages
└── dmesg             # Boot messages
```

### Diagnostic Commands

```bash
# Check running processes
ps aux

# Check network connections
netstat -tlnp

# Check FPGA status
cat /sys/class/fpga_manager/fpga0/state

# Check GPS
stty -F /dev/ttyPS1 9600
cat /dev/ttyPS1

# Check memory usage
free -m

# Check disk usage
df -h

# Check temperature (if available)
cat /sys/class/thermal/thermal_zone0/temp
```

## Future Improvements

Based on firmware analysis, potential areas for improvement:

1. **Security**:
   - Implement secure boot
   - Add GPG signature verification
   - Enable HTTPS by default

2. **Features**:
   - Expandable storage (USB)
   - Backup/restore functionality
   - Remote logging

3. **Performance**:
   - Smaller binary size
   - Faster boot time
   - Lower memory usage

## References

- [Alpine Linux Documentation](https://docs.alpinelinux.org/)
- [Xilinx Zynq Boot Guide](https://docs.xilinx.com/)
- [U-Boot Documentation](https://docs.u-boot.org/)
- [KiwiSDR Firmware Info](http://www.kiwisdr.com/info)
