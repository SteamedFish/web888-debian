# Known Issues — web888-debian

Open defects and limitations of the Debian port, with current evidence and
next steps. For planned work (not defects), see [`TODO.md`](TODO.md).
Hardware-verified facts live in
[`docs/research/hardware-facts.md`](../research/hardware-facts.md).

---

## 1. GPS: gpsd 3.25 was switching the ATGM336H to UBX-only — fixed in image; end-to-end verification pending

**Symptom (original).** gpsd/chrony/WebSDR-admin showed no usable GPS data.
chrony briefly selected "GPS" after boot, then marked it falseticker;
WebSDR-admin's GPS section stayed empty. SDR receive was never affected.

**Root cause (confirmed on hardware, 2026-08-06).** The protocol-mode
poisoning was **our own gpsd**. Debian gpsd 3.25's u-blox driver rewrites
the receiver's message configuration on connect: NMEA GGA/RMC/GSA/GSV all
disabled, UBX NAV-SOL/NAV-DOP/NAV-TIMEGPS/NAV-POSECEF/NAV-VELECEF enabled.
The stock Alpine gpsd never did this — but the ATGM336H's V_BCKP keeps RAM
config alive across reboots and power cycles, so a single gpsd connect on
our Debian image left the chip in UBX-only mode *permanently*. Verified by
experiment: after re-enabling NMEA by hand, one gpsd run (without `-b`)
returned the port to UBX-only within seconds.

Two follow-on data losses made it look like "no fix data anywhere":

- gpsd enables no UBX SVINFO substitute on this chip, so with NMEA GSV
  disabled it had **no skyview at all** → empty WebSDR-admin GPS page.
- gpsd's SiRF-hairball sanity check (`driver_nmea0183.c`) discards any GSV
  set where every satellite's azimuth is 0 — and the ATGM336H emits empty
  el/az fields until it has both almanac and a position, i.e. exactly while
  it is fix-less. So SKY/satellite data only appears after the first fix.

**Fix (deployed).**

1. `configure-rootfs.sh`: `GPSD_OPTIONS="-n -b -s 9600"` — the `-b`
   (read-only) flag stops gpsd from ever writing chip config. Verified on
   hardware: NMEA config now survives gpsd restarts. **Existing installs
   need the same one-line edit in `/etc/default/gpsd`.**
2. New device-side tool `scripts/hw-test/atgm336h-fix.py` (no deps, runs on
   the board): `status` classifies the NMEA/UBX mix, `enable-nmea` restores
   GGA/GSA/GSV/RMC (+GLL/VTG/ZDA) at 1 Hz via UBX-CFG-MSG,
   `disable-ubx` turns the gpsd-enabled UBX NAV spam back off (pure NMEA =
   factory default = what gpsd's NMEA driver handles best), `cold-start`
   sends UBX-CFG-RST (clear BBR, GNSS-only restart), `save` persists msg
   config to flash if ever wanted, `fix` runs the whole sequence.
3. Chip on the dev unit was cold-started to clear the poisoned BBR state
   (it had been stuck fix-less for hours on stale data).

**Verified on hardware.** NMEA restored and stable across gpsd restarts;
gpsd selects the NMEA0183 driver (read-only); TPV time updates flow to the
gpsd socket; chip config no longer degrades.

**Still pending — operator verification.** The chip tracks only 3–4
satellites with marginal C/N0 (24–36 dB-Hz) at the dev unit's location and
had no fix 30 min after cold start; el/az stay empty (hence no gpsd SKY)
until the first fix. PPS (`/sys/class/pps/pps0/assert`) is quiet while
fix-less — expected, the timepulse only runs with time from a lock. What
remains is **antenna/sky-view dependent**, not software: with a 3.3 V
active antenna and reasonable sky, expect a fix in 5–15 min from cold
start, after which GSV el/az fill in, gpsd SKY populates, WebSDR-admin
shows satellites, chrony's GPS/PPS refclocks come online. Confirm on
hardware, then close this item. If hours of good sky still yield no fix,
suspect the RF path (antenna/LNA) and fall back to the ±100 ms chip-RTC
acceptance noted in earlier revisions of this file.

**Not done (deliberately).** No UBX-CFG-CFG flash save: factory default is
pure NMEA, and with gpsd `-b` nothing rewrites the config, so BBR
persistence is sufficient and flash writes are unnecessary risk. chrony's
SHM-0 `precision 1e-6` stays as-is — it only mattered for the chip-RTC
fallback scenario, which did not materialise.

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
