# Changelog — web888-debian

All notable changes to this project are recorded here, newest first.
This log starts at the first public release; earlier history is preserved
on the pre-cleanup archive branch (see AGENTS.md).

Format: `## [version/date] — title`, then grouped bullet entries
(Added / Changed / Fixed / Removed). Every PR, commit series, or
behaviour-affecting change MUST add an entry here (see AGENTS.md —
this is a hard project rule).

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
- Hardware-verified on the dev unit (192.168.24.15): host-side
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
