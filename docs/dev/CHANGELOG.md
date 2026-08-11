# Changelog — web888-debian

All notable changes to this project are recorded here, newest first.
This log starts at the first public release; earlier history is preserved
on the pre-cleanup archive branch (see AGENTS.md).

Format: `## [version/date] — title`, then grouped bullet entries
(Added / Changed / Fixed / Removed). Every PR, commit series, or
behaviour-affecting change MUST add an entry here (see AGENTS.md —
this is a hard project rule).

## [2026-08-11] — websdr: KiwiSDR rx_snr SNR framework port (cherry-pick 0149)

### Added

- **Cherry-pick 0149: port KiwiSDR's `rx_snr` SNR measurement framework**
  (plan doc step B.4). `rx/rx_snr.{h,cpp}` imported wholesale and adapted
  to Web-888's scheduler (TaskSleepSec/TaskWakeupF instead of coroutine
  deadline flags Web-888 lacks), globals (`freq_offset_kHz`,
  `MAX_ZOOM` ≡ upstream `ZOOM_CAP`, moved to `rx_waterfall.h`), and missing
  helpers (`cfg_true`/`cfg_int_` local macros). Old hourly-only SNR block
  removed from `rx/rx_util.{h,cpp}`. Gains vs the old code: VDSL
  strong-signal run filter (`snr_filter_*` cfg), minute-granularity and
  fully custom measurement intervals (`snr_meas_custom_min`), custom band
  definition, ham-band and AM-broadcast-band measurements (gated by
  `snr_meas_ham`), `/snr` JSON now reports `imin`/`ant` and float band
  edges, and the admin **"Measure SNR now"** button finally triggers an
  on-demand measurement server-side (`SET snr_meas` →
  `TaskWakeupF(SNR_meas_tid)`; previously a UI no-op). New local
  `snd_send_msg()` with `SM_SND_ADM_ALL` (upstream port) pushes
  `snr_stats` spinner feedback to live admin pages. `web/kiwi/admin.js`
  gains the full v1.902 SNR options UI (9-entry interval select, custom
  interval/band inputs, measuring spinner). KiwiSDR's
  `snr_meas_ant_sw`/ant-switch integration deliberately skipped — Web-888's
  ant_switch extension has no SNR coupling. New patch
  `config/websdr/cherry-picks/0149-kiwi-rx-snr-port.patch`; deb
  `web888-websdr 2026.730-5`.

## [2026-08-11] — websdr: mongoose EPOLLERR graceful-close fix (0148)

### Fixed

- **Cherry-pick 0148 (Web-888 local): `/admin` websocket `socket error 2`
  drops.** epoll `EPOLLERR` in mongoose's `mg_iotest()` also fires on a
  graceful peer close (admin browser navigating away), sending the
  connection down the `mg_error` hard-close path and logging an error
  ~0.5 s after every connect. The epoll branch now reads `SO_ERROR` via
  `getsockopt()` first (`sdrpp_server` precedent): only real pending
  socket errors hard-close; graceful closes shut down quietly through the
  normal read path. New patch
  `config/websdr/cherry-picks/0148-mongoose-epollerr-graceful-close.patch`;
  background in
  `docs/dev/mongoose-websocket-socket-error-investigation.md` (now
  tracked). Deb `web888-websdr 2026.730-4`.

## [2026-08-11] — websdr: FAX recording info-leak fix (cherry-pick 0147)

### Fixed

- **Cherry-pick 0147: KiwiSDR `f98b3779` (post-v1.902) — remove the FAX
  extension's server-side recording.** Every FAX received by any user was
  written to a fixed, world-downloadable file `/root/samples/fax.chN.pgm`
  that anyone could fetch afterwards, leaking other users' receptions.
  Recording is replaced by a browser-side **Save** button exporting the
  displayed canvas as a timestamped JPEG download (like the other
  extensions). New patch
  `config/websdr/cherry-picks/0147-kiwi-fax-recording-info-leak.patch`
  (registered in the series, manifest, and PROVENANCE); deb
  `web888-websdr 2026.730-3`.

## [2026-08-11] — build-all.sh defaults to the U-Boot chain

### Changed

- **`scripts/build-all.sh` defaults to the U-Boot boot chain.** New
  `CHAIN=uboot|stub` knob (default `uboot` = stock FSBL + full U-Boot as
  SSBL — now the production chain); `CHAIN=stub` keeps the legacy
  stub-SSBL chain buildable as rollback (pairs with `KERNEL=6.6` for the
  full linux-xlnx 6.6 rollback). When `CHAIN=uboot`, the pipeline runs
  `scripts/build-uboot.sh` as step 8g and emits
  `output/web888-debian-uboot.img`; `stub` keeps the previous
  `final` behaviour. The run banner prints the selected chain and kernel.

### Added

- **`scripts/test-qemu.sh` `uboot` mode** — boots
  `output/web888-debian-uboot.img` through the real boot flow: QEMU
  direct-boots the U-Boot ELF (FSBL not emulated), U-Boot finds and runs
  `boot.scr` from the image FAT, which loads zImage+dtb and boots Linux
  from the ext4 rootfs. Gate = login prompt on the serial log. No ssh
  hostfwd in this mode (eth0 still cannot probe under QEMU — phy@1
  mismatch, and no 24c64 for the MAC).
- **`docs/user/building.md`** — user documentation for the build system:
  the two boot chains, every configurable knob of `build-all.sh`
  (`KERNEL`, `CHAIN`, `DEBIAN_MIRROR`) and of the per-step scripts
  (`DEBIAN_SECURITY_MIRROR`, `GOVERNOR`, `KIWI_TREE`), the manual per-chain
  build commands, QEMU gate usage including the known QEMU-vs-hardware
  differences, and the produced artifacts. Linked from the docs/user
  index, README.md, README.zh-CN.md, and docs/user/flashing.md.

### Verified on hardware

- Flashed `output/web888-debian-uboot.img` to SD and booted the board:
  the full chain (stock FSBL → full U-Boot SSBL → boot.scr → 6.12
  kernel) comes up; `eth0` and the kernel fdt `local-mac-address` carry
  the factory MAC (`ce:cf:3f:f6:d5:1b`); the DHCP lease is stable across
  a controlled reboot (same IP); `web888-websdr.service` starts, the
  FPGA bitstream loads (zynqsdr control+data plane), and the OpenWebRX
  UI answers HTTP 200 on `:8073`; zero journal errors on both boots.

## [2026-08-10] — U-Boot plants the factory MAC from the board EEPROM

### Added

- **U-Boot reads the per-unit MAC from the board EEPROM and sets
  `ethaddr` before ethernet probes** (`config/u-boot/0002-board-eeprom-mac.patch`,
  `CONFIG_WEB888_EEPROM_MAC`). The MAC is stored raw at offset 0x10 of the
  24c64 EEPROM on i2c0 (chip 0x50). Previously the GEM fell back to
  `CONFIG_NET_RANDOM_ETHADDR`, U-Boot's `fdt_fixup_ethernet` injected that
  random MAC into the kernel fdt as `local-mac-address`, and the board
  re-IPed on every boot. An `ethaddr` already in the environment (uEnv.txt
  operator override) still wins. Verified on hardware: eth0 and the kernel
  fdt `local-mac-address` are the factory MAC (`ce:cf:3f:*`) across reboots.
- **Register-level EEPROM read in board code, bypassing the cdns i2c
  driver** — the Zynq i2c0 controller is the r1p10 core with the
  BROKEN_HOLD_BIT erratum (compatible `cdns,i2c-r1p10`): the driver's
  multi-message read (offset write + 6-byte read) wedges with the HOLD bit
  stuck and times out with no RXDV, while 1-byte reads complete. The
  board code instead bit-bangs the controller registers directly: a 2-byte
  offset write with STOP (the 24c64 address counter survives STOP), then a
  plain current-address read — no HOLD, no repeated start. Probing the i2c0
  bus device first initializes the controller (clock divisors); bus state
  varies boot-to-boot, so the read retries 5× with 50 ms backoff.
- `config/u-boot/zynq-web888.dts` — `u-boot,i2c-offset-len = <2>` on the
  eeprom node (24c64 needs 2-byte addressing; needed if anything binds the
  i2c_eeprom driver in U-Boot).

## [2026-08-08] — Research: stock FSBL is source-rebuildable (new TODO F1)

### Added

- `docs/dev/TODO.md` — new "Source-built FSBL" work item (F1): replace the
  reused stock FSBL binary with one built from source. Feasibility confirmed
  against the pinned RaspSDR/red-pitaya-notes fork (`work/redpitaya-src`):
  the FSBL is the Xilinx `zynq_fsbl` template generated by HSI
  (`scripts/fsbl.tcl`), the Web-888 PS7 config is the Red Pitaya board
  preset `cfg/red_pitaya.xml` (68 lines; DDR = MT41J256M16 16-bit = 512 MB,
  matching both vendor boot chains' identical FSBL binary), and the Si5351
  122.88 MHz / EEPROM-MAC / `refclock=` hooks are `patches/
  red_pitaya_fsbl_hooks.c` + `patches/fsbl.patch`. The only missing source
  artifact is Vivado-generated `ps7_init.c/h` — a one-time HSI run (XSA
  export only, no bitstream synthesis) sharing the U3 Vivado install, after
  which per-release rebuilds need only `arm-none-eabi-gcc`.

## [2026-08-07] — Hardware gates on the 6.12 chain: smoke, E2E, RP round-trip, reboot-loop

Ran the outstanding hardware gates against the dev unit on the
`6.12.100-web888` kernel (see `docs/dev/TODO.md`).

### Added

- `scripts/hw-test/ws-e2e.py` — host-side websdr websocket E2E probe
  (no dependencies). Handles three fork protocol quirks verified against
  `work/websdr-src`: MSG frames arrive with the *binary* opcode; SND rx
  params are only accepted after `MSG audio_init`; the client must send
  `SET keepalive` every ~5 s and `SET AR OK in=… out=…` to complete
  `CMD_ALL` (`CMD_FREQ|CMD_MODE|CMD_PASSBAND|CMD_AGC|CMD_AR_OK`) or the
  server kicks the connection (`rx_sound.cpp`, `rx_sound_cmd.h`).
  Asserts real audio (`SND`) and waterfall (`W/F`) binary frames.
- `scripts/hw-test/hw-roundtrip.sh` — RP-coexistence gate (P4.5): 10×
  `web888-mode` round-trips websdr↔RF-active RP app with :8073 recovery
  polls, reboot-default check, 1 h soak, final `ws-e2e.py`.
- `scripts/hw-test/hw-reboot-loop.sh` — WebSDR deeper gate: reboot ×3
  verifying websdr self-heals as the `web888` user after every boot,
  then a multi-hour soak with journal error scans and a final E2E.
- `scripts/hw-test/mmap-test.c` — per-region `/dev/mem` mmap probe used
  to rule out STRICT_DEVMEM as the hpsdr SEGV cause.
- `scripts/hw-test/README.md` documents the new tools and warns the
  gates reboot the device (never run two concurrently).

### Fixed

- **hpsdr SEGV on the dev unit — stale deb, not a code bug.** The
  round-trip gate caught `sdr_receiver_hpsdr-server` segfaulting at
  start (fault address 0). Root cause: the unit still ran
  web888-redpitaya **2025.430-1** (unpatched vendor peri.c — sysfs GPIO
  EBUSY → NULL `FILE*` deref); the fix had been built as **2025.430-2**
  the day before but never deployed. Deployed it; hpsdr now starts
  (`attenuator initialize succeed (zynqsdr ioctl)`), UDP :1024
  discovery live, and the full gate passed (`ROUNDTRIP_OK`: 10/10
  iterations, reboot-default correct, 1 h soak clean, final E2E OK).

### Verified (hardware)

- `zynqsdr-smoke hw` → `ZYNQSDR_SMOKE_OK` on 6.12 (15-ioctl ABI,
  signature `0xaa55020c` = 12 RX + 2 WF, DNA, GPIO readback `0x155`).
- `ws-e2e.py` → `E2E_OK`: real audio + waterfall frames; service runs
  as `web888` with XDG paths under `/var/lib/web888`; zero self-update
  attempts in the journal.
- Reboot-loop ×3 + 2 h soak → `REBOOTLOOP_OK`: websdr healthy ~65 s
  after every boot (3/3), 24/24 soak checks clean (zero error-level
  journal lines), final `ws-e2e.py` E2E OK. (Gate logs in `.tmp/` on
  the build host; result recorded in `TODO.md`.)
- Scrubbed the dev unit's LAN IP from tracked files; hw-test gates now
  default to `DEVICE=web888.local`.

## [2026-08-07] — Waterfall engine (BUG 3): known-issue entry retired

Operator-verified the waterfall engine fix is clean at all zooms on the
dev unit, including z7 (the regime that originally exhibited the
16-frame-period comb+stripe artifact — see
[`docs/research/zynqsdr-port-notes.md` §14](../research/zynqsdr-port-notes.md)
for the full root cause and the three-place fix). The §2 entry's
"two cosmetic leftovers" were both non-defects: the regime A→B
transition is moot post-fix, and the stock-firmware A/B capture is a
reference wishlist item rather than an open defect.

### Removed

- `KNOWN-ISSUES.md` former §2 (Waterfall engine — BUG 3) — fully
  resolved and hardware-verified. Per the file's intro policy, resolved
  items are removed from the file; section numbers are stable so
  historical references (e.g. `CHANGELOG.md` 2026-08-06 doc-scrub entry
  referencing §2) may point at removed entries by design.
- The fix itself is preserved as the canonical reference in
  `docs/research/zynqsdr-port-notes.md` §14, and the three code changes
  remain in place: `config/kernel/zynqsdr.c` WF_PARAM reset pulse,
  `config/websdr/patches/0012-wf-engine-decim-rearm.patch`, and the
  `rx_waterfall.cpp` non-shared non-overlapped param+rearm logic.

## [2026-08-06] — README: clarify that this is a software-only project on stock Web-888 hardware

### Changed

- `README.md` and `README.zh-CN.md`: added a prominent callout right
  under the title explicitly stating that this is a 100% software
  project running on the existing, stock Web-888 (Zynq-7010) SDR
  receiver exactly as shipped by the manufacturer — no new hardware is
  involved, only the TF card contents change. Addresses a recurring
  misconception that this project designs or builds new hardware.

## [2026-08-06] — README: add user-facing Highlights section

### Added

- New `## Highlights` section in both `README.md` and `README.zh-CN.md`
  (inserted between the AI-vibe-coding notice and the `## Why` section).
  Six bullets summarise the user-visible value proposition (Debian
  default kernel/firmware → Wi‑Fi dongle support, ext4 TF root partition
  sized by the card, KiwiSDR backports, low-memory/flash tuning
  including zram and log2ram, WebSDR running as a dedicated non‑root
  user under systemd, WebSDR + Red Pitaya coexistence in one image) in
  user-friendly language. Existing `## Why` and `## What works today`
  sections are preserved unchanged — they answer different questions
  (rationale and technical status respectively).

## [2026-08-06] — GPS verified end-to-end; known-issue entry retired

Operator-verified the full GPS chain on the dev unit: satellite fix →
gpsd SKY/TPV → chrony GPS+PPS refclocks → WebSDR-admin GPS page, all
working (see the 2026-08-06 GPS entry below for the root cause and fix).

### Removed

- `KNOWN-ISSUES.md` former §1 (GPS: gpsd switching the ATGM336H to
  UBX-only) — resolved and hardware-verified. The file's intro now states
  the policy: resolved items are removed from the file, and section
  numbers are kept stable so historical references make sense.
- `TODO.md` "GPS recovery" section — all items done and verified.

### Changed

- Stray references to the removed known-issue entry repointed to this
  changelog (`docs/user/troubleshooting.md` §5, `docs/user/usage.md` GPS
  section, `scripts/configure-rootfs.sh` comments).

## [2026-08-06] — mDNS device discovery (avahi on the Debian image)

### Added

- `configure-rootfs.sh`: install `avahi-daemon` + `libnss-mdns` and enable
  `avahi-daemon.service`/`.socket`. The device now advertises itself as
  `web888.local` (hostname-based, IPv4 + IPv6) and resolves other
  `*.local` hosts via `mdns4_minimal` (libnss-mdns' postinst wires it
  into `/etc/nsswitch.conf`; listed explicitly because the build uses
  `--no-install-recommends`). RAM cost is a few MB.
- Hardware-verified on the dev unit: host-side
  `avahi-resolve-host-name web888.local` returns the unit's IPv6 and
  IPv4 addresses, and mDNS resolution survives a reboot.
  `docs/dev/TODO.md` "Networking / discovery" item closed.
- Note: this changes the image build for *future* flashes only — existing
  installs get the same result with
  `apt-get install avahi-daemon libnss-mdns`.

### Changed

- Discovery docs updated everywhere (`AGENTS.md`, `docs/user/flashing.md`
  §3, `usage.md`, `quick-reference.md`, `troubleshooting.md` §1,
  `docs/research/hardware-facts.md` §Discovery): `web888.local` mDNS is
  now the primary discovery path; MAC-prefix scanning (`ce:cf:3f:*`)
  documented as the fallback.

## [2026-08-06] — GPS: fix gpsd poisoning the ATGM336H into UBX-only mode

Root-caused the long-standing "no GPS data anywhere" defect
(`KNOWN-ISSUES.md` §1) on hardware: Debian gpsd 3.25's u-blox driver
rewrites the chip's message config on connect (NMEA off, UBX NAV on), and
the ATGM336H's battery-backed RAM keeps that config across reboots — so
every boot after the first gpsd connect found the chip in UBX-only mode,
with no NMEA and (because gpsd enables no SVINFO substitute on this chip)
no satellite/skyview data for the WebSDR admin page either.

### Fixed

- `configure-rootfs.sh`: `GPSD_OPTIONS` gains `-b` (read-only) so gpsd
  never writes chip config. Verified on hardware: NMEA output now survives
  gpsd restarts. Existing installs need the same one-line edit in
  `/etc/default/gpsd`.

### Added

- `scripts/hw-test/atgm336h-fix.py` — dependency-free on-device tool for
  the ATGM336H: classify the NMEA/UBX port mix (`status`), restore 1 Hz
  NMEA (`enable-nmea`), return to factory pure-NMEA (`disable-ubx`),
  cold-start the GNSS engine (`cold-start`), optional flash save (`save`),
  or the full sequence (`fix`). Used to repair the dev unit's chip.

### Changed

- `KNOWN-ISSUES.md` §1 rewritten: confirmed root cause, deployed fix, and
  the two gpsd quirks that hid all satellite data (no SVINFO substitute;
  the SiRF-hairball check discards GSV with all-zero azimuths, which is
  the chip's state until its first fix). Remaining verification step is
  antenna/sky-view dependent and assigned to the operator (`TODO.md`).
- `docs/user/troubleshooting.md` §5 and `docs/user/usage.md` GPS section
  updated: UBX-only limitation replaced by the fix + the one-line remedy
  for pre-2026-08-06 images; document that the satellite list stays empty
  until the first fix.

## [2026-08-06] — Published to GitHub

The cleaned single-commit `master` is now public at
<https://github.com/SteamedFish/web888-debian>. The pre-cleanup history
stays on the forgejo-only `master-pre-cleanup` archive branch.

## [2026-08-06] — Drop one-off SIGILL observation

### Removed

- The `ls`/`find` SIGILL entry (`docs/research/hardware-facts.md` and
  `docs/user/troubleshooting.md` §9): observed exactly once on an early
  image, never reproduced on any later image — not a real issue.

## [2026-08-06] — De-personalise contributor-facing docs; comment code scrub

Comment/doc-only changes; no runtime or code logic changed.

### Removed

- Personal maintainer workflow rules from `AGENTS.md` that would bind other
  contributors' tooling: the no-worktrees policy, the GPG-signing
  requirement, the merge policy, and the private remote URL.
- Arch-Linux/distrobox host specifics (`AGENTS.md`, `scripts/env-setup.sh`,
  `scripts/hw-test/README.md`) — the toolchain check is host-neutral now.
- Dangling internal milestone codes from code/config/packaging comments
  (`M1`–`M6`, `M4a`, `P0.1`–`P4.5`, `D2`–`D8`) whose plan documents no
  longer exist, and the undocumented `BUG 2` label (`BUG 3` stays — it is
  documented in `docs/research/zynqsdr-port-notes.md` §14 and
  `KNOWN-ISSUES.md` §2). Technical content of the comments unchanged.

### Changed

- `hw-probe.{c,py,armhf}` moved from `scripts/` into `scripts/hw-test/`
  alongside the other on-device diagnostic tools;
  `scripts/capture-hw-state.sh` and the hw-test README updated.
- Device-access ssh note reworded from host-specific to conditional
  ("pass `-p 22` explicitly if the client's ssh config defaults Port…").
- `docs/dev/TODO.md`: added avahi/mDNS device discovery as an open item.

## [2026-08-06] — Post-release stale-content cleanup

Removed stale and misleading references that pointed at abandoned or
retracted work. No runtime or code logic changed (comments and docs only).

### Removed

- References to the abandoned Armbian boot attempt (the armbian image
  never booted on hardware); `AGENTS.md` no longer mentions the
  `~/work/web888-armbian/` read-only repo.
- Documentation and comments describing the retracted SD-CID-derived
  `web888-set-mac` MAC-override rule as if it were current; the EEPROM MAC
  is now described plainly. The self-cleanup `rm -f` that purges stale
  artifacts from a reused `work/rootfs/` is kept unchanged.
- Dangling references to deleted internal plan documents (`plan D1`–`D8`,
  `step2-zynqsdr-driver.md`, `step3-websdr-debian-fixes.md`, the step-4
  plan) across `docs/`, `scripts/`, `config/`, and `packaging/`.
- One dangling internal commit hash (`bb6dc37`) in
  `scripts/install-kernel-deb.sh`.

### Changed

- Resolved-outcome wording where a decision was recorded as still pending:
  `cma.c` not ported (zynqsdr-port-notes), selector UI cut for v1, RP apps
  run as root systemd units (coexistence doc), netfilter acceptance
  checklist completed (debian-kernel-options-research).
- `docs/dev/README.md`: `armbian-optimizations.md` is now described as the
  rationale for the tuning shipped in `configure-rootfs.sh` (it previously
  said "future tuning").

## [2026-08-06] — First public release

The repository was reorganised for public release. No runtime behaviour
changed; this entry records the structural changes only.

### Added

- New user docs: `docs/user/flashing.md` (build/QEMU-gate/flash/first-boot/
  rollback) and `docs/user/usage.md` (services, `web888-mode` switching,
  updates, backup). Section index READMEs for all three doc sections.
- `docs/dev/KNOWN-ISSUES.md` (GPS UBX-only root cause, BUG 3 leftovers,
  watchlist, QEMU limitations).

### Changed

- Documentation reorganised into three sections: `docs/research/`
  (reverse-engineering facts about the stock device), `docs/dev/`
  (development docs: TODO, KNOWN-ISSUES, this changelog, design/SOP
  docs), `docs/user/` (user docs: flashing, usage, quick reference,
  troubleshooting).
- README rewritten as a user-facing introduction (with the "100%
  AI-generated (Kimi K3) vibe coding" notice); AGENTS.md updated
  with the new layout and the mandatory-changelog rule.
- `quick-reference.md` and `troubleshooting.md` adapted to the Debian
  system (stock-firmware procedures quarantined).
- `armbian-optimizations.md` translated to English.
- Debian package maintainer identity unified to
  `SteamedFish <steamedfish@hotmail.com>` across `web888-websdr`,
  `web888-redpitaya`, and the kernel package build
  (`scripts/build-kernel-6.12.sh`).

### Removed

- Agent plan/session directories (`.sisyphus/`, `.zcode/`) and the
  historical process narrative (old TODO/CHANGELOG, completed-plan
  documents, boot-test log) from the public tree — preserved on the
  pre-cleanup archive branch.
- `docs/raw/` primary-source reports; their unique evidence was folded
  into `zynqsdr-port-notes.md` (new Appendix A),
  `stock-kernel-analysis.md`, `security-analysis.md`, and
  `docs/dev/KNOWN-ISSUES.md`.
- Private/environment-specific details from docs and code comments
  (device MAC/IP instances, hardcoded device-IP defaults in deploy/hw-gate
  scripts, host paths, session/date narratives, dangling pre-cleanup
  commit hashes and `.sisyphus` plan references).

For the implemented feature set as of this release, see
[`TODO.md`](TODO.md) § Completed feature set.
