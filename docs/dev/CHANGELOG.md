# Changelog — web888-debian

All notable changes to this project are recorded here, newest first.
This log starts at the first public release; earlier history is preserved
on the pre-cleanup archive branch (see AGENTS.md).

Format: `## [version/date] — title`, then grouped bullet entries
(Added / Changed / Fixed / Removed). Every PR, commit series, or
behaviour-affecting change MUST add an entry here (see AGENTS.md —
this is a hard project rule).

## [2026-08-15] — install scripts now install the NEWEST built deb (were silently picking a stale one)

### Fixed

- **`scripts/install-websdr.sh` / `scripts/install-redpitaya.sh` deb
  selection** — the websdr installer picked `$ls | head -1` (lexical
  order → the OLDEST deb once `output/websdr/` accumulates builds: with
  `2026.730-2,-5,-6,-7,-8` present it selected the Aug 6 `-2` build), and
  the redpitaya installer used `find | head -1` (arbitrary directory
  order). Both now `find … | sort --version-sort | tail --lines=1`. The
  md5 fsys-tarfile guard cannot catch this — it compares the rootfs
  against the *same wrongly-selected deb*. Verified against the real
  output dirs plus a simulated `-2/-5/-8/-10` dir; exercised end-to-end
  by the 2026-08-15 full `build-all.sh` run (steps 8d/8f).

## [2026-08-15] — build-all.sh auto-clones the pinned websdr/redpitaya upstream trees

### Added

- **`scripts/fetch-upstream-src.sh`** — new helper, `fetch-upstream-src.sh
  <websdr|redpitaya>`: reads `config/<name>/upstream.pin` and, when
  `work/<name>-src` is missing, clones the pinned upstream with a shallow
  fetch-by-SHA (GitHub allows fetching any reachable commit; same shallow
  pattern as the bootgen/linux-xlnx clones in `build-all.sh`), checks out
  the pinned commit, then initialises and verifies the pinned websdr
  submodules (`externals/dumphfdl`, `pkgs/jsmn`, `pkgs/utf8`). Idempotent:
  a tree already at the pinned commit is left untouched; a tree at a
  DIFFERENT commit errors out instead of being silently rewritten.

### Fixed

- **`scripts/build-all.sh` from-scratch reproduction gap** — steps 8c/8e
  hard-failed on a fresh checkout with `error: work/websdr-src missing (run
  upstream clone first)`: the orchestrator auto-fetched the kernel and
  bootgen but never the two pinned application source trees, and the manual
  clone step was documented nowhere (the build only ever worked on machines
  where `work/websdr-src` / `work/redpitaya-src` had been cloned by hand).
  `build-all.sh` now runs `fetch-upstream-src.sh websdr|redpitaya` at the
  start of steps 8c and 8e; `docs/user/building.md` documents the helper in
  the manual per-step listing. Verified: fresh clones land exactly on the
  pinned commits (submodule SHAs included), re-runs are a no-op, and the
  pin gates in `build-websdr-deb.sh` / `build-redpitaya.sh` pass.

## [2026-08-15] — Fix build-all.sh abort: comment apostrophe truncated the rootfs chroot script

### Fixed

- **`scripts/configure-rootfs.sh`** — an apostrophe in the admin-console
  comment added with the console-tooling install (`the websdr admin
  page's console tab`, plus a second one in `console's bash`) terminated
  the single-quoted `sh -c '...'` chroot block at line 88 halfway
  through: the chroot ran only the truncated head (through the first apt
  install), while the second install (`htop tmux curl rsync
  bash-completion`, line 121) ran as *outer bash on the Arch build host*
  — where `apt-get` does not exist — aborting `build-all.sh` with
  `configure-rootfs.sh: line 121: apt-get: command not found`. The
  failure was invisible to `bash -n` (the script remained syntactically
  valid bash). Comments reworded without apostrophes and an NB warning
  added; the other seven `sh -c`/`bash -c` blocks in `scripts/` audited
  clean. Verified: the pre-fix script reproduces the exact error under a
  fake-sudo harness while the fixed one executes entirely inside the
  chroot, and a real re-run of `configure-rootfs.sh` now completes (all
  package groups + service enables; htop/tmux/curl/rsync/
  bash-completion/firmware/wifi all `install ok installed`).

## [2026-08-15] — build-all.sh FSBL knob (source-built FSBL by default, end to end)

### Added

- **`scripts/build-all.sh`** — new `FSBL=source|stock` knob (default
  `source`), validated up front and exported to `build-bootbin.sh`. New step
  8h runs `build-fsbl.sh` when `FSBL=source`, with the same stale-artifact
  skip pattern as the deb steps (rebuilds when `output/fsbl/fsbl.bin` is
  missing or any vendored input under `resources/reference/embeddedsw-zynq-fsbl`,
  `resources/reference/redpitaya-fsbl-hooks`, or `scripts/build-fsbl.sh`
  itself is newer). The final `DONE` line now reports `fsbl=$FSBL`.
  Verified: `FSBL=stock build-bootbin.sh uboot` → 953,336 B boot.bin;
  default source path → 969,720 B; invalid values rejected with exit 1.
- **`docs/user/building.md`** — boot-chain table, knobs table, DONE example,
  and the per-step listing updated for the source-built FSBL default and the
  new step 8h.

## [2026-08-15] — Doc sync for final-review minors M1-M3 (FSBL provenance, bootbin header comments, plan as-built notes)

### Changed

- **`resources/README.md`** — stock boot.bin "Why it is required" rewritten:
  the FSBL is now built from source by default (`FSBL=source` — vendored
  embeddedsw @ `xilinx_v2023.1` + RaspSDR hooks); the stock binary is still
  needed as the SSBL-stub extraction source, the ps7_init-array extraction
  source, and the `FSBL=stock` escape hatch.
- **`scripts/build-bootbin.sh`** — stale header comments updated: line 2 now
  says "source-built FSBL (default) or stock FSBL+SSBL"; the `uboot` mode
  line drops the "stock" qualifier (comments only, no code change).
- **`docs/dev/fsbl-source-build-plan.md`** — as-built annotations on the
  historical plan: 21 ps7_init arrays (incl. post_config/debug, vs the
  planned 15) and `patch -p0` (vs `git apply`, no `a/`/`b/` prefixes);
  Task 1-4 + 6 checkboxes marked complete (Task 5 stays unchecked — no
  Vivado).

## [2026-08-15] — Documentation sync for the source-built FSBL (FSBL source build, task 6)

### Changed

- **Docs synced to the `FSBL=source` default** (plan
  `docs/dev/fsbl-source-build-plan.md` now marked IMPLEMENTED 2026-08-15,
  Tasks 1-4+6 done, Task 5 skipped — no Vivado):
  - `docs/research/bootbin-repack-spec.md` — FSBL provenance in the boot
    flow, repack-contract table, and BIF template now point at
    `output/fsbl/fsbl.bin` (source-built default); new paragraph
    documenting the source-FSBL deltas for the EEPROM env @0x1800
    (`refclock=` now consumed).
  - `docs/research/hardware-facts.md` — boot-chain FSBL bullet now
    documents the source-built FSBL (provenance, 21/21 ps7_init array
    byte-match, hardware-verified 2026-08-15) and its deliberate deltas
    (MIO49 HIGH / MIO10 LOW, `refclock=` honored); env bullet notes the
    hooks consume `refclock=`.
  - `docs/dev/KNOWN-ISSUES.md` §5 — QEMU-gate bullet extended: QEMU never
    executes the FSBL (`-device loader` direct-boots U-Boot, DDR
    unmodeled), so the source FSBL is verified by the hardware battery
    only.
  - `docs/dev/TODO.md` — **F1 checked off** (done 2026-08-15 via the
    extraction path); legacy HSI sub-items annotated as
    superseded/optional provenance pass.
  - `docs/user/usage.md` — new section "Reference clock override (EEPROM
    `refclock=`)": user-visible behavior change — the boot-time hooks now
    honor `refclock=` and drive MIO49/MIO10 (fulfills the documentation
    promise in the Task 3 entry below).
  - `README.md` / `README.zh-CN.md` — "stock FSBL" mentions updated to
    the source-built FSBL (both languages kept in sync).

### Fixed

- **`xparameters.h` (web888 FSBL BSP) SCUWDT HIGHADDR typo** —
  `XPAR_PS7_SCUWDT_0_HIGHADDR` was `0xF80070FFU`, now `0xF8F006FF`
  consistent with the zc702 BSP in the same tree (SCUWDT is unused by the
  FSBL build; correctness hygiene only).
- **`embeddedsw-zynq-fsbl/PROVENANCE.md`** — notes that
  `lib/sw_services/xilrsa/src` ships as an upstream PREBUILT
  `librsa.a`/`librsa_armcc.a` plus headers (no C sources), vendored
  as-is and only linked if RSA authentication is enabled (the web888
  build does not enable it).

## [2026-08-15] — Source-built FSBL becomes the default (FSBL source build, tasks 4 step 5 + 6)

### Changed

- **`FSBL=source` is now the default** in `scripts/build-bootbin.sh`:
  every boot.bin built from now on carries the source-built FSBL
  (Xilinx embeddedsw `zynq_fsbl` @ `xilinx_v2023.1` `86f54b77` + RaspSDR
  Red Pitaya hooks @ `da1a7e3a`, ps7_init arrays extracted from the stock
  FSBL binary and byte-verified). `FSBL=stock` stays as the escape hatch.
- **Hardware-verified 2026-08-15** on the live device with an
  `FSBL=source` image (full battery, stock card untouched as rollback):
  booted to Debian; MAC `ce:cf:3f:f6:d5:1b` == EEPROM @0x10; MIO49 driven
  HIGH + MIO10 driven LOW matching the hooks; WebSDR live and streaming
  (proves Si5351 CLK0 122.88 MHz config via the hooks);
  `memtester 350M 1` — all 16 sub-tests passed, zero failures, no OOM;
  dmesg clean (zero error/fail/warn).
- **Deliberate behavior deltas vs the stock FSBL** (documented in
  `docs/research/hardware-facts.md` and `docs/user/usage.md`):
  - MIO49 (CLK_REF) is driven HIGH at boot = internal TCXO select;
    MIO10 (HF_VHF) driven LOW. The stock FSBL predates the hooks' GPIO
    commits and left these lines floating.
  - The EEPROM `refclock=` env is now consumed by the hooks to override
    the Si5351 reference frequency (default 24,576,000 Hz). The stock
    FSBL ignored it.
  - MAC is still read from the EEPROM (0x10) — same end result as stock
    via U-Boot, now also set by the FSBL hooks themselves.

## [2026-08-15] — Opt-in FSBL=source switch for boot.bin packing (FSBL source build, task 4)

### Changed

- `scripts/build-bootbin.sh` — new `FSBL=stock|source` env switch
  (**default stays `stock`** pending hardware verification): selects the
  `[bootloader]` partition between `work/stock/fsbl.bin` and the
  source-built `output/fsbl/fsbl.bin` (error hints at
  `scripts/build-fsbl.sh` when missing), and feeds the matching byte
  length to the boot-header patch (words 0x34/0x40 + header checksum).
  Verified: a default-path rebuild's bootloader region (header + stock
  FSBL) is byte-identical to the previously built stock `boot-uboot.bin`;
  `FSBL=source` builds (both `uboot` and stub modes) pack the source
  FSBL with header words 0x34/0x40 = 131092 and a valid checksum;
  invalid `FSBL` values are rejected with an error.
- `scripts/env-setup.sh` — added `arm-none-eabi-gcc` and
  `arm-none-eabi-objcopy` to the toolchain check (both required by
  `scripts/build-fsbl.sh`); host detection confirmed OK
  (gcc 16.1.0, objcopy 2.47).
- QEMU gate result (task 4, step 2): `scripts/test-qemu.sh uboot` with
  the source-FSBL `boot.bin` injected into the image FAT — **pass**
  (login prompt reached). Caveat: the gate direct-boots U-Boot via
  `-device loader`, skipping BootROM+FSBL, so it structurally cannot vet
  the FSBL; it covers the U-Boot→kernel handoff only. A separate
  no-loader boot-from-SD attempt (BootROM → FSBL in QEMU) produced zero
  serial output within 60 s for BOTH the source and the stock FSBL
  (control) — QEMU does not model the Zynq DDR controller, so FSBL
  execution cannot be validated in QEMU at all. **The hardware flash
  test is the real gate for the source FSBL** (task 4, step 4).

## [2026-08-15] — Source-built FSBL for web888 with RedPitaya hooks (FSBL source build, task 3)

### Added

- `scripts/build-fsbl.sh` — reproducible FSBL build: rsyncs the vendored
  embeddedsw zynq_fsbl tree to `work/fsbl/`, overlays the RedPitaya hooks
  (`red_pitaya_fsbl_hooks.c` into `src/`, `fsbl.patch` applied with
  patch(1)), builds with `make BOARD=web888` against the project-local
  newlib sysroot (`.tmp/newlib/`), and emits `output/fsbl/fsbl.bin`
  (131092 bytes) + `fsbl.elf`, failing if the binary exceeds 192 KiB.
  Idempotent; forces `-j1` (Xilinx makefiles race under parallel make).
- `resources/reference/embeddedsw-zynq-fsbl/lib/sw_apps/zynq_fsbl/misc/web888/`
  — web888 board BSP dir: `xparameters.h` (adapted from zc702 for the
  stock clock/clocking decode: CPU 667 MHz, UART0 stdin/stdout @100 MHz,
  UART1, SDIO0 @100 MHz, ENET0 125 MHz RGMII, I2C0, QSPIPS, XADCPS),
  `ps7_init.c` assembled from the Task 2 extracted data arrays (all 21
  arrays verbatim, DDRIOB 0x800 quirk preserved) + zed skeleton,
  plus `ps7_init.h`, `bspconfig.h`, `inbyte.c`, `outbyte.c`,
  `drivers.txt` (15 drivers). Build verified: all 15
  `ps7_*_init_data_*` symbols in the elf; all 21 arrays byte-identical
  to the stock blob (`.data` section compare, 21/21); RedPitaya hook
  strings present ("GPIO LookupConfig Failed", "User RedPitaya
  Bootloader start", ...), Xilinx FSBL banner absent.
- `resources/reference/redpitaya-fsbl-hooks/` — vendored
  `red_pitaya_fsbl_hooks.c` + `fsbl.patch` from
  RaspSDR/red-pitaya-notes @ da1a7e3a (Si5351 clock init + MAC-from-
  EEPROM hooks replacing the Xilinx banner), with `PROVENANCE.md`.

## [2026-08-15] — ps7_init tables extracted from stock FSBL binary (FSBL source build, task 2)

### Added

- `scripts/extract-ps7-init.py` — extracts, validates, decodes and
  re-emits the `ps7_init_*` register-init tables embedded in the stock
  FSBL (`work/stock/fsbl.bin`). Finds all 21 arrays (5 groups × 3
  silicon versions + post_config/debug; the `ddr` groups are not
  SLCR-anchored and are located via their DDRC start sequence),
  verifies "exactly 15 SLCR-anchored arrays" per the extraction spec,
  and emits (into gitignored `.tmp/ps7-init/`) `ps7_init_data.c` in the
  exact embeddedsw `EMIT_*` macro format, `arrays.bin`, `manifest.h`,
  and a fully decoded `decode.txt` with UG585 register/field names.
  Cross-checks: MIO mux-selects vs `work/redpitaya-src/cfg/red_pitaya.xml`
  (pin assignments/bank voltages/pullups parsed programmatically from the
  xml; all pass; USB0 pullup delta recorded) and RMW-folded DDRC/DDRP/DDRIOB
  diff vs u-boot `zynq-zybo-z7/ps7_init_gpl.c` (56 identical / 34
  differ — 16-bit bus, timing, DDRIOB and Vref differences analysed).
  Host-gcc round-trip harness byte-compares every emitted array against
  the binary: 21/21 byte-identical.
- `docs/research/ps7-init-stock-analysis.md` — full analysis: opcode
  encoding found in the stock binary (deviation from the initially
  assumed triplet format), array inventory with offsets, clock
  configuration (CPU 667 MHz, DDR3 533 MHz, 16-bit bus), MIO/DDRC
  cross-check results, MT41J-vs-MT41K voltage evidence (recorded, not
  decided), round-trip method and result, and Task 3 usage notes.

## [2026-08-15] — Vendored Xilinx embeddedsw zynq_fsbl subset (FSBL source build, task 1)

### Added

- `resources/reference/embeddedsw-zynq-fsbl/` — trimmed vendored copy of
  Xilinx `embeddedsw` @ tag `xilinx_v2023.1` (commit
  `86f54b77641f325042a1101fead96b2714e6d3ef`, MIT license): the
  `lib/sw_apps/zynq_fsbl` application, `lib/bsp/standalone/src`,
  `lib/sw_services/{xilffs,xilrsa}/src`, and the 15
  `XilinxProcessorIPLib` PS drivers the zynq_fsbl BSP build pulls in.
  First step toward replacing the stock binary FSBL inside
  `resources/stock/web888-boot.bin` with a source-built one. Upstream,
  license, trimmed-path list, and build-environment caveats (Arch
  split-package newlib injection via `CPATH` + `--sysroot` LINKER
  override, serial-make requirement) are documented in the tree's
  `PROVENANCE.md`.
- Smoke test (`BOARD=zc702`, host `arm-none-eabi-gcc` 16.1.0):
  `fsbl.elf` builds with zero source changes and no warning demotions —
  text 94,961 / data 12,540 / bss 76,604 bytes (total 184,105, under the
  200 KB sanity bound); tree diff vs upstream sparse checkout stays empty
  after `make clean`.

## [2026-08-15] — Research doc restructured: APT repo first, image build as its consumer

### Changed

- `docs/dev/github-ci-apt-repo-research.md`: swapped Part 1/Part 2 — the
  GitHub-hosted APT repository is now presented as the foundation (Part 1),
  and the GitHub Actions image build as its consumer (Part 2). Once kernel /
  websdr / redpitaya / third-party debs are in our own repo, the image build
  degenerates to debootstrap + `apt install` + assembly (new §2.7).
- Added §2.8 (U-Boot/boot.bin as a deb): feasible and simpler than on most
  boards — in the `uboot` chain `boot.bin` is only FSBL+U-Boot and the FAT
  partition is mounted at `/boot` in the live system
  (`configure-rootfs.sh` fstab), so a deb install is a plain file copy
  (Raspberry Pi `raspberrypi-bootloader` model). Caveats recorded: brick
  risk (QEMU gate must precede deb publishing), stock-FSBL redistribution
  (same review as the FPGA stack), stub chain excluded (kernel embedded in
  boot.bin). Fallback: keep U-Boot build inside the image job.
- Job topology (§2.4) updated: `debs` job publishes, `image` job consumes,
  `apt-repo` job updates the repo from release assets (NoPorts pattern).
- Open decisions list gained the web888-boot deb question; redistribution
  review now explicitly covers the stock FSBL inside `boot.bin`.

## [2026-08-15] — dumphfdl existing-repo check (research supplement)

### Added

- `docs/dev/github-ci-apt-repo-research.md` §2.7: verified that no
  existing Debian/Ubuntu APT source (official archive, PPA, deb-get)
  ships `dumphfdl` or `libacars >= 2.1.0` — Repology shows only
  AUR/Nix/openSUSE-RPM channels — so we must build and publish both
  ourselves (openSUSE `hardware:sdr` is RPM-only, no armhf deb).

## [2026-08-15] — third-party debs in the GitHub-hosted APT repo (research supplement)

### Added
- `docs/dev/github-ci-apt-repo-research.md`: new §2.7 covering self-built
  third-party debs (e.g. dumphfdl) in the same APT repo — feasible,
  built in our trixie armhf chroot so `Depends:` matches the shipped
  libraries (fixes the stale stock-source builds), with upstream pinning,
  versioning, and licensing notes; added a corresponding open decision
  (package inventory + pinning policy).

## [2026-08-15] — GitHub CI + APT repository feasibility research

### Added
- `docs/dev/github-ci-apt-repo-research.md` — research-only document
  (no implementation) answering two questions with official docs,
  changelog entries, and production reference repos:
  - **GitHub Actions image build + tag-triggered releases: feasible.**
    Everything in `build-all.sh` runs on `ubuntu-24.04` hosted runners
    (4 CPU/16 GB/14 GB SSD, public repos free): cross toolchain via apt,
    armhf debootstrap under qemu-user-static/binfmt (proven by
    Eugeny/tabby), losetup image assembly (proven by DietPi, systemd,
    RROrg/rr). Cold build ≈ 2–4 h fits the 6 h job cap with ccache +
    rootfs caching and a 4–5 job split. Images must ship xz-compressed
    (release assets strictly < 2 GiB). Main risk flagged: redistribution
    of the closed FPGA/bitstream stack in public release artifacts needs
    review before enabling public releases.
  - **Fully GitHub-hosted APT repository: feasible.** Recommended design:
    flat repo on the `gh-pages` branch (`dpkg-scanpackages --multiversion`
    + `apt-ftparchive release` + GPG InRelease, deployed via
    peaceiris/actions-gh-pages) — recipe proven by davidboulay/Clippy and
    K0IN/apt-github-pages. Pool-layout alternative via reprepro/aptly
    (production: atsign-foundation/noports-apt). Releases-hosted flat repo
    documented as fallback (production: mieweb/opensource-server,
    NeverWrite, OpenList). Pages limits (1 GB site, 100 GB/mo soft
    bandwidth) do not bite at our package scale. The three actions cited
    in older blog posts (burneracct/deb-action, sarusso/tinydeb,
    drom92/debian-repo) are all deleted — tooling list updated to
    currently maintained options.
  - Open decisions recorded: FPGA-stack redistribution review, dedicated
    ed25519 signing key custody, tag naming/push propagation, apt layout
    choice, CI Debian mirror, QEMU gate placement.

## [2026-08-15] — web888-websdr 2026.730-8 (0020/0021: admin console freeze + garbled echo)

### Fixed
- **Admin console tab froze the browser tab and echoed garbled text**
  (user report 2026-08-14, after the bash fix in 7746e36 made the console
  actually usable): one shared root cause on the wire — mongoose
  `mg_url_encode()` does not percent-encode `%` itself, so any console
  output containing `%` (notably ping's `0% packet loss`, or typing
  `echo 100%`) reached the client with a raw `%`. Client-side
  `decodeURIComponent` then failed; `kiwi_decodeURIComponent()`'s recovery
  loop only set its `double_fail` bail-out when it actually removed a
  `%xx` sequence, so a bare `%` made the `while (obj == null)` loop spin
  forever — 100% CPU, frozen tab. `kiwi_output_msg()`'s catch-fallback
  displayed the raw percent-encoded string, which was the visible garble.
  Reproduced by replaying captured `console_c2w` payloads against the
  stock parser: the first `0%%20` message froze the tab instantly; a
  no-op `kiwi_output_msg` survived everything.
- `config/websdr/patches/0020-encode-percent-in-kiwi-str-encode.patch`:
  expand every raw `%` to `%25` after `mg_url_encode()` in
  `kiwi_str_encode()` (`support/str.cpp`).
- `config/websdr/patches/0021-decodeURIComponent-infinite-loop.patch`:
  track a `removed` flag in `kiwi_decodeURIComponent()`
  (`web/kiwi/kiwi_util.js`) and force `double_fail` when the cleanup pass
  removed nothing — malformed encodings can no longer spin the loop even
  if some other producer leaks a bad payload.
- `config/websdr/patches/0022-console-no-double-decode.patch`
  (`web/kiwi/admin.js`): console output is decoded **twice** on the
  client — `console_c2w` text passes through `kiwi_output_chars()` (decode
  #1) and then `kiwi_output_msg()` (decode #2), so any shell output
  containing `%` (df `43%`, ping `0%`) failed decode #2 even after the
  server-side `%25` fix. Set `no_decode: true` on `admin.console` (the
  same pattern FT8/digi_modes already use) so `kiwi_output_msg()` renders
  the already-decoded text as-is.
- Caveat discovered during rollout: the first revision of 0020 expanded
  *every* `%`, including the `%XX` sequences `mg_url_encode()` emits for
  bytes ≥ 0x80 — double-encoding them and overflowing the `slen*3+1`
  buffer, which crashed `websdr.bin` in a `free(): corrupted unsorted
  chunks` restart loop on device. The shipped 0020 only expands a bare
  `%` (not followed by two hex digits).
- Verified on hardware (chrome-devtools MCP): Connect → prompt, `ls` /
  `pwd` / `df -H` render cleanly including `Use%`/`43%` columns, no
  console freeze, no server crash.
  Deployed as `web888-websdr_2026.730-8_armhf.deb` (same build also
  carries 0151+0152).

## [2026-08-14] — web888-websdr 2026.730-8 (0152: /admin extensions lost on queue overflow)


### Fixed
- **/admin Extensions tab showed only Antenna Switch** (regression
  introduced by 0151 in 2026.730-7, first observed 2026-08-14): routing
  all `send_msg*()` sends through the s2c nbuf queue gave control
  messages the stream-data backpressure policy — `nbuf_allocq()` drops
  silently past `ND_HIWAT=64` and latches `ovfl` until the queue drains
  below `ND_LOWAT=32`. The /admin startup burst (~200 queue entries:
  cfg frames + ~170 `log_msg` + 25 `ext_call` config calls) overflowed
  it and the `ext_call` extension-config batch was silently dropped, so
  only `ant_switch` (Web-888's own extension, which registers its admin
  config independently of the burst) rendered. Nondeterministic per
  page load depending on poll-thread drain rate.
- `config/websdr/cherry-picks/0152-websocket-control-msgs-no-drop.patch`:
  adds `nbuf_allocq_critical()` to `net/nbuf.{h,cpp}` — bypasses the
  `ovfl` latch, drops only past a pathological 1024-entry cap and logs
  loudly (`nbuf: CRIT HIWAT ... exceeded`) — used by
  `send_msg_buf()`/`send_msg_mc()` in `support/misc.cpp`. Audio/WF
  stream data keeps the original drop-under-backpressure behaviour.
- Verified on hardware: 7/7 /admin reloads render all extension config
  navs (was intermittent before), RX main page waterfall/audio
  streaming unaffected.

## [2026-08-14] — FSBL source-build plan (F1 research complete)

### Added
- `docs/dev/fsbl-source-build-plan.md` — full implementation plan for TODO
  F1 (build the FSBL from source instead of reusing the stock binary),
  compiled from three research passes (local repo/binary analysis, embeddedsw
  toolchain, ps7_init acquisition paths). Key outcomes that refine the
  original F1 assumptions:
  - No Vitis/xsct needed at all: vendor the embeddedsw `xilinx_v2023.1`
    subset (MIT) and use the official from-git build
    (`make BOARD=web888 CC=arm-none-eabi-gcc`); host gcc 16.1.0 is usable.
  - ps7_init acquisition: primary path is signature-based extraction of the
    15 data arrays from `work/stock/fsbl.bin` (hardware-proven ground truth,
    zero approvals); the one-time Vivado 2023.1 pre-synthesis XSA export is
    demoted to an optional provenance pass that must match the extraction.
  - Deliberate behavior delta identified: the stock FSBL predates the hooks'
    GPIO commits, so a source-built FSBL will newly drive MIO49/MIO10 and
    honor the EEPROM `refclock=` override — to be documented when it lands.

## [2026-08-14] — fix /admin websocket frame corruption (0151)

### Fixed
- **0151-kiwi-send-msg-via-s2c-nbuf-queue.patch** fixes the probabilistic
  `/admin` websocket disconnects root-caused on 2026-08-13: the three
  `mg_ws_send()` leaves in `support/misc.cpp` (`send_msg_buf()`,
  `send_msg_mc()`, `snd_send_msg_encoded()`) now enqueue onto the
  connection's s2c nbuf queue instead of touching `c->send` directly, so
  only the web_server task's MG_EV_POLL flush writes/consume the mongoose
  send buffer. This restores the cross-thread serialization that 0144 lost
  together with mongoose's `mongoose_lock`, without patching the vendored
  mongoose 7.14 amalgam.
- Built as `web888-websdr 2026.730-7` and deployed to hardware. Verified:
  `scripts/test-websocket-frames.py` 4 × 60 s runs with zero frame
  violations (pre-fix: 2 of 6 runs corrupted within seconds), two
  concurrent `/admin` browser tabs through a several-minute soak incl.
  Log/Console tab clicks with zero websocket console errors, and zero
  `mg_error` lines in the server journal.
- Docs: KNOWN-ISSUES §6 marked FIXED; investigation doc
  `mongoose-websocket-frame-corruption-investigation.md` updated with the
  fix and verification results; TODO item closed.

## [2026-08-13] — root cause identified: /admin websocket frame corruption

Investigation only — no code fix yet. The probabilistic `/admin` websocket
disconnects (page dies right after open or on button clicks, all browsers)
are caused by cherry-pick 0144 deleting mongoose's global `mongoose_lock`:
`send_msg*()` from non-webserver threads now races the web task's poll
flush and emits malformed frames; the browser kills the connection
(protocol error), producing the server-side `socket error 2` +
`ADMIN connection closed` symptom.

### Added

- **`docs/dev/mongoose-websocket-frame-corruption-investigation.md`** —
  full root-cause writeup (wire evidence, code-level race analysis,
  deployment timeline, fix directions).
- **`scripts/test-websocket-frames.py`** — concurrent-connection frame
  validator / corruption reproducer (exit 1 on malformed frames).
- **KNOWN-ISSUES §6** — the defect; **TODO** fix item under KiwiSDR
  upstream alignment.

### Changed

- **`docs/dev/mongoose-websocket-socket-error-investigation.md`** (0148
  investigation) — status amended: the `socket error 2` drop is a
  downstream symptom of the frame corruption, not an independent issue;
  0148 remains a close/logging fix only.
- **KNOWN-ISSUES §4 watchlist** — 0148 bullet reworded accordingly.

## [2026-08-13] — fix web admin console tab on Debian

The admin page Console tab (browser terminal) was completely broken on
Debian, and several of its shortcut buttons relied on stock-firmware or
missing tooling.

### Fixed

- **Console tab: `/bin/sh: 0: Illegal option --` on connect** —
  `ui/admin.cpp` spawned the console shell as `/bin/sh --login`; on Debian
  `/bin/sh` is dash, which rejects the GNU-style long option and exits
  immediately. New Debian patch
  `config/websdr/patches/0018-admin-console-bash.patch` changes the spawn
  to `/bin/bash --login` (bash is in the base system), appended to
  `config/websdr/debian-patches-series`.
- **"enable hotspot" console button pointed at stock-only
  `/root/wifi/hotspot.sh`** — new patch
  `config/websdr/patches/0019-admin-console-buttons-debian.patch` guards
  the command with `test -x` and prints "hotspot.sh not present on
  Debian" instead of a shell "not found" error. The hotspot feature
  itself remains stock-only; Debian WiFi uses standard tooling.
- **Console button commands missing in the image** — `htop`, `tmux`,
  `curl`, `rsync` and `bash-completion` added to the rootfs package set
  in `scripts/configure-rootfs.sh` so the console tab's `htop`/`tmux`
  buttons (and general console use) work out of the box.
- User docs: new "Admin console tab" subsection in
  `docs/user/usage.md` (features, tmux 80×24 window-size note, hotspot
  button behaviour on Debian).

## [2026-08-12] — project review follow-up: doc/data/packaging/script fixes

Defects surfaced by the 2026-08-12 whole-project review. Each is a
one-spot factual/consistency fix with no behaviour change.

### Fixed

- **F16: `debian-kernel-options-research.md` status updated to reflect the
  implemented decision** — the doc still read "Status: research only — no
  execution" and its pre-execution checklist was left unchecked, but Option 2
  (own kernel .deb on Debian's 6.12 source + Debian config) is the default
  kernel build chain (`scripts/build-kernel-6.12.sh`,
  `config/kernel-web888-6.12.fragment`, TODO step 6). Status now says
  "decision implemented"; the checklist is checked off with pointers to the
  real artifacts; the §7 "Now: Option 3" recommendation is noted as
  superseded (Option 2 was taken directly).

- **F15: Chinese option labels translated in `debian-kernel-options-research.md`** —
  the doc mixed untranslated `方案一/二/三` (Option 1/2/3) into an otherwise
  English corpus, and those labels are referenced throughout §6–§8. All
  occurrences (including a stray standalone `三` in `Option 2/三`) now read
  `Option 1/2/3`; the file is fully English.

- **F10: `quick-reference.md` LED section reconciled with hardware-facts.md** —
  the table claimed D0 "OFF = System not booted" and D2 "flashes with web
  activity", both misleading on the Debian image (D0 is OFF normally until
  a bitstream is loaded; D2 is a boot/heartbeat indicator, not a web
  indicator). Reworded to match the authoritative `hardware-facts.md`:
  D2 lights briefly then off within ~1 s once the kernel boots (stays on =
  early-boot stall); D0 steady ON only after a bitstream loads (off is
  normal early / on non-stock OS); added D3 and the `prog_done` sysfs check
  as the authoritative FPGA-load indicator.

- **F9: broken source path fixed in mongoose investigation doc** —
  `docs/dev/mongoose-websocket-socket-error-investigation.md` cited the
  SO_ERROR precedent as `pkgs/sdrp_server/sdrp_server.cpp`; the real path
  (and the spelling used in the cherry-picks manifest) is
  `pkgs/sdrpp_server/sdrpp_server.cpp` (double p). Both occurrences
  corrected.

- **F8: retracted "D8 LED" claim removed from `zynqsdr-port-notes.md`** —
  the note said "D8 (FPGA-loaded LED) stays off until userspace loads a
  bitstream", but `docs/research/hardware-facts.md` explicitly retracts
  this ("There is NO 'D8' — earlier session notes referencing D8 were a
  naming error"). Reworded to state `prog_done=0` until userspace loads a
  bitstream, with no LED reference.

- **F7: GPIO bank corrected EMIO→MIO in two Red Pitaya dev docs** —
  `docs/dev/redpitaya-upstream-delta.md` and
  `docs/dev/redpitaya-websdr-coexistence.md` described the PE4312 DSA
  bit-bang pins as "EMIO 11/13/12 (sysfs 523/525/524, base 512)", but
  base 512 + 11/13/12 are **MIO** pins (per the authoritative
  `docs/research/hardware-facts.md`); EMIO 11/13/12 would be sysfs
  577/578/579. Now reads MIO, matching both hardware-facts.md and the
  coexistence doc's own §6 resolution.

- **F14: `pipefail` added to two bash verify/test scripts** —
  `scripts/qemu-verify-step4.sh` and `scripts/test-redpitaya-mode.sh` used
  bare `set -u`; upgraded to `set -uo pipefail` so a failing command inside
  one of their piped checks can no longer be swallowed. The third script
  flagged in the review, `scripts/capture-hw-state.sh`, is `#!/bin/sh`
  (dash, no `pipefail` support) and has no local pipelines — its only pipes
  are inside the remote SSH command strings — so it is intentionally left
  unchanged.

- **F12: `License:` field added to both Debian source control files** —
  `packaging/web888-websdr/debian/control` and
  `packaging/web888-redpitaya/debian/control` declared
  `Standards-Version: 4.6.2` but carried no `License:` field. Added
  `License: GPL-2.0+` (websdr, matching the project declaration) and
  `License: MIT` (redpitaya, its documented upstream license).

- **F11: `web888-redpitaya` changelog StartLimit values corrected** — the
  changelog entry still read `StartLimitIntervalSec=60 StartLimitBurst=5`
  while the shipped `web888-rpapp@.service` carries the later-tuned
  `120`/`10` (the unit's own comment documents the 10/120 reasoning).
  Changelog now matches the unit.

- **F5: `cherry-picks.manifest` 0114 slot reconciled with the on-disk patch** —
  the slot was still `pending 0114-kiwi-kiwi-nonemptystr.patch` while the
  quilt series actually applies `0114-kiwi-str-helpers.patch`, which
  consolidates the three Batch-B str-helper ports (0114
  `kiwi_nonEmptyStr`/`kiwi_nonEmptyStrRemNL`, 0115 `kiwi_str_ASCII_static`
  len param, 0116 `kiwi_fmt_usec`). 0114 is now `applied` with all three
  Kiwi commits; 0115/0116 marked merged-into-0114. The manifest now matches
  the series and the on-disk file count.

## [2026-08-12] — websdr: antenna-switch SNR re-measure (patch 0150)

### Added

- **0150: SNR re-measurement on antenna change** — restores the
  ant_switch↔rx_snr coupling 0149 had dropped (on the wrong assumption
  that the fork had no ant_switch support). A server-side hook in
  `ant_switch_setantenna()`/`ant_switch_toggleantenna()` immediately
  re-wakes the SNR measurement task after an antenna change when the
  admin checkbox "Measure on antenna change" (`snr_meas_ant_sw`) is
  enabled — adapted from upstream's client-side `SET antsw_snr` (5 s
  delayed wake; the fork's scheduler has no delayed re-wake primitive).
  Deb 2026.730-6.

### Rejected

- **Upstream SNR-gated default antenna selection** — evaluated and not
  ported: requires re-platforming upstream's pluggable ant_switch backend
  framework for a public-multi-antenna-site feature (idle default antenna
  / ground-when-idle). Rationale recorded in
  `config/websdr/cherry-picks/PROVENANCE.md` (0150 section).

## [2026-08-12] — websdr: 0147 patch refresh (dpkg-source fuzz-0 build fix)

### Fixed

- **0147 FaxDecoder.cpp section regenerated with exact context** — the
  original hand-applied hunk #2 only applied with fuzz 2, which plain
  `patch --dry-run` tolerates but `dpkg-source` (`patch -F 0`) rejects,
  breaking the deb build at the 0147 step. The section was regenerated
  from a reconstructed post-0146 series tree; 0147/0148/0149 all verified
  with `patch -p1 --dry-run -F 0` on their respective bases.

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
