# Known Issues — web888-debian

Open defects and limitations of the Debian port, with current evidence and
next steps. For planned work (not defects), see [`TODO.md`](TODO.md).
Hardware-verified facts live in
[`docs/research/hardware-facts.md`](../research/hardware-facts.md).

---

## 1. GPS: ATGM336H outputs UBX binary only, no NMEA — no fix data anywhere

**Symptom.** gpsd/chrony/WebSDR-admin show no usable GPS data. chrony briefly
selects "GPS" after boot, then marks it falseticker; WebSDR-admin's GPS
section stays empty. SDR receive is unaffected (RX does not depend on GPS).

**Root cause (verified by raw ttyPS1 capture).** The ATGM336H chip is alive
and transmitting, but in **UBX-only output mode**: ~5 UBX frames/s
(NAV-DOP, NAV-SOL, NAV-TIMEGPS, NAV-POSECEF, NAV-VELECEF) plus a 1 Hz
`$GPTXT,01,01,01,ANTENNA OK*35` — and **zero** standard NMEA navigation
sentences (GGA/RMC/GSA/GSV). Since ATGM336H emits NMEA even without a fix
(GGA with status=0), the missing NMEA *as a category* is a protocol-mode
state, not a fix-state or antenna problem.

**What chrony actually saw.** gpsd auto-detects the u-blox driver and parses
UBX-NAV-TIMEGPS; with GPSFix=0 the chip falls back to its battery-backed RTC,
so "GPS time" was chip-RTC (~100 ms drift within 8 h), never satellite time.

**Ruled out (our port is not the cause).** The GPS UART1 path is FSBL pinmux
(MIO48/49 → EMIO) + bitstream routing only; our FSBL is verbatim stock and
both bitstreams are md5-identical to stock. websdr.bin never touches the GPS
UART (links libgps, talks to gpsd over its socket only); the zynqsdr driver
has no GPS-related ioctl. Data demonstrably reaches ttyPS1 (xuartps IRQ
increments; 1970-byte capture decoded).

**Next actions (each needs the operator's go-ahead — they write chip
config):**

1. **Enable NMEA** — send `UBX-CFG-MSG` per sentence (rate=1, UART1):
   GGA `F0 00`, RMC `F0 04`, GSA `F0 02`, GSV `F0 03`, each with payload
   `01 01 00 00 01 00 00 00`. Low risk, reverted by chip power-cycle.
   Verify in <5 s via gpsd `?POLL` returning non-empty TPV.
2. **Cold-start the chip** — send `UBX-CFG-RST`
   (`B5 62 06 04 04 00 00 00 08 00`), wait for UBX-ACK-ACK. The chip has
   been stuck in a no-fix state for hours after one brief fix; likely
   needed regardless of (1). Verify in 30–60 s via
   `/sys/class/pps/pps0/assert` sequence resuming.
3. **Re-tune chrony if only chip-RTC is achievable** — the SHM-0 line's
   `precision 1e-6` is aspirational at ±100 ms RTC quality; lower to
   `precision 1e-1` in `scripts/configure-rootfs.sh`'s chrony seed.
4. **Cross-unit check** — ATGM336H is NMEA-default at POR per datasheet;
   stock gpsd config does no protocol switching, so this chip was put into
   UBX-only mode by something (factory test or a prior config write). If
   another unit reproduces it, document in `hardware-facts.md` and consider
   sending `UBX-CFG-MSG` from `configure-rootfs.sh` at first boot.
5. **Fallback acceptance** — if nothing restores a real fix (hardware
   fault), accept ±100 ms chip-RTC accuracy; no functional SDR impact.

---

## 2. Waterfall engine (BUG 3) — fixed; two cosmetic leftovers

The periodic comb/stripe waterfall artifact was root-caused (FPGA WF engine
latches decimate only at restart; websdr re-armed every frame) and fixed in
three places (`config/kernel/zynqsdr.c` WF_PARAM reset pulse,
`config/websdr/patches/0012-wf-engine-decim-rearm.patch`). Verified clean on
hardware at all zooms. Remaining, cosmetic only:

- What triggered the old build's regime A→B transition at zoom 8 (moot
  post-fix, recorded for completeness).
- Stock-firmware A/B capture of the same band for reference (needs an SD
  swap to the stock card).

## 3. noip2 DDNS and frpc reverse proxy unavailable

The stock firmware's `noip2` (dynamic DNS) and `frpc` (FRP reverse-proxy
client) features have no Debian packages in any release, so the WebSDR
admin pages for them are non-functional on Debian. Candidates if demand
materialises:

- noip2 → port the DUC to the ddclient protocol, or build noip2 from
  upstream source.
- frpc → vendor the upstream static arm binary as `/usr/local/bin/frpc`
  with its upstream unit (the WebSDR ExecStopPost already guards with
  `command -v frpc`).

## 4. Minor / watchlist

- **PSKReporter UDP path untested** — the KiwiSDR cherry-pick batch touched
  this code; autorun is off on the development unit, so it has never
  exercised the path on hardware.
- **One transient masked-frame** was observed on the first waterfall
  websocket connect right after a deploy (not reproducible since) — watch.
- **WebSDR restart latency after Red Pitaya apps** — after an RF-active RP
  app releases the FPGA, websdr.bin needs ~33 s before the :8073 poll
  succeeds (FPGA re-init); expected behaviour, but it makes rapid
  round-trip switching slow.
- **Step-2 optional leftovers** (not blocking): IRQ arm/enable bit-field
  probing (stock does /dev/mem writes), XADC/temperature readout,
  waterfall decimate bits 26–31 live test, PPS circuit -EBUSY-without-fix
  semantics.

## 5. QEMU test-environment limitations (not device defects)

These constrain what the pre-flash gate can cover:

- QEMU's xdevcfg model hard-hangs the guest on bitstream WRITE →
  `load-bitstream` runtime checks are hardware-only (host-side mocks
  cover the fail-closed paths).
- FSBL → U-Boot handoff is not emulatable → full-U-Boot SSBL chain is
  verified in QEMU only from U-Boot onward; the FSBL handoff is a
  hardware gate.
- QEMU masks blank-PL AXI hangs (its Zynq model returns 0 for unmapped GP
  reads) — hardware does not; see `zynqsdr-port-notes.md` §11 for the
  load-bearing probe-must-not-touch-PL rule.
