# Changelog — web888-debian

All notable changes to this project are recorded here, newest first.
This log starts at the first public release; earlier history is preserved
on the pre-cleanup archive branch (see AGENTS.md).

Format: `## [version/date] — title`, then grouped bullet entries
(Added / Changed / Fixed / Removed). Every PR, commit series, or
behaviour-affecting change MUST add an entry here (see AGENTS.md —
this is a hard project rule).

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
