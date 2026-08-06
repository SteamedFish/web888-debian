# Web-888 vs KiwiSDR: Comprehensive Code Comparison

> **Purpose of this document:** a commit-level comparison of **Web-888 (RaspSDR/server)**
> and **KiwiSDR (jks-prv/KiwiSDR)**, structured to drive a **cherry-pick patch set**
> (the next session's goal). All claims below were verified against the live source
> trees directly, not inferred from commit messages.

## Executive Summary

Both projects descend from the same KiwiSDR codebase and are actively maintained. The
**extension API, the WebSocket/`SET`/`MSG` network protocol, and the web UI remain
source-compatible** — which is exactly what makes cross-porting feasible.

- **Web-888** (`RaspSDR/server`) targets the **RX-888 / Xilinx Zynq-7010**. It is a
  modernization fork: CMake build, a Linux **kernel driver** for the ADC data path
  (`/dev/zynqsdr`), pthreads, hardware GPS via gpsd, plus SpyServer/HPSDR protocol
  servers, MQTT, and a binary OTA-update system. Development is slower but
  architecturally divergent.
- **KiwiSDR** (`jks-prv/KiwiSDR`) targets the **BeagleBone (AM3358)** family. It is the
  upstream origin, moves fast (regular versioned releases), and retains the original
  direct-ARM-SPI data path, native Makefile build, full **software-defined GPS**, and
  **includes the FPGA Verilog source**.

**Bottom line for cherry-picking:** port at the **extension / web-UI / protocol** layer.
Avoid the platform (`zynq/`, `platform/`) and build-system layers — those are the
hard divergences.

## Correction vs. the previous version of this doc

The 2026-03-31 version characterized KiwiSDR's data path as **"PRU + SPI"** with a
"`pru/` directory" and "`pru_realtime.c` / `pru_spi.c`". **That is wrong.** Verified
against the current KiwiSDR tree:

- There is **no `pru/` directory** and **no PRU code** in the Kiwi-1 data path.
- The only "PRU" references in the tree are generic BeagleBone-AI-64 device-tree
  cape/pin overlays — unrelated to the ADC transfer.
- Kiwi-1 transfers ADC samples via **direct ARM SPI using memory-mapped programmed I/O**
  (`platform/common/spi_pio.h`, `platform/common/spi.cpp`, `platform/beaglebone/peri.cpp`),
  gated by `peri.cpp:561` (`!use_spidev || debian_ver >= 9`). The real-time constraint
  is enforced by a **user-space scheduler** in the server, not by a PRU co-processor.

So the real architectural axis is **"Linux kernel driver + DMA (`/dev/zynqsdr`)"**
(Web-888) vs **"user-space memory-mapped SPI + cooperative scheduler"** (KiwiSDR), not
DMA-vs-PRU.

## Repository Overview

| Attribute | Web-888 (RaspSDR) | KiwiSDR |
|-----------|-------------------|---------|
| **Repository** | https://github.com/RaspSDR/server | https://github.com/jks-prv/KiwiSDR |
| **Status** | Active (slow cadence) | Active (regular releases) |
| **HEAD @ analysis** | `68a64e1` (2026-06-07) | `c40ecb4` (2026-07-22) = **v1.902** |
| **Version scheme** | Build-time `VERSION_MAJ`=year / `VERSION_MIN`=month+day (in `version.h`); prints inherited string `KiwiSDR v<maj>.<min>` | Semver-style `v1.902`, tracked in `CHANGE_LOG` |
| **Primary author** | Howard Su (`howard0su`) | John Seamons (`jks-prv`, 745 commits) |
| **Notable contributor** | — | Christoph Mayer (`hcab14`/DL1CH) — all client-side FFT work |
| **Fork point** | ~2023 from KiwiSDR | Origin (moved from archived `Beagle_SDR_GPS`) |
| **Hardware** | RX-888 (Zynq-7010, 512 MB) | KiwiSDR 1 (BeagleBone Black) / Kiwi-2 / BBB-AI64 / BeagleY-AI |
| **Branch model** | `master` + `develop` + `copilot/*` + `adoptive_buf` | `master` published; `develop` is integration (PRs merge develop→master) |

## What changed since the previous doc

- **Web-888:** **12 commits** on `master`. Headlines: **CTC (Chinese TeleType Code)**
  support added across FSK + NAVTEX with a Node.js test harness; LTO **disabled**;
  EiBi database refreshed to A26; MQTT client bug fix (#84); a NAVTEX UI hover-flash
  fix + revert.
- **KiwiSDR:** **184 commits** on `master`, advancing **v1.832 → v1.902**. This is the
  much larger delta and the primary source of cherry-pick candidates. Headlines:
  - **v1.900** — new **"Full 8 channel" mode** (rx8/wf8) with auto-migration of public
    rx4/wf4 and rx8/wf2 Kiwis.
  - **v1.901** — **client-side (browser) FFT with millihertz resolution** (zoom-FFT
    decimation + Ooura FFT), by Christoph.
  - **v1.902** — FFT peak tracking; ALE URL user-list fix; SNR-meas kick button;
    **CHU removed** from timecode/FSK/TDoA.
  - v1.840/v1.841 — **security fixes/improvements** (IP parsing hardening, etc.).
  - Sustained **mobile / narrow-screen** UI work and minimized-bundle fixes.

## Architecture Comparison

### Hardware Platform

| Aspect | Web-888 (RX-888) | KiwiSDR 1 (BeagleBone Black) |
|--------|------------------|------------------------------|
| **SoC** | Xilinx Zynq-7010 (PS+PL) | TI AM3358/AM3359 |
| **CPU** | Dual Cortex-A9 @ 667 MHz | Cortex-A8 @ 1 GHz |
| **Co-processor** | FPGA fabric integrated in Zynq | none in CPU (no PRU used) |
| **Memory** | 512 MB DDR3 | 512 MB DDR3 |
| **ADC** | LTC2208 (16-bit, 130 MSPS) | LTC2248 (14-bit, 66.67 MSPS) |
| **Ethernet** | 1000 Mbps | 100 Mbps |
| **FPGA** | Artix-equivalent in Zynq PL | Artix-7 A50 (on the Kiwi board) |

### Data Transfer Architecture (the core divergence)

**Web-888 — kernel driver + DMA:**
```
FPGA (PL) ──AXI DMA──► /dev/zynqsdr (kernel driver) ──read()/ioctl()──► ARM user space
  • Zero-copy; CPU not busy-waiting during transfer
  • Standard pthread scheduling; blocking syscalls allowed
  • Clock discipline: PID controller on Si5351, tuned by hardware PPS
  • Code: zynq/{peri,system,timer,leds}.cpp  +  /dev/zynqsdr ioctl.h
```

**KiwiSDR 1 — memory-mapped SPI + cooperative scheduler:**
```
FPGA ──SPI──► ARM (memory-mapped, programmed I/O) ──► user-space server loop
  • CPU polls the SPI regs directly; no kernel ADC driver, no PRU
  • User-space real-time scheduler; blocking calls forbidden in the hot path
  • Code: platform/common/{spi,spi_pio,timer}.{cpp,h}, platform/beaglebone/peri.cpp
```

### Consequences (still true, restated without the PRU myth)

| Aspect | Web-888 | KiwiSDR |
|--------|---------|---------|
| **CPU during transfer** | Not busy (DMA) | Polling the SPI path |
| **Scheduling** | Linux kernel scheduler | User-space cooperative scheduler |
| **Blocking calls in extensions** | ✅ Allowed (real threads) | ❌ Must stay async/non-blocking |
| **Extension complexity** | Simpler (can block) | More constrained |

## Build System Comparison

### Web-888 — modern CMake (`CMakeLists.txt`)

- `cmake_minimum_required(VERSION 3.13)`, `project(RaspSDR)`, **C++11**.
- **ARM flags** (when `CMAKE_SYSTEM_PROCESSOR` matches arm/aarch64): `-march=armv7-a
  -mtune=cortex-a9 -mfpu=neon -mfloat-abi=hard -mvectorize-with-neon-quad`, defines
  `ARM_MATH_NEON`/`ARM_MATH_LOOPUNROLL`/`__ARM_NEON`. Non-ARM → **emulator** path
  (disables HFDL).
- **LTO disabled** (line commented out + commit `691a72e` "Disable LTO"); **ccache**
  auto-enabled when present.
- **Auto-generated extension registration** via `file(GENERATE ... extint.cpp)`
  emitting `void extint_init(){ <each>_main(); ... }`.
- pkg-config deps: `fftw3f zlib fdk-aac libgps libunwind sqlite3 libcurl openssl`;
  `libconfig++` static on target; `fftw3f` linked as `.a`.
- Build-time extras: `eibi_proc` downloads `sked-a26.csv` and generates `EiBi.h`;
  `web/mkdata.pl` embeds web assets; optional JS/CSS **minify**.
- **CI** (`.github/workflows/build.yml`): ubuntu-latest, cmake+ninja, Release,
  `-DENABLE_HDFL=OFF` (i.e. builds the x86 emulator).

### KiwiSDR — traditional Makefile (`Makefile` + `Makefile.comp.inc`)

- Native-compilation-oriented: platform detected from `/etc/dogtag`
  (`DEBIAN_DEVSYS`). **clang/clang++** on target (pinned per Debian release: plain
  `clang` / `clang-11` / `clang-8` / `clang-6.0`); gcc only on the dev machine.
- Per-platform `FP_FLAGS`: BBB/BBG → `-mtune=cortex-a8 -mcpu=cortex-a8 -mfpu=neon-vfpv3
  -mfloat-abi=hard`; BBB-AI → cortex-a15; AI-64/BeagleY-AI → cortex-a72/a53, arm64,
  `-DMULTI_CORE`. `-std=gnu++11`, `-Ofast`.
- Cross-compile supported via `make XC=-DXC` (clang `--target` + sshfs sysroot) —
  produces the ARM `kiwi.bin` only.
- **Extension registration is ALSO auto-generated** (corrects the prior doc's "manual"
  claim): `extensions/Makefile` emits `build/gen/ext_init.cpp` from `$(wildcard
  extensions/*/)`. `main.cpp` just calls `extint_setup()`.

## Code Structure Comparison

### Directory Layout

**Web-888:**
```
RaspSDR-server/
├── CMakeLists.txt            # CMake
├── zynq/                     # platform: kernel-driver + DMA (peri,system,timer,leds + ioctl.h)
├── extensions/   (29 dirs)   # auto-registered
├── net/                      # net.cpp, ip_blacklist.cpp, mqttpub.cpp, update.cpp(OTA), services.cpp
├── web/                      # kiwi/ + openwebrx/ (both UIs embedded) + pkgs/mongoose
├── gps/                      # hardware GPS via libgps/gpsd
├── hpsdr/                    # HPSDR/metis protocol server
├── pkgs/sdrpp_server/        # SpyServer protocol server (Web-888 only)
├── rx/ ui/ support/ si5351/ init/ externals/dumphfdl/
├── tests/  tools/
└── .github/workflows/        # CI
```

**KiwiSDR:**
```
KiwiSDR/
├── Makefile, Makefile.comp.inc
├── platform/                 # beaglebone(_black)/beaglebone_AI64/beagleY_AI/raspberrypi/common
│   └── common/               # spi.cpp, spi_pio.h, timer.cpp  (the SPI data path)
├── extensions/   (27 dirs)   # auto-registered (gen/ext_init.cpp)
├── net/                      # net.cpp, ip_blacklist.cpp, services.cpp, update.cpp
├── rx/                       # rx_server.cpp defines the SND/WF/EXT/ADMIN stream table
├── web/                      # kiwi/ + openwebrx/ + extensions/ + minimized bundles
├── gps/                      # full software-defined GPS (Andrew Holme receiver, GNSS-SDRLIB, ka9q-fec)
├── verilog/                  # FULL FPGA RTL: kiwi.v cpu.v host.v + gps/ + rx/ (DDC chain)
├── verilog.Vivado.2022.2.ip/ # pre-packaged Xilinx IP cores
├── *.bit / *.aout            # prebuilt per-mode FPGA bitstreams (rx8.wf3, rx4.wf4, rx14.wf0 ...)
└── tools/ dx/ cfg/ dev/ e_cpu/
```

### Key File Differences

| Component | Web-888 | KiwiSDR |
|-----------|---------|---------|
| **Platform code** | `zynq/` (kernel driver + DMA) | `platform/{beaglebone,common}/` (memory-mapped SPI) |
| **Real-time** | `/dev/zynqsdr` ioctl + DMA | `platform/common/spi*.cpp` + user-space scheduler |
| **Build** | `CMakeLists.txt` | `Makefile` + `Makefile.comp.inc` |
| **Extension registration** | `file(GENERATE extint.cpp)` | Makefile `gen/ext_init.cpp` (both auto) |
| **FPGA source** | **Not included** | **Included** (`verilog/`) + prebuilt `.bit` |
| **GPS** | hardware, via gpsd (`libgps`) | software-defined (`gps/`, MAX2769B frontend) |

## Extension System Comparison

### Extension sets

| | Web-888 (29) | KiwiSDR (27) |
|---|---|---|
| **Shared** (present in both) | ALE_2G, colormap, CW_decoder, CW_skimmer, devl, digi_modes, DRM, example, FAX, FFT, FSK, FT8, HFDL, IBP_scan, IQ_display, Loran_C, NAVTEX, prefs, s4285, S_meter, SSTV, TDoA, timecode, wspr, iframe | (same) |
| **Web-888 only** | `ant_switch`, `noise_blank`, `noise_filter`, `waterfall` | — |
| **KiwiSDR only** | — | **`FreeDV`**, **`sig_gen`** |
| **Note** | TDoA: JS frontend + 61-line backend stub, "disabled for now" | ant_switch/noise_blank/noise_filter/waterfall **deleted as extensions in v1.666** — functionality moved into the main control panel (RF/Audio/WF tabs); ant_switch became a 775-line integrated subsystem in `pkgs/ant_switch/` + shell-script backends. FreeDV's backend is a 235-line stub; decode is client-side WASM from `freedv.kiwisdr.com` |

### Extension API (still compatible — the basis for cherry-picking)

Both expose the same heritage API (`extensions/ext.h`, `ext_int.h`):

```cpp
void ext_register(ext_t* ext);
void ext_send_msg(int rx_chan, bool debug, const char* msg, ...);
void ext_register_receive_iq_samps(ext_receive_IQ_samps_t func, ...);  // PRE_AGC / POST_AGC
void ext_register_receive_FFT_samps(...);   // PRE_FILTERED / POST_FILTERED
void ext_register_receive_real_samps(...);
void ext_register_receive_S_meter(...);
void ext_register_receive_cmds(...);
```

`ext_t` fields (`name`, `version = EXT_NEW_VERSION = 0xcafebeef`, `flags`
`EXT_FLAGS_HEAVY`, `poll_cb`, …) match. **Extensions are largely portable between the
two trees**, modulo: (a) the `ext_register_receive_*` callback wiring, (b) any
blocking assumptions (fine on Web-888, risky on Kiwi), and (c) the auto-registration
list in the respective build file.

## Network Protocol Comparison

### WebSocket protocol (near-identical)

| Feature | Web-888 | KiwiSDR |
|---------|---------|---------|
| **Transport** | WebSocket (embedded mongoose **5.6**, 2018-era) | WebSocket (embedded mongoose **7.14**, upgraded v1.818 to fix dropped proxy headers; v1.819 keeps old non-`/ws` URL compat) |
| **Stream kinds** | `SND`, `WF`, `EXT` (+ ADMIN via HTTP) | `SND`, `W/F`, `EXT`, `ADMIN` (+ `MON`, `MFG`) |
| **Audio codec** | ADPCM 4:1 | ADPCM 4:1 |
| **Command prefix** | `SET …` | `SET …` |
| **Response prefix** | `MSG …` | `MSG …` |

KiwiSDR defines its stream table in `rx/rx_server.cpp` (`rx_streams[]`,
`STREAM_ADMIN/MFG/SOUND/WATERFALL/EXT/MONITOR`); Web-888 mirrors this in
`net/net.h` (`ICONN_WS_SND|WF|EXT`).

### HTTP / security surface

| Aspect | Web-888 | KiwiSDR |
|--------|---------|---------|
| **HTTP server** | embedded mongoose (`web/web_server.cpp`), CORS `*`, SSL on | embedded mongoose (`web/web_server.cpp`) |
| **IP blacklist** | ✅ `net/ip_blacklist.cpp` (512-entry hash, CIDR, whitelist, auto-download, iptables shelling) | ✅ `net/ip_blacklist.cpp` (same lineage) |
| **Strict IP helpers** | inherited | ✅ `isLocal_ip()`, `inet4_d2h_strict()`, `is_valid_ipv6_strict()` (hardened v1.840/841) |
| **Per-IP / dup-conn limits** | ✅ inline in `net/net.cpp` | ✅ channel-count caps |
| **Honey-pot** | `OPTION_HONEY_POT` (commented) | ✅ trap for unauth SND/WF (`rx_cmd.cpp`) |
| **Rate limiting** | ⚠️ no dedicated module (conn-count only) | ❌ none (channel-count only) |

## GPS Implementation Comparison

| Feature | Web-888 | KiwiSDR |
|---------|---------|---------|
| **Approach** | Hardware GPS module → gpsd → `libgps` | **Software-defined GPS receiver** |
| **Frontend** | ATGM336H (NMEA to gpsd) | MAX2769B RF front-end |
| **Positioning** | Parsed NMEA fixes | Full acquisition/tracking/EKF solver (GPS L1 + Galileo E1B) |
| **PPS** | Hardware PPS → FPGA → `fpga_read_pps()` → PID on Si5351 | Software timing |
| **Code** | `gps/gps.cpp` (~300 lines, gpsd client) | `gps/*.cpp` + `GNSS-SDRLIB` + `ka9q-fec` (large) |

## Web-888-only features (no Kiwi counterpart to port)

| Feature | Location | Notes |
|---------|----------|-------|
| **SpyServer protocol** | `pkgs/sdrpp_server/` | lets SDR++ connect via `sdr://`; own accept/write loop |
| **HPSDR/metis protocol** | `hpsdr/` | HL2/Thetis-compatible discovery + EP2/EP6 |
| **MQTT publish** | `net/mqttpub.cpp` + `pkgs/mqtt-c/` | start/stop events; fixed #84 |
| **Binary OTA update** | `net/update.cpp` | pulls from `downloads.rx-888.com`, sha256-verified, atomic swap |
| **CTC support** | FSK + NAVTEX | Chinese TeleType Code (recent, with Node.js tests) |
| **OpenWebRX UI** | `web/openwebrx/` | embedded alternate frontend |
| **EiBi build-time DB** | `eibi_proc` (CMake) | auto-downloads sked list → `EiBi.h` |

---

## Cherry-Pick Analysis (comprehensive plan — see docs/dev/web888-kiwisdr-cherry-pick-plan.md)

> **Update (comprehensive):** the first pass (below) only surveyed
> KiwiSDR's recent 184 commits and found ~2 portable. That was the wrong
> denominator. A full-history survey of all three repos (`Beagle_SDR_GPS` →
> `KiwiSDR`, vs Web-888) found Web-888 forked from `Beagle_SDR_GPS` around
> **2024-02-22**, so the real upstream delta is ~2.5 years. The comprehensive
> plan is in `docs/dev/web888-kiwisdr-cherry-pick-plan.md`; status tracked in
> `config/websdr/cherry-picks.manifest`.
>
> **Net finding:** beyond the 2 already-applied patches (0101 CHU, 0104 IP-security),
> there are **4 GREEN** (trivial macros/string) + **15 YELLOW** (portable with
> adaptation, including the high-value `37f65b4b` admin-password==serial detection
> and FT8 freq-sort) across the shared C++ backend (`support/`, `rx/CuteSDR/`,
> `rx/wdsp/`, `net/`). The recurring RED blockers are the **coroutines.cpp rewrite**,
> the **SPI/misc_miso layer absence** (kernel driver), the **divergent web/ frontend**,
> the **SNR API fork**, and **kiwisdr.com-specific proxy/TDoA/my.kiwisdr.com infra**.
> GPS is entirely RED (software-GPS engine vs Web-888's gpsd).
>
> **Critical correction from actual porting work:** the tiers below
> were drafted from commit messages and assumed the `web/` frontend was shared.
> It is not — Web-888's `admin.js`/`kiwi.js` are an independent, older layout
> lacking the `id-admin-top`/`w3_inline_noencl`/`WIN_WIDTH_NOM` infrastructure
> the mobile/FFT patches depend on. Verdicts below reflect that.
>
> **Second-pass deep survey:** the first-pass plan only saw the 62
> shared-and-diverged files. A full CHANGE_LOG v1.664→v1.902 read + tree-level
> diff found a second layer of candidates: **~16 additional small ports** (e.g.
> PSKReporter fragmentation fix `PR_BUF_LEN 1190` — Web-888 still has the bug;
> FT8/WSPR V-UHF+QO-100 freqs; SSTV R36-BW; `MODE_FLAGS_SCAN`; ipset blacklist;
> FAX recording rework with a real info-leak angle) and **6 ranked feature-port
> epics** that are not cherry-picks: Mongoose 5.6→7.14 (foundational — gates FSK
> UDP, DRM RSCI, proxy-header robustness), admin.js re-sync (3329 vs 5875 lines;
> the entire v1.666+ admin feature set is absent), user-UI bundle, rx_snr.cpp
> reimplementation, FreeDV/sig_gen/iframe-multi/ant_switch-integrated, and a
> gpsd-backed `/gps` JSON endpoint. Full detail: the "Second-pass deep survey"
> section of `docs/dev/web888-kiwisdr-cherry-pick-plan.md`.

This is the section the next session will build on. Candidates are grouped by effort
and keyed to **KiwiSDR→Web-888** (the direction with the large 184-commit delta) and
**Web-888→KiwiSDR**.

### Tier 1 — Easy / self-contained (UI, JS, protocol, pure logic)

These touch only `web/`, extension `.js`, or generic C helpers — no platform or
build-system coupling. **Re-graded after hands-on porting**:
verdicts marked ✅/❌ reflect what actually happened.

| Source | Commit(s) | What | Verdict |
|--------|-----------|------|---------|
| Kiwi→Web | v1.840/v1.841 security (`6f21031`) | `isLocal_ip()` / `inet4_d2h_strict()` / `is_valid_ipv6_strict()` in `net/net.cpp` + `ip_blacklist.cpp` | ✅ **APPLIED** as `0104` — `net/` is the shared lineage; adapted (const char*, no kiwi_emptyStr/ansi.h, dev→zynq leds) |
| Kiwi→Web | `c3b4c06` remove CHU | FSK freq menu + TDoA refs `.cjson` | ✅ **APPLIED** as `0101` — pure data files, GREEN |
| Kiwi→Web | `1a4a1af` URL-encode user & host | `net/services.cpp` reg fields | ❌ **DROPPED** — Web-888 rewrote registration to rx-888.com API; no `rev_user`/`rev_host` exists; the `email` field it does send is already URL-encoded |
| Kiwi→Web | `c8f839c` admin narrow-screen top bar | `web/kiwi/admin.js` | ❌ **DROPPED** — Web-888's `admin.js` is a fully divergent older layout; the `id-admin-top`/`id-admin-scroll` DOM it rewrites does not exist |
| Kiwi→Web | `2ac60e5`, `09418b3`, `b7baae9` | narrow-screen / mobile UI | ⚠️ PENDING, likely RED — depend on `w3_inline_noencl`/`WIN_WIDTH_NOM` (absent in Web-888); only `manifest.json` add is plausibly portable |
| Kiwi→Web | `53328ae` | `time_display_width()` → `kiwi.time_display_width` refactor | ⚠️ PENDING — mechanical rename, but verify per-extension `.js` |
| Kiwi→Web | `ef22aeb` | SNR-meas "kick" button | ❌ PENDING/RED — `rx_snr.cpp` absent in Web-888; logic is in `rx/rx_util.cpp`; needs rewrite, not cherry-pick |
| Web→Kiwi | `01e9a2f` | Safari 26.2 blank-page WebSocket workaround | `web/kiwi/kiwi_util.js` (Web-888 already notes "PORT FROM KIWISDR" — may already be upstream) |
| Web→Kiwi | `bccebc9f`-era | Don't send Content-Length | mongoose HTTP tweak |

### Tier 2 — Moderate (extension backends, needs API/callback reconciliation)

Extension code is portable but each port needs the `ext_register_receive_*` wiring
re-checked against Web-888's `ext.h`, and added to the CMake `EXTENSIONS` list.

| Source | Commit(s) | What | Caveat |
|--------|-----------|------|--------|
| Kiwi→Web | v1.901 (`13c3d8d`,`4b365f8`,`9e83898`, `326b99a`,`f8f8fc7`) | **Client-side browser FFT, millihertz resolution** (Ooura + zoom-FFT) | mostly `web/extensions/FFT/*.js`; big but high-value; Christoph's work |
| Kiwi→Web | v1.902 (`326b99a`,`f8f8fc7`) | FFT peak tracking + readout | extension JS + backend |
| Kiwi→Web | `595b51b` | FreeDV stability improvements | **requires porting the `FreeDV` extension Web-888 lacks** |
| Kiwi→Web | v1.900 CIC compensation filter | 8-channel CIC comp (Christoph) | only relevant if Web-888 adopts 8-ch mode |
| Kiwi→Web | `c472a26` | ALE: don't menu-match in user-list mode | extension backend |
| Kiwi→Web | `c3b4c06` | remove CHU from timecode/FSK/TDoA | multi-extension coordinated removal |
| Web→Kiwi | `0ddfbf4`-era | SpyServer / HPSDR | **large; Kiwi has no equivalent** — likely out of scope |
| Web→Kiwi | CTC (FSK/NAVTEX) | Chinese TeleType Code | region-specific feature |

### Tier 3 — Hard / not portable as-is

| Item | Why hard |
|------|----------|
| **8-channel mode** (v1.900 rx8/wf8) | touches FPGA bitstream (Kiwi includes `verilog/`, Web-888 does **not** have the RTL), DDC chain, WF allocation, channel caps — not a code cherry-pick |
| **Software GPS** (Kiwi) vs **gpsd hardware GPS** (Web-888) | fundamentally different `gps/` trees; MAX2769B vs ATGM336H |
| **Kernel driver vs SPI data path** | `zynq/` vs `platform/`; the irreducible platform split |
| **CMake ↔ Makefile** | build-system changes don't translate |
| Kiwi multi-platform (`beaglebone_AI64`, `beagleY_AI`, `raspberrypi`) | Beagle-family-only; irrelevant to Zynq |

### Suggested patch-set ordering (for the next session)

> **Outcome:** only steps 1 & 4 partially landed. Steps 2-3 turned
> out RED on hands-on verification — see `config/websdr/cherry-picks/PROVENANCE.md`.
> The patch set is **complete at stages 1-2**; the portable surface (the `net/`
> C++ layer + pure data files) is exhausted. Further alignment needs feature
> ports, not cherry-picks.

1. ✅ **Security:** Kiwi `isLocal_ip`/`inet4_d2h_strict`/`is_valid_ipv6_strict` →
   Web-888 `net/` + `ip_blacklist` — landed as `0104`.
2. ❌ **Web UI fixes:** narrow-screen/mobile + `time_display_width` refactor —
   all RED; depend on `w3_inline_noencl`/`WIN_WIDTH_NOM`/`kiwi.time_display_width`
   infrastructure Web-888 does not have.
3. ❌ **Extension features:** FFT client-side, SNR-meas kick, ALE user-list fix —
   all RED; `web/extensions/` JS is structurally divergent, `rx_snr.cpp` is absent.
4. ✅ **CHU removal** — landed as `0101` (the data-file piece).
5. **Evaluate-only (future):** FreeDV port (adds a missing extension) and 8-channel
   mode (needs FPGA RTL Web-888 lacks) — both are feature ports, not cherry-picks.

### How to extract a candidate

```bash
# KiwiSDR source tree (analysis clone at .tmp/repos/KiwiSDR, or re-clone)
cd KiwiSDR
git format-patch -1 <commit> -o /tmp/patches   # one commit
git format-patch <since>..<until> -o /tmp/patches  # a range (e.g. an FFT series)

# Inspect against the Web-888 target tree
cd work/websdr-src   # RaspSDR/server
git checkout -b cherry-pick/<topic>
# apply with:
patch -p1 < /tmp/patches/0001-*.patch   # or `git am` / `git cherry-pick` after adding Kiwi as a remote
```

When applying, expect to reconcile: (a) the extension's `ext_register` block, (b) the
`EXTENSIONS` list in `CMakeLists.txt`, (c) any `pru/`/`platform/`-specific includes
that won't exist on the Web-888 side, and (d) minified `.min.js` artifacts (rebuild
via the CMake `minify` step or the Kiwi `FILE_OPTIM` target).

## Recommendations

- **Do cherry-pick** at the extension / web-UI / protocol layer. The shared
  `ext_register` API and `SET`/`MSG` protocol are the stable interface.
- **Prioritize** Kiwi's v1.840/841 security hardening and the client-side FFT work —
  both are high-value and comparatively isolated.
- **Do not** attempt to port the platform layer, the data path, or the GPS
  implementation — those are the genuine architectural forks.
- **Verify each patch against binaries** before relying on it (per project AGENTS.md:
  the rest of `docs/` is AI-generated material; load-bearing claims must be checked).
- For 8-channel mode and anything FPGA-related, Kiwi can move forward (it has
  `verilog/`); Web-888 cannot without obtaining the RX-888 FPGA source separately.

## Conclusion

The two trees share heritage and remain source-compatible at the extension/protocol/UI
layer, which is exactly the surface cherry-picking should target. Since the previous
doc, KiwiSDR has moved far further (184 commits, v1.832→v1.902, including the
client-side FFT and 8-channel mode) while Web-888 has focused on platform
modernization and region-specific features (CTC, SpyServer/HPSDR, OTA). The previous
doc's central architectural claim (KiwiSDR uses a PRU) was incorrect and is corrected
here: KiwiSDR uses direct ARM memory-mapped SPI with a user-space scheduler.

---

*Revised (adds Mongoose 5.6-vs-7.14 divergence, Kiwi extension
deletions v1.666, TDoA/FreeDV/ant_switch detail, second-pass survey pointer)*
*Based on Beagle_SDR_GPS `efb38e2`, KiwiSDR `c40ecb4` (v1.902), Web-888 `68a64e1` (2026-06-07).*
*Analysis trees: `work/websdr-src/` (Web-888), `.tmp/repos/KiwiSDR/`, `.tmp/repos/Beagle_SDR_GPS/` (scratch clones).*
*Comprehensive cherry-pick plan: `docs/dev/web888-kiwisdr-cherry-pick-plan.md`; patch set + status: `config/websdr/cherry-picks/` + `cherry-picks.manifest`; upstream re-check: `scripts/refresh-cherry-picks.sh`.*
