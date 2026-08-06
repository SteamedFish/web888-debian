# Web-888 / RX-888 Software Architecture

## Overview

The Web-888 runs a custom software stack based on Alpine Linux, derived from the KiwiSDR project but with significant modifications to support the Zynq hardware platform. The software provides a web-accessible SDR receiver with real-time signal processing, multi-user support, and numerous built-in decoders.

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          WEB-888 SOFTWARE STACK                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         USER INTERFACE LAYER                         │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────┐  │   │
│  │  │  Web UI     │  │  Admin UI   │  │  Extensions │  │  Decoders  │  │   │
│  │  │ (OpenWebRX) │  │ (Config)    │  │ (JS/C++)    │  │ (Real-time)│  │   │
│  │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └─────┬──────┘  │   │
│  │         │                │                │               │         │   │
│  │         └────────────────┴────────────────┴───────────────┘         │   │
│  │                              │                                      │   │
│  │  Protocol: HTTP / WebSocket / Web Audio API                         │   │
│  └──────────────────────────────┼──────────────────────────────────────┘   │
│                                 ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      APPLICATION LAYER (websdr.bin)                  │   │
│  │  ┌───────────────────────────────────────────────────────────────┐  │   │
│  │  │                      Server Core (C/C++)                       │  │   │
│  │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │  │   │
│  │  │  │ HTTP    │ │ WS      │ │ RX Ctrl │ │ Stream  │ │ Config  │  │  │   │
│  │  │  │ Server  │ │ Server  │ │ Manager │ │ Manager │ │ Manager │  │  │   │
│  │  │  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘  │  │   │
│  │  │       └───────────┴───────────┴───────────┴───────────┘       │  │   │
│  │  └───────────────────────────────────────────────────────────────┘  │   │
│  │                              │                                      │   │
│  │  ┌───────────────────────────────────────────────────────────────┐  │   │
│  │  │                   Signal Processing Pipeline                   │  │   │
│  │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │  │   │
│  │  │  │ FFT     │ │ DDC     │ │ Demod   │ │ Decoders│ │ Waterfall│  │  │   │
│  │  │  │ Engine  │ │ Engine  │ │ Chain   │ │ (DSP)   │ │ Gen      │  │  │   │
│  │  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘  │  │   │
│  │  └───────────────────────────────────────────────────────────────┘  │   │
│  │                              │                                      │   │
│  │  ┌───────────────────────────────────────────────────────────────┐  │   │
│  │  │                     Extension System                           │  │   │
│  │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │  │   │
│  │  │  │ ALE_2G  │ │ FT8     │ │ DRM     │ │ WSPR    │ │ HFDL    │  │  │   │
│  │  │  │ CW_SKIM │ │ TDoA    │ │ FAX     │ │ SSTV    │ │ [more]  │  │  │   │
│  │  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘  │  │   │
│  │  └───────────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                 ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      KERNEL DRIVER LAYER                             │   │
│  │  ┌───────────────────────────────────────────────────────────────┐  │   │
│  │  │                FPGA Interface Driver (Linux Kernel Module)      │  │   │
│  │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │  │   │
│  │  │  │ AXI DMA │ │ IRQ     │ │ MEM     │ │ SPI/I2C │ │ GPIO    │  │  │   │
│  │  │  │ Control │ │ Handler │ │ Mapping │ │ Control │ │ Control │  │  │   │
│  │  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘  │  │   │
│  │  └───────────────────────────────────────────────────────────────┘  │   │
│  │                              │                                      │   │
│  │  ┌───────────────────────────────────────────────────────────────┐  │   │
│  │  │                   GPS/PPS Driver                                │  │   │
│  │  │  - UART interface to ATGM336H                                   │  │   │
│  │  │  - PPS interrupt handling                                       │  │   │
│  │  │  - GPSDO PID control loop                                       │  │   │
│  │  └───────────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                 ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      HARDWARE ABSTRACTION LAYER                      │   │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐       │   │
│  │  │  FPGA   │ │  ADC    │ │  DMA    │ │  GPS    │ │  ATT    │       │   │
│  │  │  Bitstream │ Driver  │  Engine │  Module │  Control │       │   │
│  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Operating System

### Alpine Linux

The Web-888 uses **Alpine Linux 3.20** as its base operating system.

**Key Characteristics:**
- **Musl libc**: Lightweight C standard library (vs glibc)
- **BusyBox**: Minimalist Unix utilities
- **APK**: Alpine Package Keeper for package management
- **OpenRC**: Init system and service manager
- **Security**: Proactive security features, small attack surface

**File System Layout:**
```
/                          # Root (read-only overlay)
├── bin/                   # Essential binaries
├── boot/                  # Boot files
│   ├── boot.bin          # FSBL + U-Boot + FPGA bitstream
│   ├── uImage            # Compressed kernel
│   └── ...
├── dev/                   # Device files
├── etc/                   # Configuration
│   ├── config/           # WebSDR configuration
│   └── websdr.json       # Main config file
├── lib/                   # Shared libraries
├── mnt/                   # Mount points
├── opt/                   # Optional software
├── proc/                  # Process info
├── root/                  # Root home
├── run/                   # Runtime files
├── sbin/                  # System binaries
├── sys/                   # System info
├── tmp/                   # Temporary files
├── usr/                   # User programs
├── var/                   # Variable data
└── www/                   # Web server root
```

### Linux Kernel

**Version:** Linux 6.6 (LTS)

**Key Features:**
- Custom FPGA interface driver
- GPS/PPS support for timing
- DMA engine support
- Network drivers for 1000M Ethernet
- Device Tree support for Zynq

**Custom Drivers:**
```
/drivers/char/rx888/      # Custom FPGA interface driver
├── rx888.c              # Main driver
├── rx888.h              # Header file
└── Makefile             # Build rules
```

## Main Application (websdr.bin)

The core SDR application is a monolithic C/C++ binary (`websdr.bin`) that provides all server functionality.

### Architecture Components

#### 1. HTTP Server
- **Library**: Custom or embedded (e.g., civetweb, mongoose)
- **Features**:
  - Static file serving (HTML, CSS, JS, images)
  - REST API endpoints
  - WebSocket upgrade handling
  - Authentication/authorization

#### 2. WebSocket Server
- **Protocol**: RFC 6455 WebSocket
- **Usage**: Real-time streaming of audio and waterfall data
- **Binary Protocol**: Custom efficient binary protocol

#### 3. RX Control Manager
- Manages 13 receive channels
- Handles frequency/tuning requests
- Controls bandwidth and demodulation mode
- Manages per-channel audio streams

#### 4. Stream Manager
- Coordinates audio streaming to clients
- Manages waterfall data distribution
- Handles connection lifecycle

#### 5. Configuration Manager
- Reads/writes JSON configuration files
- Hot-reload capabilities
- Admin interface backend

## Signal Processing Pipeline

### Data Flow

```
ADC Samples (130MSPS, 16-bit)
    │
    ▼
┌─────────────────────────────────────────┐
│  FPGA DMA Buffer (in DDR memory)        │
│  - Circular buffer for continuous data  │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│  DDC Engine (per channel)               │
│  - NCO: Local oscillator                │
│  - Mixer: Complex downconversion        │
│  - CIC: Decimation (coarse)             │
│  - FIR: Anti-alias filter               │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│  Demodulation Chain                     │
│  - AM: Envelope detection               │
│  - SSB: Phasing method                  │
│  - FM: Frequency discriminator          │
│  - CW: Product detector                 │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│  Audio Processing                       │
│  - Resampling to audio rate             │
│  - AGC (Automatic Gain Control)         │
│  - Noise blanking/filtering             │
│  - Volume control                       │
└─────────────────────────────────────────┘
    │
    ▼
WebSocket Audio Stream (OPUS or PCM)
```

### Waterfall Processing

```
ADC Samples
    │
    ▼
┌─────────────────────────────────────────┐
│  FFT Engine                             │
│  - Sliding window FFT                   │
│  - Configurable FFT size (2K-64K)       │
│  - Hanning/Hamming window               │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│  Magnitude Calculation                  │
│  - Complex magnitude                    │
│  - Log conversion (dB)                  │
│  - Scaling and clipping                 │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│  Time Multiplexing (13 virtual channels)│
│  - 2 hardware WF channels               │
│  - Fast switching between frequencies   │
│  - Buffer management                    │
└─────────────────────────────────────────┘
    │
    ▼
WebSocket Waterfall Stream (compressed binary)
```

## Extension System

### Built-in Extensions

Extensions are modular components that add functionality:

| Extension | Language | Description |
|-----------|----------|-------------|
| ALE_2G | C | Automatic Link Establishment decoder |
| ant_switch | C++ | Antenna switching control |
| CW_decoder | C++ | Morse code decoder |
| CW_skimmer | C | CW skimmer for contesting |
| DRM | C++ | Digital Radio Mondial decoder |
| FAX | C++ | Weather fax decoder |
| FFT | C | FFT display extension |
| FSK | C++ | FSK/RTTY decoder |
| FT8 | C++ | WSJT-X FT8 decoder |
| HFDL | C++ | High Frequency Data Link decoder |
| IBP_scan | C | International Beacon Project scanner |
| IQ_display | C++ | IQ constellation display |
| Loran_C | C | Loran-C navigation decoder |
| NAVTEX | C++ | Maritime NAVTEX decoder |
| SSTV | C++ | Slow Scan Television decoder |
| S_meter | C | Signal strength meter |
| TDoA | C++ | Time Difference of Arrival (direction finding) |
| waterfall | C++ | Enhanced waterfall display |
| wspr | C++ | WSPR decoder |
| noise_blank | C | Noise blanker |
| noise_filter | C | Noise filter |

### Extension Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Extension API                         │
├─────────────────────────────────────────────────────────┤
│  - Register/unregister extension                         │
│  - Allocate audio buffer                                 │
│  - Access to raw IQ samples                              │
│  - UI panel registration                                 │
│  - WebSocket communication                               │
└─────────────────────────────────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
   ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
   │ C Extension │ │ C++ Ext     │ │ JS Extension│
   │ (compiled)  │ │ (compiled)  │ │ (runtime)   │
   └─────────────┘ └─────────────┘ └─────────────┘
```

## Web Interface

### Technology Stack

- **Frontend**: Vanilla JavaScript (ES6+)
- **UI Framework**: Custom (KiwiSDR/OpenWebRX derived)
- **Graphics**: HTML5 Canvas (waterfall, spectrum)
- **Audio**: Web Audio API
- **Communication**: WebSocket

### Main Components

#### 1. Waterfall Display
- Real-time spectrum visualization
- 15 levels of zoom (z0 - z14)
- Configurable speed and resolution
- Click-to-tune functionality

#### 2. Audio Player
- Web Audio API based
- Real-time streaming
- Buffer management
- Volume control

#### 3. Control Panel
- Frequency entry/display
- Mode selection (AM, SSB, CW, FM)
- Bandwidth control
- AGC settings
- Noise reduction controls

#### 4. Extension Panels
- Dynamically loaded extension UIs
- Tab-based interface
- Real-time decoder output

## Configuration System

### Configuration Files

Located in `/etc/config/`:

```
/etc/config/
├── websdr.json           # Main configuration
├── admin.json            # Admin settings
├── dx.json               # DX cluster/station database
├── dx_config.json        # DX display configuration
├── dx_community.json     # Community DX data
├── dx_community_config.json
└── samples/              # Audio sample files
```

### websdr.json Structure

```json
{
  "server": {
    "port": 8073,
    "name": "Web-888 SDR",
    "location": "Grid Square",
    "admin_email": "admin@example.com"
  },
  "receiver": {
    "antenna": "Long Wire",
    "gps": true,
    "clocks": {
      "adc_clock": 130000000,
      "gpsdo_enabled": true
    }
  },
  "users": {
    "max_users": 13,
    "timeout": 300
  },
  "extensions": {
    "enabled": ["FT8", "WSPR", "DRM", ...]
  }
}
```

## GPS and Timing System

### GPS Module Interface

**Hardware**: ATGM336H via UART

**Features**:
- NMEA 0183 protocol parsing
- Multi-constellation support
- PPS (Pulse Per Second) input

### GPSDO (GPS Disciplined Oscillator)

The Web-888 implements a "poor man's GPSDO" using software control:

```
GPS PPS Signal
      │
      ▼
┌─────────────────┐
│ PPS Interrupt   │ ← Hardware interrupt on PPS
│ Handler         │   rising edge
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ PID Controller  │ ← Software PID loop
│ - Proportional  │   adjusts Si5351 frequency
│ - Integral      │   to minimize PPS error
│ - Derivative    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Si5351 Control  │ ← I2C commands to adjust
│ - Frequency     │   clock frequency
│ - Phase offset  │
└─────────────────┘
```

**Parameters**:
- PID gains tuned for stability
- Convergence time: ~10-30 minutes
- Accuracy: ~0.1-1 ppm (parts per million)

## Update System

### Binary Update Mechanism

Unlike KiwiSDR which required source compilation (10+ minutes), the Web-888 uses binary updates:

```
┌─────────────────────────────────────────┐
│        Update Process (10 seconds)       │
├─────────────────────────────────────────┤
│  1. Check for updates (alpha/stable)    │
│  2. Download binary package (.zip)      │
│  3. Verify checksum/signature           │
│  4. Mount root read-write               │
│  5. Extract new binaries                │
│  6. Update configuration if needed      │
│  7. Remount root read-only              │
│  8. Restart services                    │
└─────────────────────────────────────────┘
```

### Update Channels

- **Stable**: Production releases, well-tested
- **Alpha**: Beta releases, latest features

### Update Sources

- **Primary**: rx-888.com official server
- **Mirror**: Community mirrors (if configured)

## Security Features

### Network Security

1. **Authentication**:
   - Optional password protection
   - Admin panel separate authentication
   - Session management

2. **Access Control**:
   - IP allowlist/blocklist
   - User limit enforcement
   - Bandwidth limiting

3. **HTTPS Support**:
   - TLS certificate support
   - Let's Encrypt integration (if configured)

### System Security

1. **Read-Only Root Filesystem**:
   - Prevents SD card corruption
   - Attack surface reduction
   - Overlay for temporary changes

2. **Minimal Attack Surface**:
   - Alpine Linux minimal base
   - Only necessary services running
   - No SSH by default (optional)

3. **Update Verification**:
   - Checksum verification
   - Signature verification (if enabled)

## Build System

### Cross-Compilation

The Web-888 software uses CMake for building:

```
┌─────────────────────────────────────────┐
│        Build Environment                 │
├─────────────────────────────────────────┤
│  Host: x86_64 Linux                      │
│  Target: ARMv7 Alpine Linux (musl)       │
│  Toolchain: arm-linux-musleabihf-gcc     │
│  Emulator: QEMU (optional)               │
└─────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│        CMake Build Process               │
├─────────────────────────────────────────┤
│  1. Configure (cmake)                    │
│  2. Compile (make)                       │
│  3. Link (static/dynamic)                │
│  4. Package (create update .zip)         │
└─────────────────────────────────────────┘
```

### Build Requirements

- CMake 3.10+
- ARM cross-compiler (musl-based)
- Alpine Linux ARM rootfs (for linking)
- Optional: QEMU for testing

### Key Build Options

```cmake
# Example CMake configuration
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER arm-linux-musleabihf-gcc)
set(CMAKE_CXX_COMPILER arm-linux-musleabihf-g++)
set(CMAKE_SYSROOT /path/to/alpine-arm-rootfs)

# Enable extensions
option(ENABLE_FT8 "Build FT8 extension" ON)
option(ENABLE_WSPR "Build WSPR extension" ON)
option(ENABLE_DRM "Build DRM extension" ON)
```

## Performance Characteristics

### Throughput

| Metric | Value |
|--------|-------|
| ADC Sample Rate | 130 MSPS |
| Total Data Rate | ~260 MB/s (raw) |
| Network Throughput | ~100 Mbps (typical) |
| Concurrent Users | Up to 13 |
| Audio Latency | ~100-300 ms |
| Waterfall Update | 10-20 fps |

### Resource Usage

| Resource | Usage |
|----------|-------|
| CPU (ARM) | ~20-50% (varies with load) |
| Memory | ~100-150 MB |
| FPGA Resources | ~70-80% utilization |
| Network (per user) | ~50-100 kbps |

### AXI bus + CPU/channel (recovered figures — treat as estimates, not measured)

The FPGA is reached over four AXI ports from the PS: one GP master (config
registers) + three HP ports (RX DMA + two WF DMA). Reported bandwidth split:

- **RX DMA (HP0):** ~4.992 Mbps (13 channels × 12 kHz × 32-bit)
- **WF DMA (HP1/HP2):** up to ~3.9 Gbps (time-multiplexed waterfall)

CPU cost of DMA (vs KiwiSDR's constant-polling PRU+SPI): roughly **~3% per RX
channel** with the kernel-driver model — extensions can use blocking APIs
since the kernel scheduler, not user-mode strict timing, drives data movement.
*(These numbers are recovered/reported, not independently measured on this
unit; verify before relying on them.)*

## Differences from KiwiSDR Software

| Aspect | KiwiSDR | Web-888 (RaspSDR) |
|--------|---------|-------------------|
| **Platform** | BeagleBone (ARMv7) | Zynq (ARMv7) |
| **OS** | Debian | Alpine Linux |
| **libc** | glibc | musl |
| **Kernel Driver** | PRU-based (SPI) | Linux kernel module (DMA) |
| **Scheduler** | User-mode (PRU) | pthread (kernel) |
| **Threads** | PRU-based | Native pthreads |
| **GPS** | SDR-based (software) | Hardware module |
| **Clock** | Fixed | Tunable (Si5351) |
| **Build System** | Makefile | CMake |
| **Updates** | Source compile (10+ min) | Binary (10 sec) |
| **Extensions** | Kiwi extensions | Modified/added extensions |
| **TDoA** | Supported | Not supported |

## References

- [Alpine Linux Documentation](https://docs.alpinelinux.org/)
- [KiwiSDR Architecture](http://www.kiwisdr.com/info)
- [OpenWebRX Project](https://github.com/jketterl/openwebrx)
- [WebSocket Protocol (RFC 6455)](https://tools.ietf.org/html/rfc6455)
- [Web Audio API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API)
