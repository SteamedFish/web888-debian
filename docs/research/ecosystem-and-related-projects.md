# Web-888 Ecosystem and Related Projects

## Overview

The Web-888 platform has an expanding ecosystem of related projects and tools. This document catalogs all known repositories, software, and hardware projects related to the Web-888/RX-888 platform.

## Official RaspSDR Repositories

### Core Repositories

#### 1. server (RaspSDR/server)
- **Purpose:** Main web server and SDR application
- **Language:** C++
- **License:** Not specified (fork of KiwiSDR)
- **Status:** Active development
- **Documentation:** [software-architecture.md](software-architecture.md)

**Key Features:**
- 13-channel receiver
- 27 built-in extensions
- Web-based interface
- Binary update system

#### 2. rx888 (RaspSDR/rx888)
- **Purpose:** Host software and firmware for RX-888 USB interface
- **Language:** Rust
- **License:** Not specified
- **Status:** Active development

**Contents:**
- `firmware/RX888_FW.img` - Cypress FX3 USB firmware image
- Rust host driver library
- CMake build configuration

**Use Case:** Direct USB control of RX-888 hardware without web server

#### 3. red-pitaya-notes (RaspSDR/red-pitaya-notes)
- **Purpose:** Alternative firmware for Red Pitaya boards
- **Language:** C, Tcl
- **License:** MIT
- **Status:** Maintenance mode

**Contents:**
- SDR receiver applications
- HPSDR (Hermes) emulation
- FT8/WSPR transceivers
- GNU Radio integration

### Extension and Tool Repositories

#### 4. wsjtx (RaspSDR/wsjtx)
- **Purpose:** WSJT-X fork optimized for Web-888
- **Language:** C++
- **License:** GPL-3.0
- **Status:** Fork maintenance

**Integration:** Provides native FT8/WSPR encoding/decoding

#### 5. dumphfdl (RaspSDR/dumphfdl)
- **Purpose:** Multichannel HFDL decoder
- **Language:** C
- **License:** GPL-3.0
- **Status:** Active

**Integration:** Used by HFDL extension for ACARS message decoding

#### 6. gpsdo (RaspSDR/gpsdo)
- **Purpose:** External GPSDO hardware design
- **Hardware:** Raspberry Pi Pico
- **License:** GPL-3.0
- **Status:** Hardware design complete

**Contents:**
- PCB Gerber files
- Schematics (PDF)
- Bill of Materials (Excel)
- 3D renderings
- Interactive BOM

**Purpose:** Standalone high-precision GPSDO for improved frequency accuracy

### Client Applications

#### 7. supersdr (RaspSDR/supersdr)
- **Purpose:** Advanced Python client with CAT integration
- **Language:** Python
- **License:** Not specified (fork of mcogoni/supersdr)
- **Status:** Active

**Key Features:**
- Real-time spectrum waterfall
- Dual audio receivers
- CAT radio integration (hamlib)
- Keyboard shortcuts
- Multiple KiwiSDR/Web-888 connections
- Low CPU usage
- QRZ.com integration

**Installation:**
```bash
pip install -r requirements.txt
./supersdr.py --server <device-ip> --port 8073
```

**CAT Radio Integration:**
```bash
# Start rigctld for Kenwood TS-590SG
rigctld -m 237 -r /dev/ttyUSB0

# Connect SuperSDR with CAT
./supersdr.py --server <device-ip> --port 8073 -S <rigctld-host> -P 4532
```

**Keyboard Shortcuts:**
| Key | Function |
|-----|----------|
| Left/Right | Tune ±1 kHz (±100 Hz when zoomed) |
| Shift + Left/Right | Tune ±10 kHz |
| Up/Down | Zoom in/out (2X steps) |
| Page Up/Down | Move spectrum center |
| Space | Return to RX frequency |
| S | Toggle CAT sync |
| Y | Switch between dual receivers |
| M | Mute/unmute |
| Z | Center tuning mode |
| G/H | Increase/decrease waterfall averaging |
| J/K | Adjust filter bandpass |
| 1/2 | Adjust AGC threshold |
| 3 | Toggle auto spectrum levels |
| X | Toggle auto RX mode |
| Q | Change KiwiSDR server |

#### 8. SDR-888 (RaspSDR/SDR-888)
- **Purpose:** Cross-platform SDR software (SDR++ fork)
- **Language:** C++
- **License:** GPL-3.0
- **Status:** Active development

**Features:**
- Native desktop application
- Web-888 hardware support
- Spectrum analyzer
- Multiple demodulators

### Hardware Support

#### 9. ExtIO_sddc (RaspSDR/ExtIO_sddc)
- **Purpose:** ExtIO plugin for HDSDR
- **Language:** C
- **License:** Not specified
- **Status:** Legacy

**Use Case:** Windows SDR software integration via ExtIO interface

#### 10. TRX_DUO_125-16 (RaspSDR/TRX_DUO_125-16)
- **Purpose:** Red Pitaya transceiver variant
- **Language:** Tcl
- **License:** MIT
- **Status:** Archived

## Third-Party Tools and Integration

### SDR Software with Web-888 Support

| Software | Type | Platform | Notes |
|----------|------|----------|-------|
| SDR++ | Desktop | Win/Linux/Mac | Via SDR-888 fork |
| HDSDR | Desktop | Windows | Via ExtIO_sddc |
| SuperSDR | Desktop | Python | Official RaspSDR fork |
| Quisk | Desktop | Python | Via network interface |
| Linrad | Desktop | Linux | Network interface |

### Programming Libraries

#### Python
```python
# KiwiSDR client library (works with Web-888)
from kiwiclient import KiwiSDRClient

client = KiwiSDRClient('<device-ip>', 8073)
client.set_frequency(14074000)
client.set_mode('USB')
```

#### Rust
```rust
// rx888 crate
use rx888::Rx888;

let device = Rx888::open()?;
device.set_frequency(10000000)?;
```

### Network Protocol Libraries

Web-888 uses the KiwiSDR network protocol, so any KiwiSDR client library works:

- **kiwiclient** (Python)
- **KiwiSDR-Java** (Java)
- **kiwisdr_js** (JavaScript/Node.js)

## Public Server Lists

### Web-888 Public Servers
- **URL:** https://www.rx-888.com/web/public.html
- **API:** Server list provided for SuperSDR integration
- **Coverage:** Global Web-888 receivers

### KiwiSDR Public Servers
- Compatible with Web-888
- Lists at:
  - https://rx.kiwisdr.com/
  - http://kiwisdr.com/public/

## Hardware Accessories

### GPSDO Options

1. **Internal GPSDO**
   - ATGM336H module (built-in)
   - Si5351 clock generator
   - "Poor man's GPSDO" via software

2. **External GPSDO (RaspSDR/gpsdo)**
   - Raspberry Pi Pico-based
   - Higher precision reference
   - Standalone operation
   - Full hardware design available

### Antenna Systems

Recommended configurations:
- **HF:** Wideband active antenna or dipole
- **VHF:** Discone or J-pole
- **Dual-input:** Separate HF and VHF antennas

## Development Tools

### FPGA Development

**Current Status:**
- FPGA bitstreams are prebuilt binaries
- No public source code available for Web-888 FPGA
- Based on Xilinx Zynq-7010 (XC7Z010)
- Vivado 2023.1 used for builds

**Related Open Source FPGA Projects:**
- Pavel Demin's Red Pitaya projects (similar architecture)
- OpenHPSDR FPGA code (Hermes protocol)

### Kernel Development

**Source:** Linux 6.6 with custom drivers
- LTC2208 ADC driver
- DMA controller driver
- GPIO control for antenna switching

### Cross-Compilation

**Recommended Environment:**
- Alpine Linux 3.20 ARM chroot
- QEMU for x86_64 → ARM emulation
- CMake 3.13+
- ARM GCC toolchain

## Community Resources

### Forums and Discussion

1. **Raspberry Pi SDR Community**
   - KiwiSDR forums (applicable to Web-888)
   - Reddit r/RTLSDR
   - QRZ.com forums

2. **Chinese Communities**
   - rx-888.com support
   - WeChat groups (contact support@rx-888.com)

### Documentation

1. **Official**
   - https://www.rx-888.com/web/ - Product page
   - https://www.rx-888.com/web/dochub.html - Documentation

2. **GitHub Wiki**
   - Individual repository documentation
   - README files in each repo

### Support Channels

- **Email:** support@rx-888.com
- **GitHub Issues:** Individual repositories
- **Website:** Contact form at rx-888.com

## Integration Examples

### Example 1: Automated Monitoring Station

```python
#!/usr/bin/env python3
"""
Automated Web-888 monitoring with FT8 spotting
"""
from ft8 import FT8Watcher
from kiwiclient import KiwiSDRClient

client = KiwiSDRClient('<device-ip>', 8073)
watcher = FT8Watcher(client)

# Monitor 20m FT8 frequency
watcher.monitor(14074000, 'FT8')

# Callback on decode
def on_spot(spot):
    print(f"{spot['time']} {spot['callsign']} {spot['grid']} "
          f"{spot['snr']}dB")

watcher.on_decode = on_spot
watcher.run()
```

### Example 2: Spectrum Logger

```python
#!/usr/bin/env python3
"""
Log spectrum data from Web-888
"""
import json
import time
from kiwiclient import KiwiSDRClient

client = KiwiSDRClient('<device-ip>', 8073)
client.connect()

# Record spectrum every minute
with open('spectrum_log.jsonl', 'w') as f:
    while True:
        spectrum = client.get_spectrum()
        record = {
            'timestamp': time.time(),
            'center_freq': client.frequency,
            'spectrum': spectrum.tolist()
        }
        f.write(json.dumps(record) + '\n')
        time.sleep(60)
```

### Example 3: CAT Radio Integration

```python
#!/usr/bin/env python3
"""
Sync Web-888 with CAT radio using hamlib
"""
import Hamlib
from kiwiclient import KiwiSDRClient

# Initialize radio
Hamlib.rig_set_debug(Hamlib.RIG_DEBUG_NONE)
rig = Hamlib.Rig(Hamlib.RIG_MODEL_TS590S)
rig.set_conf("rig_pathname", "/dev/ttyUSB0")
rig.open()

# Connect to Web-888
kiwi = KiwiSDRClient('<device-ip>', 8073)
kiwi.connect()

# Sync frequency
while True:
    radio_freq = rig.get_freq()
    kiwi.set_frequency(int(radio_freq))
    time.sleep(0.5)
```

## Project Status and Roadmap

### Active Development (2025)

| Component | Status | Priority |
|-----------|--------|----------|
| server | Active | High |
| rx888 | Active | Medium |
| SDR-888 | Active | Medium |
| supersdr | Maintenance | Low |
| gpsdo | Complete | Low |

### Known Limitations

1. **FPGA Source:** Not publicly available
2. **Documentation:** Primarily in English/Chinese
3. **Third-party Clients:** Limited compared to KiwiSDR
4. **Mobile App:** No native mobile application

## Comparison with Related Projects

| Project | Web-888 | KiwiSDR | Red Pitaya |
|---------|---------|---------|------------|
| Channels | 13 | 4 | 1-8 |
| ADC Bits | 16 | 14 | 14 |
| Max Sample Rate | 130 MSPS | 66.67 MSPS | 125 MSPS |
| FPGA | Zynq-7010 | Artix-7 | Zynq-7010 |
| GPS | Hardware | Software | Optional |
| Web Interface | Yes | Yes | No |
| Price | $200-300 | $300-400 | $200 + addons |

## Contributing

### How to Contribute

1. **Report Issues:** GitHub issues in relevant repositories
2. **Documentation:** Improve docs, translations
3. **Extensions:** Develop new signal decoders
4. **Testing:** Test on different platforms
5. **Hardware:** Design accessories and modifications

### Code Contributions

**Preferred Languages:**
- C++ (server, extensions)
- Rust (rx888 host software)
- Python (tools, clients)
- JavaScript (web interface)

**Development Guidelines:**
- Follow existing code style
- Test on actual hardware
- Document new features
- Add to CHANGELOG

## References

- [RaspSDR GitHub Organization](https://github.com/RaspSDR)
- [Web-888 Product Page](https://www.rx-888.com/web/)
- [KiwiSDR Project](https://github.com/jks-prv/Beagle_SDR_GPS)
- [Red Pitaya Notes](https://pavel-demin.github.io/red-pitaya-notes/)
- [SuperSDR Original](https://github.com/mcogoni/supersdr)
- [SDR++ Project](https://github.com/AlexandreRouma/SDRPlusPlus)

---

*Document version: 2026-03-31*
