# Web-888 Hardware Reference

> **Trust level:** AI-generated reverse-engineering material. For facts
> **verified live on this device**, see
> [`hardware-facts.md`](hardware-facts.md) — trust it first when they conflict.
> This doc consolidates the former `hardware-specifications.md`,
> `hardware-pinout-reference.md`, and `gpsdo-implementation.md` (component
> specs, the FPGA package-pin map, connectors, clock domains, and the GPSDO
> algorithm). Numbers not marked "verified" are datasheet/RE-derived and
> should be re-checked before relying on them.

## Overview

The Web-888 (a.k.a. RX-888) is a web-accessible SDR receiver built around the
Xilinx Zynq-7010 SoC. It is a significant hardware evolution of the original
KiwiSDR: more receive channels, dual-band (HF + VHF) operation, and hardware GPS.

```
┌─────────────────────────────────────────────────────────────────┐
│                        RX-888 SYSTEM                            │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │   HF Input  │    │  VHF Input  │    │    GPS Antenna      │  │
│  │  (0-62MHz)  │    │ (118-150MHz)│    │                     │  │
│  └──────┬──────┘    └──────┬──────┘    └──────────┬──────────┘  │
│         │                  │                      │             │
│         ▼                  ▼                      ▼             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │  DSA (HF)   │    │  DSA (VHF)  │    │    ATGM336H         │  │
│  │  ATT        │    │  ATT        │    │  Multi-GNSS Module  │  │
│  └──────┬──────┘    └──────┬──────┘    │  (BDS/GPS/GLONASS/  │  │
│         └────────┬─────────┘           │   GALILEO)          │  │
│                  ▼                     └──────────┬──────────┘  │
│         ┌─────────────────┐◄──────┐               │             │
│         │   LTC2208       │       │               │             │
│         │   16-bit ADC    │    ┌──┴───────────────┘             │
│         │   130 MSPS      │    │  Si5351 Clock Generator        │
│         └────────┬────────┘    │  (Tunable ADC Clock)           │
│                  ▼             └─────────────────┘             │
│         ┌─────────────────┐                                    │
│         │  Zynq XC7Z010   │                                    │
│         │  ┌───────────┐  │  ← 13 RX Channels (DDC)           │
│         │  │  FPGA     │  │  ← 2 WF Channels (TDM)            │
│         │  └─────┬─────┘  │                                    │
│         │  ┌─────┴─────┐  │                                    │
│         │  │  ARM A9   │  │  ← Linux 6.6                      │
│         │  │ (Dual)    │  │                                    │
│         └────────┼────────┘                                    │
│                  ▼                                             │
│         ┌─────────────────┐    ┌─────────────┐                │
│         │  512MB DDR3     │◄──►│  1000M      │                │
│         │  Memory         │    │  Ethernet   │                │
│         └─────────────────┘    └─────────────┘                │
└─────────────────────────────────────────────────────────────────┘
```

## Main components

### SoC — Xilinx Zynq-7000 XC7Z010-1CLG400C

| Feature | Specification |
|---------|--------------|
| Processor | Dual-core ARM Cortex-A9 MPCore @ 667 MHz (NEON SIMD) |
| FPGA | Artix-7 equivalent (28K logic cells) |
| Package | CLG400 (400-pin BGA), 28nm |
| L2 cache | 512 KB; double-precision FPU |
| Peripherals | DDR3/DDR3L ctrl, dual tri-speed GbE, USB 2.0 OTG + host, dual SD/SDIO, dual SPI/Quad-SPI/NAND/NOR, 2× UART, 2× CAN 2.0B, 2× I2C |

### ADC — Linear Technology LTC2208

| Parameter | Specification |
|-----------|---------------|
| Resolution | 16 bits |
| Sampling rate | 130 MSPS (configurable via Si5351) |
| Input bandwidth | 700 MHz (−3 dB) |
| SNR | 78 dBFS @ 70 MHz input |
| SFDR | 98 dB @ 70 MHz input |
| Power | ~1 W, 64-pin QFN |

### Clock generator — Si5351

| Feature | Specification |
|---------|---------------|
| Type | I2C-programmable clock generator (I2C @0x60) |
| Outputs | 3 independent PLL outputs (CLK0 = ADC clock, CLK2 = external clock out) |
| Frequency range | 8 kHz – 160 MHz |
| Reference | 24.576 MHz TCXO (or external 10 MHz via GPIO IO_49) |
| Purpose | tunable ADC sampling rate, GPSDO frequency correction, VHF support |

> **Variant note:** the chip is referenced as "Si5351A" in some docs and
> "Si5351C" in the GPSDO doc; the exact variant on this board is **unverified**.
> Treat either label as tentative until board inspection.

### GPS — ATGM336H multi-GNSS

| Feature | Specification |
|---------|---------------|
| Constellations | BDS, GPS, GLONASS, GALILEO |
| Channels | 32 tracking |
| Sensitivity | −148 dBm (cold start), −162 dBm (tracking) |
| Update rate | up to 10 Hz |
| PPS output | yes (timing sync) |
| Interface | UART to Zynq PS; external active antenna (3.3 V bias) |

### Digital step attenuators (DSA) — labeled "AD8370", actually PE4312

Two attenuators give independent gain control for HF and VHF paths.

| Parameter | Specification |
|-----------|---------------|
| Type | 6-bit digital step attenuator (3-wire serial, bit-banged on GPIOs 11/12/13) |
| Attenuation range | 0 to 31.5 dB |
| Resolution | 0.5 dB steps |
| Bandwidth | 700 MHz |

> **Naming dispute (resolved as PE4312):** the chip is labeled "AD8370" in the
> kernel driver name (`ad8370_driver.c`), the `AD8370_SET` ioctl, and older
> docs, but WebSDR userspace prints `Set PE4312 ...` and the 0–31.5 dB in
> 0.5 dB steps semantics match the PE4312 (the AD8370 is a *gain* VGA,
> −11…+34 dB). Full evidence chain and the "ad8370 ghost driver" explanation
> (the zynqsdr driver was compiled from a misnamed source file) are in
> [`zynqsdr-port-notes.md`](zynqsdr-port-notes.md) §12.

### Memory — 512 MB DDR3 (verified)

| Parameter | Value |
|-----------|-------|
| Type | DDR3 SDRAM, 16-bit, DDR3-1066 |
| Capacity | **512 MB verified** on this device (`MemTotal 509476 kB`, DT `reg = <0x0 0x20000000>`) |

> Some official marketing specs list 256 MB; the live device has 512 MB. (The
> Zynq-7010 supports up to 1 GB DDR3.) Allocation: OS+app ~100 MB, FPGA DMA
> buffers ~100 MB, user/cache ~312 MB.

### Networking

| Parameter | Specification |
|-----------|---------------|
| Interface | 10/100/1000 Mbps Ethernet |
| PHY | Realtek RTL8211E (PHY ID `0x001cc915`), MDIO addr 1 |
| Connector | RJ45 with magnetics, auto-MDIX, EEE |
| Protocols | IPv4/IPv6, TCP/UDP, HTTP, WebSocket |

## RF front-end

### HF path (0–62 MHz)
```
HF Antenna (SMA) → DSA ATT → 64 MHz anti-alias LPF → LTC2208 ADC
```
Covers VLF/LF (0–300 kHz, time/nav stations), MF (300 kHz–3 MHz, AM broadcast),
HF (3–30 MHz, shortwave/ham), low VHF (30–62 MHz).

### VHF path (118–150 MHz)
```
VHF Antenna (SMA) → DSA ATT → 129 MHz BPF → +20 dB LNA → LTC2208 ADC
```
Optimized for air band (118–137 MHz). The BPF is centred at **129 MHz**
(intentional, for optimal filter response); the ADC undersamples the 2nd
Nyquist zone.

### Antenna switching
HF/VHF/GPS each on SMA; HF/VHF selection via GPIO IO_10 (LOW=HF, HIGH=VHF).

## FPGA architecture

```
ADC (16-bit @ 122.88 MHz) → FPGA (Artix-7)
   ├─ Digital Down-Converters:  ADC → CIC decimator → FIR → IQ
   │   (13 user-tunable RX channels)
   ├─ Waterfall:                ADC → FFT → magnitude → decimation
   │   (2 hardware WF channels, time-multiplexed to 13 virtual)
   └─ Custom DMA controllers     (zero-copy to DDR via AXI4)
        → ARM (via AXI) → Ethernet (WebSocket streaming)
```

| Feature | Specification |
|---------|--------------|
| Total RX channels | 13 (independent receivers) |
| Waterfall channels | 13 virtual (TDM of 2 hardware) |
| Bandwidth per channel | 12/24/36 kHz (configurable) |
| Decimation | CIC + FIR cascade |
| Data format | I/Q complex baseband |
| FPGA utilization | ~80% (logic; near practical limit at 122.88 MHz) |

Each RX channel is a DDC: NCO → mixer → CIC decimator → FIR (CIC-droop
compensation + anti-alias) → I/Q formatter. WF uses FFT → magnitude → log →
TDM across the 2 hardware channels.

## Power supply

| Parameter | Specification |
|-----------|---------------|
| Input | 5 V DC, ~2 A typical (~10 W), USB-C |
| Minimum | **must stay above 4.75 V under load** (device fails below) |
| Cable | quality matters: cheap cables drop 0.5–1.0 V; use "Fast Charger" rated 2 A+ |
| Noise | switching PSUs add 20–170 kHz harmonics in LF/MF bands — linear supply best for LF/MF DXing |

Power modes (approx): idle ~0.5 A/2.5 W, 1 user ~1.0 A/5 W, 13 users peak ~1.5 A/7.5 W.

## FPGA pinout (PL pins — 3.3 V CMOS)

> **This package-pin map is the single most valuable RE asset for the board
> and exists nowhere else — preserve verbatim.**

```tcl
# ADC Data (16-bit parallel)
set_property PACKAGE_PIN V17 [get_ports {adc_dat_a_i[0]}]  ;# ADC D0
set_property PACKAGE_PIN U17 [get_ports {adc_dat_a_i[1]}]  ;# ADC D1
set_property PACKAGE_PIN Y17 [get_ports {adc_dat_a_i[2]}]  ;# ADC D2
set_property PACKAGE_PIN W16 [get_ports {adc_dat_a_i[3]}]  ;# ADC D3
set_property PACKAGE_PIN Y16 [get_ports {adc_dat_a_i[4]}]  ;# ADC D4
set_property PACKAGE_PIN W15 [get_ports {adc_dat_a_i[5]}]  ;# ADC D5
set_property PACKAGE_PIN W14 [get_ports {adc_dat_a_i[6]}]  ;# ADC D6
set_property PACKAGE_PIN Y14 [get_ports {adc_dat_a_i[7]}]  ;# ADC D7
set_property PACKAGE_PIN W13 [get_ports {adc_dat_a_i[8]}]  ;# ADC D8
set_property PACKAGE_PIN V12 [get_ports {adc_dat_a_i[9]}]  ;# ADC D9
set_property PACKAGE_PIN V13 [get_ports {adc_dat_a_i[10]}] ;# ADC D10
set_property PACKAGE_PIN T14 [get_ports {adc_dat_a_i[11]}] ;# ADC D11
set_property PACKAGE_PIN T15 [get_ports {adc_dat_a_i[12]}] ;# ADC D12
set_property PACKAGE_PIN V15 [get_ports {adc_dat_a_i[13]}] ;# ADC D13
set_property PACKAGE_PIN T16 [get_ports {adc_dat_a_i[14]}] ;# ADC D14
set_property PACKAGE_PIN V16 [get_ports {adc_dat_a_i[15]}] ;# ADC D15

# ADC Control Pins
set_property PACKAGE_PIN P20 [get_ports adc_ofl_i]         ;# ADC Overflow
set_property PACKAGE_PIN K14 [get_ports adc_pga_o]         ;# ADC PGA Control
set_property PACKAGE_PIN J15 [get_ports adc_dith_o]        ;# ADC Dither Control

# ADC Clock (Differential)
set_property PACKAGE_PIN U18 [get_ports adc_clk_p_i]       ;# ADC Clock +
set_property PACKAGE_PIN U19 [get_ports adc_clk_n_i]       ;# ADC Clock -

# GPS PPS Input
set_property PACKAGE_PIN K18 [get_ports pps_i]             ;# GPS PPS Signal

# Antenna Selection Outputs (6-bit)
set_property PACKAGE_PIN G17 [get_ports {antenna_o[0]}]
set_property PACKAGE_PIN G18 [get_ports {antenna_o[1]}]
set_property PACKAGE_PIN H16 [get_ports {antenna_o[2]}]
set_property PACKAGE_PIN H17 [get_ports {antenna_o[3]}]
set_property PACKAGE_PIN J18 [get_ports {antenna_o[4]}]
set_property PACKAGE_PIN H18 [get_ports {antenna_o[5]}]

# Front Panel Status LED
set_property PACKAGE_PIN F16 [get_ports led_o]             ;# Status LED
```

## CPU ports (PS pins)

### I2C bus 0 (i2c-0)

| Address | Device | Purpose |
|---------|--------|---------|
| 0x50 | 24c64 EEPROM (8 KB) | config storage; factory MAC @0x10 (nvmem cell) |
| 0x60 | Si5351 | clock generator |

> The attenuators are **not** I2C devices — they are 3-wire serial, bit-banged
> on GPIOs 11 (DATA) / 12 (LTCH) / 13 (CLCK). (An earlier doc revision wrongly
> listed "AD8370 0xCA/0xCB" — neither valid 7-bit I2C addresses.)

### DSA (attenuator) control
```c
#define ATT_CLCK  IO_13    // Clock
#define ATT_LTCH  IO_12    // Latch
#define ATT_DATA  IO_11    // Data
// (named AD8370_* in older docs; chip is PE4312 — see §Attenuators)
```

### RF path control GPIOs
```c
#define SWITCH_HF_VHF  IO_10    // LOW = HF, HIGH = VHF
#define REF_CLK_INPUT  IO_49    // LOW = External 10 MHz, HIGH = Internal TCXO (24.576 MHz)
```

## Physical connectors

### Upper side (antenna side)
```
┌─────────────────────────────────────────────────────┐
│  [HF ANT]  [VHF ANT]  [CLK IN]  [GPS ANT]          │
│   (SMA)     (SMA)      (SMA)      (SMA)             │
└─────────────────────────────────────────────────────┘
```
- **HF Antenna (SMA):** LNA → 64 MHz LPF → ADC; 0.01–62 MHz.
- **VHF Antenna (SMA):** 129 MHz BPF → +20 dB LNA → ADC; 118–150 MHz air band.
- **Reference clock in (SMA):** 10 MHz, sine/square, 0.1–3.0 Vpp; selected via GPIO IO_49.
- **GPS Antenna (SMA):** 3.3 V active antenna required; Navstar/QZSS/Galileo.

### Lower side (I/O side)
```
┌──────────────────────────────────────────────────────────────┐
│  [ETHERNET]  [USB HOST]  [EXTIO]  [USB-C PWR]  [TF CARD]    │
│   (RJ-45)     (USB-A)    (8-pin)   (Type-C)    (Micro SD)   │
└──────────────────────────────────────────────────────────────┘
```
- **Ethernet (RJ45):** 10/100/1000 auto-neg; Cat 5e+ recommended.
- **USB Host (USB-A):** USB 2.0, 5 V; Wi-Fi dongles, UART/CAT, hubs.
- **EXTIO (SH 1.0, 8-pin male):** pin1=GND (TF-card side), pin2–7=GPIO_0–5 (3.3 V, direct to FPGA — add isolation/ESD for external use), pin8=+5V out.
- **USB-C power:** 5 V, min 2 A; over-voltage + reverse-polarity protection.
- **TF card (Micro SD):** insert **upside down** (label down, contacts up); SD/SDHC only (NOT SDXC, max 32 GB), Class 10, FAT32/FAT16.

### Serial console (header J3)
**115200 8N1, 3.3 V only** (pin1 = 3V3 NC, pin2 = TXD, pin3 = RXD, pin4 = GND).
Do **not** connect a 5 V adapter. (See `hardware-facts.md`.)

## Clock domains

| Clock | Frequency |
|-------|-----------|
| ADC / FPGA (Si5351 CLK0) | 122.88 MHz (configurable) |
| CPU (ARM Cortex-A9) | 667 MHz |
| DDR | 533 MHz |
| Ethernet (GMII) | 125 MHz |
| Si5351 reference | 24.576 MHz TCXO (or ext 10 MHz) |

```
Si5351 CLK0 ──┬──→ ADC Clock
              ├──→ FPGA Clock
              └──→ Internal logic
Si5351 CLK2 ────→ External Clock Output
24.576 MHz TCXO ──→ Si5351 Reference
```

## Data rates

- **RX channel data rate:** `16 bits × 2 (I/Q) × 13 channels × 12 kHz = 4.992 Mbps`
- **Waterfall (zoom0):** `16 bits × 122.88 MHz ≈ 1.966 Gbps` theoretical; ~3.9 Gbps actual with overhead + dual channels. 13 users share 2 WF channels via TDM.

## Electrical specs (GPIO, 3.3 V CMOS)

| Parameter | Min | Typ | Max | Unit |
|-----------|-----|-----|-----|------|
| VCCIO | 3.15 | 3.3 | 3.45 | V |
| VIH | 2.0 | — | 3.45 | V |
| VIL | −0.3 | — | 0.8 | V |
| VOH | 2.4 | — | — | V |
| VOL | — | — | 0.4 | V |
| IOUT | — | — | 8 | mA |

ADC interface: 16-bit, parallel CMOS, LVDS differential clock, offset-binary data.

## GPSDO — "poor man's GPS Disciplined Oscillator"

The Web-888 disciplines the ADC clock using hardware GPS PPS + a software PID
loop driving the Si5351 — no dedicated GPSDO hardware.

```
ATGM336H → PPS (1 Hz) → FPGA captures 64-bit tick counter on PPS edge
        → gpsd UTC timestamp (t_rx)
        → clock_correction(t_rx, ticks): PID → Si5351 freq register
        → tuned ADC clock (LTC2208)
```

**Control loop (`clk.cpp`):** expected ticks from nominal ADC clock → error =
expected − actual → PID filter → Si5351 frequency register → ADC clock.
Recovered PID gains (reported, not independently measured): `Kp = 1.4, Ki = 0.15, Kd = 0.01`.

**Key symbols:** `fpga_start_pps()`, `fpga_read_pps()` (u64 tick count),
`clock_correction(gps_time, pps_ticks)`, `clock_reset_correction()`.
**Si5351 registers:** `MSNA_P1/P2/P3` (PLL A params), `MS0_P1/P2/P3`
(multisynth 0 divider), `CLK0_CTRL`. **admin.json keys:** `GPS_enable`,
`ADC_clk_cor`, `ext_ADC_clk`, `ext_ADC_freq`.

> Performance figures sometimes quoted for the GPSDO (±30 ns time accuracy,
> ±0.01 ppb stability, <1 ppm holdover) are **spec-sheet/aspirational, not
> measured on this board** — treat as unverified.

## Stock firmware fingerprint

| Parameter | Value |
|-----------|-------|
| OS | Alpine Linux 3.20.10 |
| Kernel | Linux 6.6.110-xilinx (built 2025-10-18, Debian cross-GCC 12.2) |
| FPGA signature | `0xaa55020c` ("Genuine Web-888 Detected": 12 RX + 2 WF channels) |
| FPGA toolchain | Vivado 2023.1 (part 7z010clg400, built 2025-04-13) |
| Custom drivers | zynqsdr (SDR DMA, `/dev/zynqsdr`; built from misnamed `ad8370_driver.c`) |
| EEPROM | 24c64 (8 KB); MAC @0x10 |
| Services | dhcpcd, chronyd, avahi-daemon, sshd, gpsd, sdrd (websdr), frpc, noip2 |
| Open ports | 22 (SSH), 2947 (gpsd), 8073 (WebSDR) |

## Comparison with KiwiSDR

| Feature | KiwiSDR | Web-888 |
|---------|---------|---------|
| Platform | BeagleBone Black/Green | Zynq-7010 custom board |
| ADC | LTC2248 (14-bit, 66.67 MSPS) | LTC2208 (16-bit, 130 MSPS) |
| RX channels | 4 | 13 |
| WF channels | 4 | 13 (TDM of 2) |
| GPS | SDR-based (MAX2769B) | Hardware ATGM336H |
| Memory | 512 MB DDR3 | 512 MB DDR3 (verified) |
| Ethernet | 100M | 1000M |
| VHF | No | Yes (118–150 MHz) |
| Attenuator | No | Yes (×2; PE4312) |
| Clock | Fixed 66.67 MHz | Tunable (Si5351) |

## References

- [Zynq-7000 TRM (UG585)](https://docs.xilinx.com/v/u/en-US/ug585-Zynq-7000-TRM)
- [LTC2208 datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/2208fb.pdf)
- [Si5351 datasheet](https://www.skyworksinc.com/-/media/Skyworks/SL/documents/public/data-sheets/Si5351.pdf)
- [ATGM336H spec](http://www.icofchina.com/d/file/xiazai/2016-10-31/c93115488f4dd3651b37c3a4937db7d3.pdf)
- Verified facts: [`hardware-facts.md`](hardware-facts.md)
