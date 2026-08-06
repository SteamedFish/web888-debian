# Web-888 Hardware Facts (Verified)

Facts on this page were verified **live on the device** (DHCP-floating IP; discover
by MAC prefix `ce:cf:3f:*`) or against stock firmware binaries. Everything in other
docs/ files is AI-generated reverse-engineering material — trust this file first
when they conflict.

## Identity

| Item | Value | Source |
|---|---|---|
| SoC | Xilinx Zynq-7010 (xc7z010-1clg400), dual Cortex-A9 (CPU part 0xc09, NEON) | docs + cpuinfo |
| RAM | 512 MB DDR3 (MemTotal 509476 kB) | live `/proc/meminfo` |
| Storage | SD/TF card boot (BootROM → boot.bin on FAT32 p1) | live `/proc/partitions` |
| Stock card | 16 GB class, **single** FAT32 partition spanning whole card | live |
| Ethernet MAC | `ce:cf:3f:*` prefix; full per-unit value stored in board EEPROM @0x10, read by the kernel via the DTB nvmem cell (see config/web888.dts gem0/macaddr@10); check `cat /sys/class/net/eth0/address` on your unit | live `eth0/address` |

> **MAC scope (honest):** this value is verified on the **one** unit available
> (this project has a single Web-888). An earlier claim that "ALL stock units
> share this MAC" was never verified (would need multiple units) and has been
> retracted. Treat the MAC as "this unit's EEPROM
> MAC", not as a universal factory constant.
| Network env | DHCP, DHCP on a large broadcast domain (check your LAN) | live `ip addr/route` |
| Stock kernel | 6.6.110-xilinx `#1 SMP PREEMPT Sat Oct 18 23:11:49 CST 2025` armv7l | live `uname` |
| Stock userland | Alpine Linux 3.20.10, root on tmpfs, modloop squashfs on loop0 | live `/etc/alpine-release` |

## Boot chain (verified against stock boot.bin binary)

- boot.bin 9,056,768 B, Xilinx boot image (sync 0xAA995566, XNLX header):
  - FSBL @0x0–0x1C008 (Red Pitaya–derived, configures Si5351 clock chip, does NOT load FPGA)
  - SSBL @0x1C008–0x1D780 (~2936 B, Pavel-Demin-style minimal loader)
  - DTB @0x1D780 (12,455 B)
  - gzip kernel @0x278A8 (4,700,435 B → 11,740,160 B)
  - gzip initramfs @0x4A3200 (3,894,120 B → 6,503,936 B)
- Kernel cmdline (from DTB `chosen`): `console=ttyPS0,115200 earlycon earlyprintk initrd=0x3000000,4M modloop=modloop`
- U-Boot env stored in I2C EEPROM 24c64 @0x50, offset 0x1800, size 0x400 (fw_printenv works on stock).
- FPGA bitstream NOT in boot.bin — loaded at runtime by websdr.bin via `/dev/xdevcfg`.

## Console / LEDs / recovery

- Serial: header J3, 115200 8N1, **3.3 V only** (pin1 = 3V3 NC, pin2 = TXD, pin3 = RXD, pin4 = GND).
  We have NO serial adapter → all testing is blind.
- LEDs (stock firmware sequence):
  - D2 (green): lights briefly at power-on, turns OFF within ~1 s → off means the
    **kernel booted** (Linux GPIO-LED driver probes that early; stock kernel cmdline
    has no `leds=` override). Stays on = BootROM/FSBL/kernel never got that far.
  - D0: steady ON only after the system is fully booted AND the stock software stack
    is running (websdr/factory service drives it, also PWM). Absence is NORMAL for any
    non-stock OS.
  - D3: blinks occasionally once stock software runs. D1: never lights.
- LEDs observed under **our Debian** (step-2 image with
  bitstream loaded via /dev/xdevcfg): **D0 (blue) steady ON, D3 (green) blinking**.
  There is NO "D8" — earlier session notes referencing D8 were a naming error.
  Do not use LEDs as FPGA health evidence: authoritative checks are
  `cat /sys/devices/soc0/axi/f8007000.devcfg/prog_done` (=1 after bitstream load)
  and real RX reads via /dev/zynqsdr. Note the Si5351 ADC clock (userspace i2c-0
  @0x60) must be initialized before the PL produces RX samples — websdr.bin does
  this itself; `scripts/hw-test/si5351-init` does it for driver-level tests.
- LED wiring (decoded from stock DTB `gpio-leds` node — all MIO pins on gpio0,
  NOT the 74HC595 chain that the reverse-eng docs mention):
  - `greend2` (= D2): gpios `<&gpio0 9 1>` — MIO9, ACTIVE-LOW,
    `linux,default-trigger = "heartbeat"`, default-state off.
  - `led6` (red): gpios `<&gpio0 7 0>` — MIO7, active-high, default-state on.
  - node literally named `d2` (blue): gpios `<&gpio0 30 0>` — MIO30, active-high.
- Safe-mode/recovery mechanism exists in stock initramfs (KiwiSDR-style); details in
  `docs/boot-chain-analysis.md` (AI-generated, verify before relying).

## Devices relevant to Step 2+ (reference)

- zynqsdr driver: built-in misc device `/dev/zynqsdr` (10:126), compatible `rx888,zynqsdr`,
  no reg in stock DT (hardcoded: config 0x40000000, status 0x41000000, RX 0x42000000,
  WF 0x43000000+, PPS 0x47000000), IRQs SPI 29–32, GPIOs MIO 10/11/12/13/49 (all active-low).
  (Pin numbering: 0-53 = MIO 0-53, 54+ = EMIO 0+ — so "idx 4 = gpio pin 49" is MIO 49,
  not EMIO 49 as some older notes say.)
- websdr.bin talks to `/dev/i2c-0` (Si5351 @0x60, EEPROM 24c64 @0x50) and `/dev/zynqsdr` only.
- GPS time sync (stock): gpsd on `/dev/ttyPS1` (UART1 @ e0001000, ATGM336H 9600 8N1) +
  `/dev/pps0` (1PPS); stock DTB declares both. PPS is a top-level `pps` node,
  `compatible="pps-gpio"; gpios=<&gpio0 54 0>; capture-clear;` — pin 54 = EMIO[0].
  Stock loads `pps_gpio` module at runtime (include PPS_GPIO in our kernel). The stock
  `emio-gpio-width=<1>` property is a legacy no-op the `gpio-zynq` driver ignores
  (`chip->ngpio` is fixed at 118 from platform data, not DT), so our `config/web888.dts`
  omits it — EMIO pins are always available. uart1 needs `status="okay"` (defaults to
  disabled in zynq-7000.dtsi). chrony uses gpsd's SHM refclock + the PPS refclock.
  Live-verified GPS-chip behaviour (2026-08-06, dev unit): the ATGM336H accepts
  standard UBX-CFG-MSG/CFG-RST commands (ACKed except CFG-RST); its V_BCKP keeps
  RAM message config across reboots, so any software that writes UBX config —
  notably Debian gpsd 3.25's u-blox driver — leaves a lasting protocol-mode
  change (this is what put the dev unit into UBX-only output; fixed by running
  gpsd read-only, `-b`). It emits GSV with empty el/az fields until it has
  almanac *and* a position, which gpsd's SiRF-hairball check then discards —
  so no skyview anywhere before the first fix. Management tool:
  `scripts/hw-test/atgm336h-fix.py`.
- USB host port: a USB-A host connector on the board, driven by usb0
  (`e0002000`, MIO 28-39 USB0 controller) through a ULPI PHY. Stock DTB enables
  it (`status="okay"; dr_mode="host"`). Our `config/web888.dts` matches: `&usb0`
  override + a top-level `phy0@e0002000` node (`compatible="ulpi-phy"`,
  `view-port=<0x0170>`, `external-drv-vbus`). The phandle binding is `usb-phy`
  (not `phys`): that is the property the `ci_hdrc_usb2` glue reads for
  `xlnx,zynq-usb-2.20a` (`drivers/usb/chipidea/ci_hdrc_usb2.c`). Stock's
  `xlnx,phy-reset-gpio`/`usb-reset` (gpio0 pin 48) are NOT in our DTB — no
  mainline driver reads them (dead legacy props) and this board's ULPI PHY reset
  is handled at power-up, not via GPIO. `external-drv-vbus` is the current
  binding name for stock's `drv-vbus` (`phy-ulpi.c` accepts both).
- ExtIO / antenna switch (per rx-888.com/web/design/pinout.html):
  an 8-pin SH1.0 connector (pin 1 = GND on the SD-card side, pin 8 = 5V) for an
  external antenna switch; pins carry 6 control signals **A1–A6**. These are
  **FPGA PL pins** (`antenna_o[0..5]` → G17/G18/H16/H17/J18/H18, 3.3 V CMOS),
  **NOT** Zynq PS GPIO — so ExtIO is never in the device tree (neither stock's
  nor ours). Control is bitstream + driver MMIO: the `zynqsdr` driver's
  `SET_GPIO_MASK`/`GET_GPIO_MASK` ioctls (`_IOW/_IOR('Z',7/8,__u32)`,
  `config/kernel/zynqsdr.c:564-571`) write bits 0–5 to the FPGA config register
  at `0x40000084`. Bit map (`resources/reference/raspsdr-server/peri.h`):
  bit 0–5 = `GPIO_ANTENNA0..5` (= ExtIO A1–A6), bit 6 = DITHER, bit 7 = PGA,
  bit 8 = LED. Reference userspace helper: `fpga_set_antenna()`
  (`resources/reference/raspsdr-server/peri.cpp:267`, read-modify-write that
  preserves the DITHER/PGA/LED bits). Driver support is complete; surfacing it
  in the websdr web UI is a later userspace step. The connector supplies 5 V
  but the GPIO lines are 3.3 V — external isolation/ESD protection is required.
- **RX data path regression — RESOLVED (root cause: gpiod vs legacy-gpio
  polarity inversion).** For a period the FPGA intermittently produced no
  ADC samples on our port (RX ring static while the WF ring stayed live —
  a partial fabric wedge; only a full PL reconfig cleared it; roughly one
  start in five wedged). Front-end controls, Si5351 config, bitstream
  identity, module md5, FCLK gating and pinmux were all exonerated live.
  Root cause, proven against a stock-card golden register dump: the stock
  zynqsdr driver uses legacy `gpio_set_value()`, which IGNORES the DT
  ACTIVE_LOW flag (0x01 in the stock DTB is inert), while our port used
  `gpiod_set_value()`, which HONOURS it — so identical logical values
  drove opposite physical levels on all 5 control pins. MIO49 (ext/int
  clock select) ended up LOW = the unconnected external 10 MHz input was
  selected -> Si5351 lost its TCXO reference -> PLL never locked (status
  reg0 = 0x61 = LOL_A+LOL_B at all times vs stock's 0x01) -> marginal
  ADC/FPGA clocking -> per-start dice rolls and mid-run wedges. The same
  inversion explained the earlier "DSA writes have no visible effect" and
  the opposite MIO10 mode level. **Fix:** `config/web888.dts` zynqsdr
  gpios flags 1->0 (ACTIVE-HIGH — the truthful description for this
  hardware; stock's 0x01 flags are a copy-paste artefact its own driver
  ignores). Verified on hardware: PS GPIO levels byte-match the stock
  golden reference, Si5351 locked from boot (reg0=0x01), RX+WF rings live
  with real RF, waterfall dense with real signals, header SNR 17 dB.
  Operational lessons kept:
  - **DT deploy lesson**: the running kernel's DT comes from the DTB
    EMBEDDED IN boot.bin (FSBL partition #3, per `bootbin-repack-spec.md`)
    — `/boot/web888.dtb` on the FAT partition is NOT used by the boot
    flow. Deploy DT changes via `scripts/build-bootbin.sh final` ->
    replace `/boot/boot.bin` -> reboot. Verify a DT change with
    `od -A d -t x1 /proc/device-tree/<node>/gpios`, never file timestamps.
  - **`zynqsdr-smoke` is a QEMU-mode binary** — its "FAIL ... (0 under
    QEMU)" messages actually mean the hardware returned correct NONZERO
    values, and its single-shot RX read right after arm is not a health
    check. Use `rx-dump`/`rx-matrix` (they poll 30x100 ms) for hardware
    RX health.
  - **rx-matrix argv3** ("rearm") is passed as a DECIMATE value to a
    second RX_START ioctl and must be in [5,40] (`rx-matrix 0 20 40`).
  - **journald rate-limit artifact**: suppressed stdout lines flush much
    later carrying old internal timestamps — a frozen-looking websdr
    clock in the journal is NOT evidence of a wedge; grep journalctl
    with absolute `--since` windows instead.
  - **RX_FIFO u16 @status+0x04 is a static field**, not a live producer
    counter; live RX health indicators are ring content changing
    (/dev/mem double-snapshot) or RX_READ readed > 0.
  - **RX ring data format**: 4-word blocks; word0 = sample (full-scale
    real RF when live), words 1-3 = header/status constants — do not
    mistake the constant header words for garbage.
  - **i2c caveat (this board)**: Si5351 single-byte reads are reliable;
    multi-byte BURST reads are unreliable (the chip has no
    auto-increment) — a "registers identical across different configs"
    observation is a burst-read artifact.
## Discovery procedure (blind boot, DHCP + avahi mDNS)

1. Boot device with new card.
2. The Debian image runs avahi-daemon: the device answers as
   `web888.local` over mDNS (IPv4 + IPv6) — verified live on hardware
   (host `avahi-resolve-host-name web888.local`, survives reboot). With an
   mDNS-capable client this is all you need.
3. Fallback (no mDNS client / multicast blocked): from host
   `sudo nmap -sn <your-lan-subnet>` (or check router DHCP leases) and look for
   the unit's `ce:cf:3f:*` MAC; also `ip neigh | grep -i ce:cf:3f` after
   pinging broadcast.
4. The MAC is stable — it comes from the board EEPROM (not the SD card), so it does
   NOT change when you swap cards or reflash.

## QEMU emulation gaps (qemu-system-arm 11.0.2)

Facts about the QEMU test environment where it DIFFERS from hardware — do not
"fix" the production DTB to match QEMU:

- `xilinx-zynq-a9` cadence_gem PHY is fixed at MDIO address **7** (Marvell
  88E1111 model). `-global driver=cadence_gem,property=phy-addr,value=1`
  parses without error but is silently ignored (monitor `info qtree` shows
  phy-addr = 7). QEMU-only DTB variant (phy@7 + local-mac-address) is built
  by `scripts/test-qemu.sh final`.
- No 24c64 EEPROM is emulated on i2c0: at24's probe-time test read fails with
  -ENODEV, the nvmem device never registers, and macb's `of_nvmem_cell_get`
  returns -EPROBE_DEFER forever. Deferred `e000b000.ethernet` under QEMU
  alone is therefore EXPECTED and is not a hardware bug.
- Hardware PHY (RTL8211) is at MDIO address 1; factory MAC comes from the
  real EEPROM via nvmem — both work only on hardware.

## Kernel 6.6 boot blockers (fixed in final bootargs) (fixed in final bootargs)

- `fw_devlink=on` (6.6 default) blocks `e000b000.ethernet` BEFORE probe via
  fwnode-level supplier links that can never resolve: phy-handle → phy node
  (created only by macb's own MDIO registration — circular) and clkc
  (CLK_OF_DECLARE, never a struct device; also blocks amba coresight).
  No suppliers/ sysfs dirs appear — the block is invisible in sysfs.
  Fix: `fw_devlink=off` in bootargs (matches stock-era kernel behaviour).
- udev predictable naming renames eth0 → end0; ifupdown's
  `/etc/network/interfaces.d/eth0` (`auto eth0`) then fails with
  "eth0: interface not found" and networking.service fails → no DHCP.
  Fix: `net.ifnames=0` in bootargs.

## Step-4 Red Pitaya coexistence (verified with web888-redpitaya 2025.430-1/-2)

- **QEMU xdevcfg write hangs the guest kernel** (qemu-system-arm 11.0.2):
  QEMU's zynq model exposes /dev/xdevcfg, but `cat app.bit > /dev/xdevcfg`
  hard-hangs the guest (devcfg unemulated write stall — sshd froze, no
  panic, killed only by the 120s test timeout). All bitstream-load runtime
  testing is hardware-only; fail-closed paths are host-mock-tested.
- **Runtime mode switching works on hardware** (websdr ↔ RP app):
  `web888-mode led_blinker` stopped websdr, loaded led_blinker.bit,
  prog_done=1; `web888-mode websdr` restored WebSDR fully (bitstream
  reload + Si5351 re-init + :8073 listening, HTTP 200 from the host).
- **sdr_receiver streams live I/Q immediately after websdr ran** (P4.4
  question, answered for this app): web888-mode sdr_receiver right after
  an active websdr session → TCP :1001, 65536-byte frame, 94.9% non-zero
  int16 samples, stdev 17282 (live ADC data). **No Si5351 re-init was
  needed** → `SI5351_RESET=0` shipped default stands unless hpsdr/wide
  show otherwise.
- **gpiochip numbering matches the vendor kernel**: our 6.12 exposes
  gpiochip512 (base=512, ngpio=118, zynq_gpio) — exactly peri.c's
  GPIO_BASE_ADDR 512 assumption (sysfs GPIOs 523/525/524 = MIO 11/13/12).
  BUT the sysfs path still fails with EBUSY because the zynqsdr kernel
  driver owns MIO 11/12/13 — the vendor peri.c then dereferenced a NULL
  FILE* and SEGV'd. Fixed by patch 0001-peri-use-zynqsdr-ioctl (DSA via
  the driver's ZYNQSDR_AD8370_SET ioctl, PL-bitstream-agnostic).
- **Hang incident (observed once)**: device dropped off the network
  (no ce:cf:3f in arp/nmap) after ~15 min of the hpsdr SEGV crash-loop
  (Restart=on-failure, RestartSec=3 → bitstream reloaded every ~4s
  continuously). Likely sustained devcfg churn; unproven. Mitigation:
  StartLimitIntervalSec + StartLimitBurst on web888-rpapp@.service.
  NOTE: those are [Unit]-section keys — in [Service] systemd 257 logs
  "Unknown key" and silently ignores them (first attempt was inert).
- **hpsdr fully functional after the peri.c patch** (P4.3 PASS, deb -2):
  HPSDR Metis discovery broadcast (255.255.255.255:1024 — the LAN is /17,
  brd <ip>, NOT a /24) gets a 63-byte 0xEFFE02 reply with the
  board MAC; start → 7189 UDP frames / 7.36 MB payload in 3s, 62.9%
  non-zero; ATT command (C0=0x14, frame[4]=0x40|att) → journal "Set
  attenuator to 20" via the zynqsdr ioctl; clean stop. The rpapp unit
  needed `DeviceAllow=/dev/zynqsdr rw` added (EPERM under
  DevicePolicy=closed otherwise).
- **Si5351 reset not needed for sdr_receiver OR hpsdr** after websdr ran
  (both stream normally with SI5351_RESET=0) → shipped default settled.
- **websdr.bin takes ~30-35s to re-bind :8073 after an RF-active RP app**
  (hpsdr/wide ran before the switch): the service is "active" within 1s
  but the port appears ~33s later (silent init — likely FPGA restore +
  clock settle inside the closed binary; si5351 init then logs error=0).
  After led_blinker (PL idle, no RF) the same restore was <3s. Any
  round-trip test must poll :8073 up to 60s, not fixed-sleep 3s.
- **StartLimit tuned to 10/120s**: 5/60s broke legitimate rapid switching
  (the P4.5 ×10 round-trip hit start-limit-hit on cycles 6-10 — the only
  "failures" in that run; zero genuine load-bitstream/PL errors).
  10/120s still bounds sustained crash-loop churn to ~75 PL loads/15min.
- **sdr_transceiver_wide: starts + listens on TCP 1001**; protocol-level
  data check deferred (optional app; role-select connection model — first
  uint32 0/1/2/3 = rx-ctl/tx-ctl/rx-data/tx-data — two quick host attempts
  got 0 bytes on rx-data; no in-repo consumer to validate against).
