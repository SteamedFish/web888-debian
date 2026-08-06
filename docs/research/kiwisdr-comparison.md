# Web-888 vs KiwiSDR Comparison

## Overview

The Web-888 (RX-888 hardware + RaspSDR software) is derived from the KiwiSDR project but represents a significant evolution in both hardware and software. This document provides a detailed comparison between the two systems.

## Quick Comparison Table

| Feature | KiwiSDR | Web-888 (RX-888) |
|---------|---------|------------------|
| **Status** | Active development | Active development |
| **Creator** | John Seamons (jks-prv) | RaspSDR team |
| **Hardware Platform** | BeagleBone Black/Green | Custom Zynq-7010 board |
| **ADC** | LTC2248 (14-bit, 66.67 MSPS) | LTC2208 (16-bit, 130 MSPS) |
| **FPGA** | Artix-7 A35 | Artix-7 (in Zynq) |
| **RX Channels** | 4 | 13 |
| **Waterfall Channels** | 4 | 13 |
| **Frequency Range** | 0-30 MHz (HF only) | 0-62 MHz (HF) + 118-150 MHz (VHF) |
| **GPS** | SDR-based (software MAX2769B) | Hardware module (ATGM336H) |
| **Network** | 100 Mbps Ethernet | 1000 Mbps Ethernet |
| **Memory** | 512MB DDR3 | 256MB DDR3 (official) / 512MB observed |
| **OS** | Debian | Alpine Linux 3.20 |
| **libc** | glibc | musl |
| **Update Time** | 10-15 minutes (compile) | 10 seconds (binary) |
| **Price** | $299 (board only) | ~$150-200 (complete) |

## Hardware Comparison

### System Architecture

#### KiwiSDR
```
BeagleBone Black/Green
    │
    ├─ AM3358 (ARM Cortex-A8 @ 1GHz)
    ├─ 512MB DDR3
    ├─ PRU (Programmable Realtime Unit)
    │
    ├─ KiwiSDR Cape
    │   ├─ LTC2248 ADC (14-bit, 66.67MSPS)
    │   ├─ Artix-7 A35 FPGA
    │   ├─ MAX2769B GPS frontend (SDR-based)
    │   └─ 100M Ethernet (via BeagleBone)
```

#### Web-888
```
RX-888 Board
    │
    ├─ Zynq XC7Z010
    │   ├─ Dual ARM Cortex-A9 @ 667MHz
    │   ├─ Artix-7 FPGA (28K cells)
    │   └─ 512MB DDR3 (officially 256MB)
    │
    ├─ LTC2208 ADC (16-bit, 130MSPS)
    ├─ Si5351 Clock Generator
    ├─ ATGM336H GPS (hardware)
    ├─ AD8370 ATT (x2)  (identity disputed — likely PE4312)
    └─ 1000M Ethernet (dedicated)
```

### ADC Comparison

| Parameter | KiwiSDR (LTC2248) | Web-888 (LTC2208) |
|-----------|-------------------|-------------------|
| Resolution | 14 bits | 16 bits |
| Sampling Rate | 66.67 MSPS | 130 MSPS |
| SNR | 72.3 dB | 78 dB |
| SFDR | 85 dB | 98 dB |
| Input Bandwidth | 500 MHz | 700 MHz |
| ENOB | ~11.5 bits | ~12.7 bits |

**Impact**: The Web-888's better ADC provides:
- Lower noise floor
- Better dynamic range
- Ability to see weaker signals
- Better intermodulation performance

### FPGA Channel Capacity

#### KiwiSDR (4 Channels)
```
FPGA (Artix-7 A35)
├─ 4 DDC Channels
│  ├─ Each: NCO + Mixer + CIC + FIR
│  └─ Bandwidth: Configurable up to ~12kHz
│
├─ 4 Waterfall Channels
│  └─ FFT-based spectrum display
│
└─ SPI Interface to BeagleBone PRU
    └─ PRU manages real-time scheduling
```

#### Web-888 (13 Channels)
```
FPGA (Artix-7 in Zynq)
├─ 13 DDC Channels
│  ├─ Each: NCO + Mixer + CIC + FIR
│  ├─ Bandwidth: 12/24/36 kHz options
│  └─ More efficient resource usage
│
├─ 2 Hardware Waterfall Channels
│  └─ Time-multiplexed to 13 virtual channels
│
└─ DMA Controllers (AXI4)
    └─ Direct to DDR, no CPU involvement
```

**Key Difference**: Web-888 uses DMA for zero-copy data transfer, while KiwiSDR uses SPI through the PRU, limiting bandwidth.

### GPS Systems

#### KiwiSDR (SDR-Based GPS)
```
MAX2769B GPS Frontend
    │
    ├─ RF front-end (L1 band)
    ├─ AGC and filtering
    └─ ADC sampling
         │
         ▼
FPGA (software-defined GPS)
    ├─ Digital downconversion
    ├─ Correlation engine
    ├─ Navigation solution
    └─ PPS generation
```

**Pros**:
- Educational value (visible GPS processing)
- Flexible (can modify algorithms)

**Cons**:
- Higher CPU usage
- Slower lock time
- Less sensitive
- More complex

#### Web-888 (Hardware GPS)
```
ATGM336H Module
    │
    ├─ Complete GPS receiver
    ├─ Multi-constellation
    ├─ NMEA output via UART
    ├─ PPS output to FPGA
    └─ Built-in navigation solution
```

**Pros**:
- Fast lock time
- Better sensitivity (-162 dBm tracking)
- Lower CPU usage
- Multi-constellation (GPS, GLONASS, BDS, GALILEO)
- Simpler software

**Cons**:
- Black box (can't modify algorithms)
- Additional cost

## Software Comparison

### Operating System

| Aspect | KiwiSDR | Web-888 |
|--------|---------|---------|
| **Distribution** | Debian | Alpine Linux |
| **Version** | Debian 10/11 | Alpine 3.20 |
| **libc** | glibc | musl |
| **Size** | ~1GB | ~300MB |
| **Package Manager** | apt | apk |
| **Init System** | systemd | OpenRC |
| **Kernel** | Custom 4.x | Custom 6.6 |

**Impact**:
- Alpine is smaller and more secure
- musl is lighter than glibc
- Smaller attack surface
- Faster boot times

### FPGA Interface

#### KiwiSDR (PRU + SPI)
```
┌─────────────────────────────────────────┐
│ KiwiSDR Data Flow                       │
│                                         │
│  FPGA → SPI → PRU → Shared Memory → CPU │
│                                         │
│  PRU (Programmable Realtime Unit)       │
│  - Custom real-time scheduler           │
│  - Bit-banged SPI at high speed         │
│  - User-mode to kernel transition       │
│  - Latency: ~100μs                      │
└─────────────────────────────────────────┘
```

**Limitations**:
- SPI bandwidth limits channel count
- PRU programming complexity
- Real-time constraints on scheduling
- Context switch overhead

#### Web-888 (DMA)
```
┌─────────────────────────────────────────┐
│ Web-888 Data Flow                       │
│                                         │
│  FPGA → AXI DMA → DDR Memory → CPU      │
│                                         │
│  DMA (Direct Memory Access)             │
│  - Hardware-managed transfers           │
│  - No CPU involvement during transfer   │
│  - Interrupt-driven                     │
│  - Latency: ~10μs                       │
└─────────────────────────────────────────┘
```

**Advantages**:
- Higher bandwidth (supports 13 channels)
- Lower latency
- Less CPU overhead
- Simpler software architecture

### Threading Model

#### KiwiSDR
```
KiwiSDR Threading:
├─ Main Thread (HTTP/WebSocket)
├─ PRU Thread (real-time)
├─ GPS Thread (SDR-based)
├─ Per-user Audio Threads (4 max)
└─ Extension Threads (varies)

Scheduler: User-mode PRU-based
```

#### Web-888
```
Web-888 Threading:
├─ Main Thread (HTTP/WebSocket)
├─ DMA Interrupt Handler
├─ GPS Thread (hardware)
├─ Per-user Audio Threads (13 max)
├─ Waterfall Threads
└─ Extension Threads (varies)

Scheduler: Linux pthread (kernel)
```

### Update System

#### KiwiSDR (Source-Based)
```
Update Process (10-15 minutes):
1. Download source code
2. Stop running server
3. Compile (gcc, make)
4. Link libraries
5. Install new binary
6. Restart server

Problems:
- Slow update process
- Compilation can fail
- Requires build tools on device
- Risk of partial updates
```

#### Web-888 (Binary-Based)
```
Update Process (10 seconds):
1. Download binary package
2. Stop running server
3. Replace binary (atomic)
4. Restart server

Advantages:
- Fast updates
- Atomic replacement
- No build tools needed
- Consistent binaries
- Rollback possible
```

### Build System

| Aspect | KiwiSDR | Web-888 |
|--------|---------|---------|
| **Build Tool** | Make | CMake |
| **Cross-compile** | Difficult | Supported |
| **Dependencies** | Many | Minimal (static linking) |
| **Build Time** | 10-15 min on device | Cross-compile in seconds |
| **Binary Size** | ~5-10 MB (dynamic) | ~15 MB (static) |

## Feature Comparison

### Receive Channels

| Feature | KiwiSDR | Web-888 |
|---------|---------|---------|
| **Max Simultaneous Users** | 4 | 13 |
| **Max Waterfall Channels** | 4 | 13 |
| **Bandwidth Options** | Fixed | 12/24/36 kHz |
| **Decoding Capacity** | 4 simultaneous | 13 simultaneous |

### Frequency Coverage

| Band | KiwiSDR | Web-888 |
|------|---------|---------|
| **VLF** (0-30 kHz) | ✓ | ✓ |
| **LF** (30-300 kHz) | ✓ | ✓ |
| **MF** (300 kHz-3 MHz) | ✓ | ✓ |
| **HF** (3-30 MHz) | ✓ | ✓ |
| **Low VHF** (30-62 MHz) | ✗ | ✓ |
| **Air Band** (118-137 MHz) | ✗ | ✓ |
| **VHF** (137-150 MHz) | ✗ | ✓ |

### Extensions Support

Both systems support similar extensions, but with some differences:

| Extension | KiwiSDR | Web-888 | Notes |
|-----------|---------|---------|-------|
| ALE_2G | ✓ | ✓ | Automatic Link Establishment |
| ant_switch | ✓ | ✓ | Antenna switching |
| CW_decoder | ✓ | ✓ | Morse code decoder |
| CW_skimmer | ✗ | ✓ | CW contesting (new in Web-888) |
| DRM | ✓ | ✓ | Digital Radio Mondial |
| FAX | ✓ | ✓ | Weather fax |
| FFT | ✓ | ✓ | FFT display |
| FSK | ✓ | ✓ | RTTY/FSK decoder |
| FT8 | ✓ | ✓ | FT8 mode |
| HFDL | ✓ | ✓ | High Frequency Data Link |
| IBP_scan | ✓ | ✓ | Beacon scanner |
| IQ_display | ✓ | ✓ | IQ constellation |
| Loran_C | ✓ | ✓ | Loran-C navigation |
| NAVTEX | ✓ | ✓ | Maritime safety |
| SSTV | ✓ | ✓ | Slow-scan TV |
| S_meter | ✓ | ✓ | Signal meter |
| TDoA | ✓ | ✗ | Direction finding (not in Web-888) |
| waterfall | ✓ | ✓ | Extended waterfall |
| wspr | ✓ | ✓ | WSPR mode |
| noise_blank | ✓ | ✓ | Noise blanker |
| noise_filter | ✓ | ✓ | Noise filter |
| MQTT | ✗ | ✓ | IoT integration (new in Web-888) |

**Missing in Web-888**:
- TDoA extension (major omission for direction finding)

**New in Web-888**:
- CW Skimmer
- MQTT support
- More bandwidth options

## Web Interface Comparison

### UI Similarities

Both systems share:
- OpenWebRX-based interface
- Waterfall display with zoom
- Click-to-tune
- Multiple demodulation modes
- Extension panels
- Admin interface

### UI Differences

| Feature | KiwiSDR | Web-888 |
|---------|---------|---------|
| **Max Waterfalls** | 4 | 13 |
| **Bandwidth Options** | Limited | 12/24/36 kHz |
| **Theme** | Dark | Dark (slightly different) |
| **Mobile Support** | Basic | Basic |
| **Config Page** | Simple | More options |

### Performance

| Metric | KiwiSDR | Web-888 |
|--------|---------|---------|
| **Page Load Time** | ~2-3 sec | ~2-3 sec |
| **Waterfall FPS** | ~10-15 | ~15-20 |
| **Audio Latency** | ~200-300ms | ~100-200ms |
| **Tuning Response** | ~100ms | ~50ms |

## Network and Connectivity

### Ethernet

| Feature | KiwiSDR | Web-888 |
|---------|---------|---------|
| **Speed** | 100 Mbps | 1000 Mbps |
| **Throughput** | ~50 Mbps | ~500 Mbps |
| **Concurrent Streams** | 4 x ~12kHz | 13 x ~36kHz |

**Impact**: Web-888 can handle many more simultaneous high-bandwidth users.

### Reverse Proxy

Both systems support reverse proxy for easy remote access:

- **KiwiSDR**: Built-in reverse proxy (kiwisdr.com proxy)
- **Web-888**: FRP (Fast Reverse Proxy) integration

## Power and Physical

### Power Requirements

| Parameter | KiwiSDR | Web-888 |
|-----------|---------|---------|
| **Voltage** | 5V | 5V |
| **Current** | ~2A | ~2A |
| **Power** | ~10W | ~10W |
| **Connector** | Barrel jack | Barrel jack / USB-C |
| **Reverse Polarity** | No protection | Protected (v2+) |

### Physical

| Parameter | KiwiSDR | Web-888 |
|-----------|---------|---------|
| **Form Factor** | BeagleBone + Cape | Single PCB |
| **Size** | ~86 x 55mm (BBB) + cape | ~100 x 80mm |
| **Enclosure** | Available | Available |
| **Antenna** | Single SMA | Dual SMA (HF/VHF) + GPS |

## Development and Community

### Source Code Availability

| Aspect | KiwiSDR | Web-888 |
|--------|---------|---------|
| **License** | Simplified BSD | Simplified BSD (derived) |
| **GitHub** | jks-prv/Beagle_SDR_GPS | RaspSDR/server |
| **Status** | Active | Active |
| **Last Update** | Jan 2025 | Active (2026) |
| **Contributors** | John Seamons | RaspSDR team |

### Community

| Aspect | KiwiSDR | Web-888 |
|--------|---------|---------|
| **Forum** | forum.kiwisdr.com | Limited |
| **Documentation** | Extensive | Growing |
| **Public Stations** | 700+ | Growing |
| **User Base** | Large | Growing |

## Price Comparison

### KiwiSDR (Discontinued)

| Component | Price |
|-----------|-------|
| KiwiSDR Board | $299 |
| BeagleBone Green | ~$50 |
| Enclosure | ~$30 |
| GPS Antenna | ~$15 |
| **Total** | **~$395** |

### Web-888

| Component | Price |
|-----------|-------|
| RX-888 Board | ~$150-200 |
| Enclosure | ~$20-30 |
| GPS Antenna | ~$10 |
| Power Supply | ~$10 |
| **Total** | **~$190-250** |

**Web-888 is significantly more cost-effective** while offering more features.

## Migration from KiwiSDR to Web-888

### What Stays the Same

- Web interface look and feel
- Extension system
- Admin configuration
- Most user workflows
- DX cluster integration

### What Changes

1. **More channels**: 4 → 13 users
2. **VHF support**: New air band capability
3. **Update process**: 15 min → 10 sec
4. **GPS**: Faster lock, multi-constellation
5. **No TDoA**: Direction finding not available

### Configuration Migration

Most configuration is compatible:
- `dx.json` (station database): Compatible
- User settings: Need manual transfer
- Extensions config: Mostly compatible
- Network settings: May differ

## Recommendation

### Choose KiwiSDR if:

- You already own one (continue using it)
- You need TDoA direction finding
- You want to study SDR-based GPS
- You prefer the original creator's support

**Note**: KiwiSDR 2 is now in production as of 2024. The project moved from the old Beagle_SDR_GPS repository to the new KiwiSDR repository.

### Choose Web-888 if:

- You're buying new
- You need more than 4 channels
- You want VHF/air band coverage
- You prefer faster updates
- You want better value for money
- You need reliable hardware GPS

## Conclusion

The Web-888 represents a significant evolution over KiwiSDR:

**Advantages**:
- More channels (13 vs 4)
- Better hardware GPS
- VHF support
- Faster updates
- Lower cost
- Active development
- Better ADC performance

**Disadvantages**:
- Missing TDoA extension
- Smaller community (currently)
- Less documentation (growing)

**Overall**: The Web-888 is a superior platform for most use cases, offering significantly more capability at a lower price point.

## References

- [KiwiSDR Official Site](http://www.kiwisdr.com)
- [KiwiSDR GitHub](https://github.com/jks-prv/Beagle_SDR_GPS)
- [Web-888 Official Site](https://www.rx-888.com/web/)
- [RaspSDR GitHub](https://github.com/RaspSDR)
- [KiwiSDR Forum](http://forum.kiwisdr.com)
