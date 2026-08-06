# Red Pitaya Software Port to Web-888

> **Status: IMPLEMENTED and hardware-verified** as
> `web888-redpitaya` 2025.430-2 (Step 4). What actually shipped:
> runtime switching via `web888-mode` + systemd (`web888-rpapp@.service`
> template, `Conflicts=` both directions, bitstream load in ExecStartPre),
> no nginx port-80 selector (cut for v1), no resource-lock daemon
> (systemd ordering suffices), `/usr/share/web888-redpitaya/apps/<app>/`
> file layout. The "Validation Against Vendor Firmware" section remains the
> verified vendor-analysis base; the "Architecture Overview" below is the
> original proposal — read it as history; the binding description of the
> shipped system is `docs/research/hardware-facts.md`
> (Step-4 section) + `docs/dev/redpitaya-websdr-coexistence.md` §6 (resolved).

This document describes how Red Pitaya software could be ported to run on
Web-888 alongside WebSDR.

## Architecture Overview

### Runtime Switching Model

Unlike dual-boot approaches, this port allows both WebSDR and Red Pitaya
to run on the same Debian installation. The key is FPGA bitstream
switching at runtime:

```
Boot → Debian → Default: WebSDR active
                    ↓
              User switches mode
                    ↓
            Stop WebSDR → Load RP bitstream → Start Red Pitaya
```

### FPGA Bitstream Management

The FPGA is reconfigured at runtime. The original design assumed Linux
FPGA Manager (`echo x.bit > /sys/class/fpga_manager/fpga0/firmware`).
Validation against the vendor firmware (see
[Validation Against Vendor Firmware](#validation-against-vendor-firmware))
shows that `/dev/xdevcfg` is the proven loading mechanism on this
platform, and it is the recommended approach for this port. FPGA
Manager remains an optional alternative.

1. **WebSDR bitstream**: Optimized for RX-888 ADC (LTC2208 at 130MSPS)
2. **Red Pitaya bitstream**: Standard RP ecosystem bitstream

Switching time is an unverified estimate (originally cited as
"approximately 2-3 seconds"). Measure it during Plan 06 execution.

### Network Port Sharing

nginx handles URL-based routing:

- `/` - Application selector landing page
- `/websdr/` - WebSDR interface (proxy to :8080)
- `/redpitaya/` - Red Pitaya interface (proxy to RP apps)

### Resource Arbitration

A lock-based system prevents conflicts:

- **FPGA**: Exclusive lock prevents simultaneous access
- **ADC**: WebSDR exclusive (direct /dev/zynqsdr access)
- **I2C**: Shared (clock generator, attenuators)
- **GPS**: WebSDR exclusive

## Validation Against Vendor Firmware

This document was written before the vendor firmware had been analyzed.
A binary analysis of the RaspSDR Red Pitaya firmware ZIP
(`red-pitaya-alpine-3.20-armv7-20241228.zip`) and of the stock Web-888
firmware (see `red-pitaya-firmware.md`, `stock-kernel-analysis.md`, and
the full report in `redpitaya-firmware-analysis.md`) validates
some of the design assumptions above and corrects others. Findings are
labeled CONFIRMED (verified from binaries or source) or INFERRED
(reasoned, not directly observed).

### FPGA Loading: xdevcfg, not FPGA Manager

This document (and `plan/06-redpitaya-port.md`) assumed Linux FPGA
Manager for bitstream loading. The vendor firmwares disprove this for
their own stacks:

- CONFIRMED: The RaspSDR Red Pitaya kernel does not include FPGA
  Manager at all (`CONFIG_FPGA` is not set in its extracted 6,736-line
  kernel config). Apps load bitstreams with
  `cat app.bit > /dev/xdevcfg` (`CONFIG_XILINX_DEVCFG=y`).
- CONFIRMED: The stock Web-888 kernel also has xdevcfg built in, but
  `websdr.bin` loads the FPGA through its own internal mechanism
  (not xdevcfg-based per symbol analysis; still under investigation).
- Recommendation: For the new Debian kernel, use `/dev/xdevcfg` (enable
  `CONFIG_XILINX_DEVCFG`) as the proven-compatible loading mechanism.
  FPGA Manager remains optional.

### ADC Data Path: /dev/mem vs /dev/zynqsdr

- CONFIRMED: RaspSDR apps access the FPGA purely through `/dev/mem`
  mmap polling: config registers at 0x40000000, status at 0x41000000,
  RX FIFO at 0x42000000. These are the same physical addresses that
  WebSDR's zynqsdr driver maps.
- CONFIRMED: Red Pitaya apps need no custom kernel driver, so they are
  portable to any kernel (including our Debian linux-xlnx 6.6 kernel)
  without zynqsdr. WebSDR still requires the zynqsdr driver.
- Implication: A unified kernel can carry both zynqsdr and xdevcfg with
  no conflict. The two stacks use different access mechanisms against
  the same registers, and only one application owns the FPGA at a time
  at runtime.

### Boot Chain Compatibility

- CONFIRMED: Both vendor firmwares use an identical packed boot.bin
  layout: DTB + gzip kernel + gzip initramfs inside boot.bin, with the
  DTB at the same offset (0x1D780) and no FPGA bitstream inside
  boot.bin.
- CONFIRMED: Both use the same Red Pitaya-derived FSBL (identical
  strings: Si5351 122.88 MHz configuration, no FPGA load). The FSBL
  provenance is RaspSDR/red-pitaya-notes (`patches/red_pitaya_fsbl_hooks.c`,
  howard0su fork), which is the source of both vendor boot chains.
- Implication: A single FSBL/boot.bin can boot either userspace.

### Runtime Switching: Validated by the Vendor

- CONFIRMED: The vendor's own Red Pitaya firmware already implements
  runtime FPGA + app switching: a tcpserver-based app selector on port
  80, where each app's `start.sh` stops all running apps, loads its
  bitstream via `/dev/xdevcfg`, then starts its server; `stop.sh`
  kills all app processes. This proves the runtime-switching model
  this document proposes works on this exact hardware.
- Port note: WebSDR listens on port 8073; the RaspSDR selector uses
  port 80. No conflict.

### Coexistence Options (ranked)

1. **Unified kernel + both userlands + app/mode selector**
   (recommended, moderate effort): one kernel carrying zynqsdr +
   ad8370 + xilinx_devcfg + CMA 36M, both userlands installed, and a
   selector service that performs stop-all, loads the bitstream via
   `/dev/xdevcfg`, then starts the selected app. This mirrors the
   vendor's proven model on our Debian base.
2. **U-Boot boot menu** (boot.scr/extlinux.conf): complete isolation,
   but the kernel and initramfs would need to be separate files on the
   FAT partition. The current vendor packing (everything inside
   boot.bin) makes this awkward.
3. **SD swap** (status quo): zero engineering effort, maximum user
   friction.

### Open Documentation Issue

An earlier draft described a dual-boot approach (U-Boot boot menu,
`switch-firmware` script) that contradicts the runtime-switching model.
The vendor findings above favor runtime switching; resolve any such
contradiction when Step 4 (Red Pitaya port) is actually executed.

> **The sections below the validation/coexistence findings above (file
> locations, systemd services, `fpga-switch.sh`/`resource-manager.sh` API,
> HTTP API, troubleshooting) were an unimplemented target design from an
> earlier draft — none of those files/services/scripts exist in this repo.
> They have been removed. When Step 4 begins, design the actual service /
> switch mechanism against the validated findings above (xdevcfg loading,
> /dev/mem data path, runtime app/bitstream switching proven by the vendor),
> not against this old sketch.**

## References

- [Red Pitaya Documentation](https://redpitaya.readthedocs.io/)
- [Linux FPGA Manager](https://www.kernel.org/doc/html/latest/driver-api/fpga/)
- [Xilinx Zynq-7000 TRM](https://docs.xilinx.com/v/u/en-US/ug585-Zynq-7000-TRM)
- Full vendor-firmware analysis: [`red-pitaya-firmware.md`](../research/red-pitaya-firmware.md)
  (curated from the offline binary analysis of the vendor ZIP)
