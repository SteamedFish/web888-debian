# Red Pitaya / WebSDR Coexistence — Research (Step 4)

> **Status:** Research synthesis. Superseded by step-4 execution (see §6). This doc consolidates
> prior repo research (`redpitaya-port-guide.md`, `red-pitaya-firmware.md`,
> `zynqsdr-port-notes.md`) with new external research (official RedPitaya/RedPitaya
> stack, pavel-demin/red-pitaya-notes, RaspSDR/red-pitaya-notes activity) to
> answer the two milestone questions: **(A) can WebSDR and Red Pitaya apps run
> simultaneously, or (B) do we need a switch mechanism — and can official Red
> Pitaya code be adapted to the Web-888?**

## Verdict (TL;DR)

1. **Plan A (simultaneous, different ports) is IMPOSSIBLE.** The FPGA holds
   exactly one bitstream at a time, and the two stacks need *different*
   bitstreams (`websdr_{hf,vhf}.bit` vs per-app `sdr_*.bit`). Ports were never
   the conflict — the FPGA fabric is. (CONFIRMED from both vendor firmwares and
   upstream Demin architecture.)
2. **Plan B (runtime switching) is the architecture, and the vendor already
   proves it works on this exact hardware.** The RaspSDR Red Pitaya firmware
   ships a tcpserver app selector on port 80 where each app's `start.sh`
   stops all apps → `cat app.bit > /dev/xdevcfg` → starts the app daemon.
   Switching back to WebSDR is even simpler: `websdr.bin` loads its own
   bitstream at startup (peri.cpp `peri_init` step 2).
3. **Official Red Pitaya code (RedPitaya/RedPitaya) is NOT adaptable to the
   Web-888 in any practical sense** — the hardware is fundamentally different
   (ADC, clocking, front-end, no DAC/TX), and the official FPGA design +
   UIO/overlay userspace would need a from-scratch port of the HDL. The viable
   "Red Pitaya" stack for this board is **RaspSDR/red-pitaya-notes** (the
   vendor's own fork of pavel-demin, already built for Web-888 hardware,
   open source, prebuilt bitstreams).
4. **Our Debian 6.12 kernel already meets every kernel-side requirement** for
   the RaspSDR RP apps: `CONFIG_DEVMEM=y`, `CONFIG_XILINX_DEVCFG=m`,
   `CONFIG_ZYNQSDR=m`, `CONFIG_CMA_SIZE_MBYTES=64` (verified in
   `work/linux-debian-6.12/.config`). The RP apps need no custom kernel
   driver at all — pure `/dev/mem` mmap + `/dev/xdevcfg`.

## 1. Why simultaneous operation is impossible

| Fact | Evidence |
|---|---|
| WebSDR requires `websdr_hf.bit` or `websdr_vhf.bit` (Vivado 2023.1, built 2025/04/13) | vendored in `resources/stock-card/`; loaded by peri.cpp at startup |
| Each RP app requires its own bitstream (6 apps, Vivado 2023.1, built 2024/12/01–09) | `red-pitaya-firmware.md` §Bitstream Inventory (CONFIRMED) |
| The Zynq PL is a single reconfigurable fabric — one bitstream at a time | Xilinx Zynq-7000 architecture |
| pavel-demin upstream confirms the model: every app's `start.sh` stops running apps, loads its own bitstream to `/dev/xdevcfg`, then starts its server — two apps requiring different FPGA configurations cannot run concurrently | DeepWiki synthesis of pavel-demin/red-pitaya-notes `sdr-transceiver.c` + `start.sh` |
| Even *within* WebSDR, HF↔VHF already switches bitstreams at runtime | peri.cpp init (`websdr_hf.bit` vs `websdr_vhf.bit` by ADC clock / airband) |

**Corollary:** "both listening on different ports simultaneously" cannot be
done regardless of software effort — the receive hardware itself (DDC chain in
the PL) exists in only one configuration at a time.

## 2. Why runtime switching is proven (and cheap for us)

The vendor's own Red Pitaya firmware implements exactly the switching model on
this exact hardware (all CONFIRMED by binary analysis):

- **App selector:** `tcpserver -H -l 0 0 80 .../apps/server/server` (port 80,
  always-on); HTTP GET of an app directory runs `<app>/start.sh` detached.
- **start.sh pattern:** `source stop.sh` (kill all app processes) →
  `cat <app>.bit > /dev/xdevcfg` → exec app binary in background.
- **stop.sh pattern:** every app's `stop.sh` runs, each `killall -q` its own
  process.
- **Switching back to WebSDR:** `websdr.bin` performs Si5351 init →
  `cat websdr_{hf,vhf}.bit > /dev/xdevcfg` → `open("/dev/zynqsdr")` itself at
  startup (zynqsdr-port-notes §1). So the "switch script" in the WebSDR
  direction is literally `systemctl start web888-websdr`.

Our kernel side is ready today (verified in the 6.12 build):

```
CONFIG_DEVMEM=y            # RP apps' only data path
CONFIG_XILINX_DEVCFG=m     # /dev/xdevcfg — shared loader for BOTH stacks
CONFIG_ZYNQSDR=m           # WebSDR control/data plane
CONFIG_CMA_SIZE_MBYTES=64  # ≥ vendor's cma=36M headroom
```

Note: `CONFIG_FPGA_MGR_ZYNQ_FPGA=n` is a deliberate project decision (devcfg
conflict) — this forecloses the *official* RP stack's fpgautil/overlay loading
path, which is another reason the official stack is off the table.

## 3. Port inventory — no network conflicts

| Port | User | Conflict? |
|---|---|---|
| 22 | sshd (openssh) | — |
| 80 | RP app selector (tcpserver + apps/server/server) | free in our Debian (websdr is NOT on 80) |
| 1001 | RP app data stream (sdr_receiver / hpsdr / wide; trx_0) | free |
| 1002 | sdr_transceiver trx_1 (upstream Demin dual-channel) | free |
| 2947 | gpsd (localhost only) | shared, both stacks read-only clients |
| 8073 | websdr.bin (WebSocket + HTTP) | free |

Ports were never the problem; the FPGA is. The selector/web infrastructure can
even stay always-on — only the FPGA + app daemon switch.

## 4. Official Red Pitaya code — feasibility assessment

Research target: `github.com/RedPitaya/RedPitaya` (via DeepWiki).

### What the official stack is

- **Services:** `rp-nginx` (custom nginx + `ngx_http_rp_module` + WebSocket
  module, web UI), SCPI server (remote control over TCP), apps as `.so`
  plugins loaded by the web server, all on top of `librp` /
  `librp_hw` / `librp_dsp` / `librp_hw_profiles` API libraries.
- **FPGA loading:** `fpgautil` + device-tree overlays (`overlay.sh` /
  `fpga.sh`, bitstreams in `/opt/redpitaya/fpga/<MODEL>/.../*.bit.bin`) —
  i.e. the **fpga-manager** path, which we deliberately disabled.
- **Hardware access:** UIO (`/dev/uio/*`) and IIO (`/sys/bus/iio/...`), NOT
  `/dev/mem`; requires their devicetree/UIO region layout.
- **Kernel:** targets linux-xlnx **5.15**; userspace does cross-build for
  armhf.

### Why it does not fit the Web-888 (hardware-level)

| | STEMlab 125-14 (official target) | Web-888 |
|---|---|---|
| ADC | LTC2145, 125 MSPS, 14-bit, 2ch | **LTC2208, 130 MSPS, 16-bit, 1ch** |
| Clocking | fixed 125 MHz | **Si5351 programmable** (122.88 default; websdr re-tunes) |
| Front-end | 2 × RF in, jumpers | HF + **VHF** inputs, PE4312 DSA, antenna GPIO |
| DAC / TX | 2 × 125 MSPS DAC | **none** |
| FPGA design | official RP HDL (scope/gen/LCR...) | vendor `system_wrapper` (websdr / Demin-derived) |

Porting the official stack therefore means porting the official **FPGA HDL**
to a different ADC interface, clock tree, pinout, and GPIO/DSA scheme — a
Vivado engineering project of its own, with the reward being a scope/signal-
generator UI on a board that has no DAC and whose actual purpose is SDR
reception. **Verdict: reject.** (Also blocked software-side: official loading
needs fpga-manager overlays, which we intentionally turned off; their UIO
devicetree expectations would collide with our zynqsdr node layout.)

### The viable "Red Pitaya" stack: RaspSDR/red-pitaya-notes

- `github.com/RaspSDR/red-pitaya-notes` — the vendor's fork of
  pavel-demin/red-pitaya-notes, **already adapted to Web-888 hardware**
  (Howard Su's additions: `peri.c` PE4312 attenuator via sysfs GPIO
  523/525/524, HLv2 HPSDR protocol, Web-888 server naming). Full source:
  `projects/`, `cores/`, `cfg/`, Vivado 2023.1 Makefile flow.
- **Activity** (at time of research): last substantive work 2024-12
  (multi-channel fix, HLv2, att function, removed 122_88 apps); one
  "playground" commit 2025-04-30. The user's "几年没更新" is roughly right —
  ~1.5 years stale — but the codebase is small, stable, and matches the
  shipped bitstreams.
- **Apps (6):** led_blinker (FPGA smoke test), sdr_receiver (TCP 1001 raw I/Q),
  sdr_receiver_hpsdr (Hermes/HL2 → Thetis/SparkSDR/cuSDR/PowerSDR — the main
  user value), sdr_transceiver_ft8, sdr_transceiver_wspr (standalone decoders
  + PSK Reporter/WSPRnet upload), sdr_transceiver_wide (GNU Radio
  gr-osmosdr).
- **Kernel requirements:** none beyond `DEVMEM` + `xdevcfg` — apps mmap
  `cfg@0x40000000`, `sts@0x41000000`, `fifo@0x42000000` (the **same physical
  addresses** zynqsdr uses; only one stack owns the PL at a time).
- **Refresh path** if upstream pavel-demin has useful fixes: cherry-pick onto
  the RaspSDR fork — upstream apps target genuine Red Pitaya hardware and
  would *not* run unmodified on Web-888 (no peri.c attenuator support,
  different clocking assumptions).

## 5. Proposed Step-4 design (outline — to be planned in detail)

Mirrors the vendor-proven model on our Debian base:

```
/opt/redpitaya/apps/<app>/{<app>.bit, <app-binary>, start.sh, stop.sh, index.html}
/usr/sbin/web888-mode  websdr | <rp-app> | stop        # the switch
web888-websdr.service                                 # existing deb unit
web888-rpapp@.service (template)                      # one per RP app
```

Switch semantics:

- `web888-mode websdr`  → stop rpapp units → `systemctl start web888-websdr`
  (websdr loads its own bitstream — nothing else to do).
- `web888-mode <app>`   → `systemctl stop web888-websdr` →
  `cat <app>.bit > /dev/xdevcfg` → start `web888-rpapp@<app>` (binary runs as
  root or with a `/dev/mem` helper; vendor runs as root).
- Mutual exclusion enforced by a lockfile / systemd `Conflicts=` so the two
  stacks can never run concurrently (protects the shared PL + register space).
- Optional always-on selector on port 80 (nginx or the vendored
  `apps/server/server`) with a landing page linking to `:8073` (WebSDR) and
  triggering mode switches — UI polish, not a blocker.
- Bitstream source for v1: prebuilt `.bit` files from the vendor ZIP (match
  shipped hardware; rebuild from RaspSDR/red-pitaya-notes source only if we
  need changes — requires Vivado 2023.1).

### Interaction notes / risks

- **zynqsdr vs /dev/mem:** harmless — zynqsdr only touches PL registers when
  its ioctls are called, and websdr is stopped while an RP app runs. The
  module can stay loaded.
- **Si5351 clock state (OPEN QUESTION, verify on hardware):** the FSBL
  programs Si5351 (122.88 MHz) at boot; RP apps never touch Si5351 and assume
  the FSBL clock; websdr's peri_init re-programs it per ADC-clock config.
  After websdr has run, an RP app may see a different ADC clock than its
  bitstream expects → switch script may need to re-run the stock Si5351
  init sequence (`scripts/hw-test/si5351-init`) before loading the RP
  bitstream. Measure on hardware.
- **EMIO GPIO numbering (OPEN QUESTION):** hpsdr's peri.c drives the DSA via
  sysfs GPIOs 523/525/524 (base 512 + EMIO 11/13/12). Vendor RP DT has
  `emio-gpio-width=64`; our web888.dts follows the stock Web-888 DT (width 1).
  Under our 6.12 DT the sysfs base/width may differ → peri.c may need a small
  patch (or drive the DSA through the same bit-bang our zynqsdr uses — MIO
  13/12/11, already proven in step 2).
- **CMA:** vendor RP firmware boots `cma=36M`; we carry `CMA_SIZE_MBYTES=64`
  with no cmdline override — expected fine, confirm empirically.
- **GPS:** gpsd/chrony are shared read-only infrastructure for both stacks;
  no arbitration needed.
- **Root /dev/mem:** RP apps need root (vendor runs everything as root on
  Alpine). On Debian prefer a dedicated unit with `User=root` but tight
  sandboxing, or a small setuid helper. Resolved: apps run as root systemd
  units (`web888-rpapp@.service`).

## 6. Open questions — RESOLVED (step-4 execution)

**Execution updates (P0):** build deps verified from the pinned
source (`RaspSDR/red-pitaya-notes` @ `da1a7e3a`, `projects/<app>/server/Makefile`)
— v1 app set needs **gcc + libm only** (`sdr_receiver`), plus **pthread** for
`sdr_receiver_hpsdr` and `sdr_transceiver_wide`. No other libraries, no
Alpine/musl-isms in the build flags (`-O3 -march=armv7-a -mtune=cortex-a9
-mfpu=neon -mfloat-abi=hard [-D_GNU_SOURCE]`). The vendored ZIP's C sources are
byte-identical to the pinned repo (verified by diff). v1 app set decided per
the v1 app-set decision: hpsdr + receiver + led_blinker, wide included if it compiles cleanly
(so item 3 below is settled for v1).

1. **Si5351 re-init on websdr→RP switch? RESOLVED — NO.**
   `sdr_receiver` AND `sdr_receiver_hpsdr` both stream live data immediately
   after an active websdr session with no Si5351 re-init (P4.2/P4.3).
   `SI5351_RESET=0` is the shipped default; the opt-in hook stays for
   field problems. Evidence in `hardware-facts.md`.
2. **EMIO GPIO base for hpsdr peri.c DSA? RESOLVED.** gpiochip512
   (base=512, ngpio=118) matches peri.c's assumption exactly, but the sysfs
   path is unusable: the zynqsdr kernel driver owns MIO 11/12/13 → export
   fails EBUSY → vendor peri.c dereferenced NULL FILE* and SEGV'd. Resolved
   by `config/redpitaya/patches/0001-peri-use-zynqsdr-ioctl.patch`: DSA
   writes go through the driver's `ZYNQSDR_AD8370_SET` ioctl (bitstream-
   agnostic, step-2 proven). Verified live (ATT=20 write + discovery +
   7.36 MB/3 s streaming). Also fixed the NULL-deref crash path.
3. **Apps in v1: settled** — all four (`led_blinker`, `sdr_receiver`,
   `sdr_receiver_hpsdr`, `sdr_transceiver_wide`; wide built clean → included).
4. **Selector UI: CUT for v1** — `web888-mode` CLI + systemd only;
   port-80 nginx selector deferred to a later milestone.
5. **TX-capable apps:** unchanged — TX treated as experimental; v1 gates are
   RX-only.

**Behavioral facts learned on hardware (deb 2025.430-2):**

- websdr.bin needs ~30-35 s to re-bind :8073 after an RF-active RP app ran
  (silent FPGA/clock restore inside the closed binary); after led_blinker
  (PL idle) restore is <3 s; at fresh boot :8073 is up within seconds.
  Tests must poll, never fixed-sleep.
- `StartLimit{IntervalSec,Burst}` must live in the unit's [Unit] section —
  in [Service] systemd 257 logs "Unknown key" and ignores them. Tuned to
  10/120 s (5/60 s blocked legitimate ×10 round-trip switching; 10/120 s
  still bounds crash-loop PL churn to ~75 loads/15 min).
- The rpapp unit needs `DeviceAllow=/dev/zynqsdr rw` (patched peri.c) on
  top of /dev/mem, /dev/xdevcfg, /dev/i2c-0 and /sys/class/gpio rw.
- HPSDR discovery broadcasts must target the actual /17 broadcast
  (the LAN's actual broadcast address, which may not be a /24) or 255.255.255.255 — a /24 guess never reaches the box.
- QEMU (11.0.2) exposes /dev/xdevcfg but a bitstream WRITE hard-hangs the
  guest kernel — all bitstream runtime testing is hardware-only.
- Device hang incident (~15 min of SEGV crash-loop churning devcfg every
  ~4 s → box dropped off the network): root SEGV fixed by patch 0001;
  recurrence bounded by the StartLimit above. Power-cycle recovered.

## References

- Internal: `redpitaya-port-guide.md` (prior design + vendor validation),
  `../research/red-pitaya-firmware.md` (vendor RP firmware analysis,
  CONFIRMED facts), `../research/zynqsdr-port-notes.md` (websdr driver/ABI),
  `../research/hardware-facts.md`.
- External: DeepWiki syntheses of `RedPitaya/RedPitaya` and
  `pavel-demin/red-pitaya-notes`; GitHub commit listing of
  `RaspSDR/red-pitaya-notes` (HEAD `da1a7e3a`, 2025-04-30).
- Vendor bitstreams: `red-pitaya-alpine-3.20-armv7-20241228.zip` analysis in
  `red-pitaya-firmware.md`; websdr bitstreams in `resources/stock-card/`.
