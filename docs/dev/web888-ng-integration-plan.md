# web888-ng evaluation and optional web888d integration plan

> Status: **Phase 1 complete, including hardware validation** (2026-10-31).
> Phase 2 is not authorised or started. Phase 1 produced useful driver and
> test improvements even if Phase 2 never ships. Implementation commits are
> local test milestones, not releases; no GitHub push has occurred.

## 1. Purpose and strategy

Use [jeskko/web888-ng](https://github.com/jeskko/web888-ng) and its companion
repositories in two deliberately separated stages:

1. **Improve web888-debian itself.** Use web888-ng as an independent source of
   `zynqsdr` ABI evidence, a second userspace test workload, and a possible
   QEMU FPGA model. Fix our driver and strengthen repeatable testing before
   making web888d a product feature.
2. **Optionally integrate web888d.** Only after the Phase 1 gate passes, package
   web888d as an experimental, default-off third runtime mode alongside WebSDR
   and Red Pitaya applications.

This order separates driver-compatibility risk from packaging and product
risk. It also ensures that the first stage has standalone value: ABI tests,
QEMU coverage, and driver fixes remain useful if web888d is ultimately not
shipped.

## 2. External inputs and current local facts

External references (pin an exact version before any implementation):

- `jeskko/web888-ng`: Rust `web888d`, web UI, DSP, HPSDR and skimmers.
- `jeskko/web888-ng-hw`: open FPGA/driver, stock-driver interface notes and
  the QEMU virtual Web-888.
- `jeskko/web888-ng-os`: Yocto image and RAUC A/B updates (research only here).
- `web888-ng-hw/docs/stock-driver.md`: independent stock ioctl/PL interface
  evidence.
- `web888-ng/doc/design.md` and `doc/m6-channelizer.md`: architecture,
  implemented milestones and resource measurements. The README's broad
  protocol summary is not proof that every listed protocol is complete.

Relevant local facts:

- Our `config/kernel/zynqsdr.c` implements the 15-ioctl stock-compatible ABI
  and permits only one opener (`zynqsdr_open`).
- `web888-mode` currently switches WebSDR and Red Pitaya applications;
  systemd `Conflicts=` supplies a second exclusivity guard.
- WebSDR and web888d both use TCP 8073 by default. web888d and the RP HPSDR
  application both use UDP 1024. The PL and `/dev/zynqsdr` also require
  exclusive ownership, so concurrent servers are out of scope.
- Our stock bitstreams live under `/usr/share/web888/firmware/`, which must be
  configured explicitly for web888d.
- Writing `/dev/xdevcfg` in the current QEMU hangs the guest. A model showing
  an already-configured PL is not equivalent to emulating devcfg configuration;
  these capabilities must be evaluated separately.
- Real FPGA timing, Si5351/ADC behaviour and PL-bus safety remain hardware
  test subjects even if a QEMU model passes.

## 3. Scope boundaries

### Phase 1 includes

- An independent stock-ABI compatibility matrix.
- Repeatable `zynqsdr` conformance tests.
- web888d used as a pinned behavioural reference, with project-owned runtime
  tests and no external server binary required by the Phase 1 gate.
- A time-bounded feasibility evaluation of `web888-ng-hw/emu/`, followed by
  full reuse or a narrowly scoped model adaptation if justified.
- Driver fixes with regression tests and hardware evidence.
- Clear documentation of what simulation cannot establish.

### Phase 2 includes

- A source-built, optional `web888-web888d` deb, default disabled.
- HF only, using our `zynqsdr`, `/dev/xdevcfg`, and the stock HF bitstream.
- Web UI/audio/waterfall and HPSDR verification.
- Three-way WebSDR/RP/web888d switching through `web888-mode` and systemd.
- Experimental documentation and a reliable return to WebSDR.

### Explicit non-goals for both phases

- No change to the default WebSDR server.
- No simultaneous SDR servers or concurrent `/dev/zynqsdr` owners.
- No web888-ng-os migration.
- No open FPGA, open driver, channelizer, 32-receiver or VHF commitment.
- No claim of Kiwi-protocol, rtl_tcp or full stock-feature parity.
- No default skimmers, spot uploads, accounts or admin password.
- No large web888d fork and no copying GPL-3.0-or-later code into the
  GPL-2.0-only reference area.
- No public GitHub push on the agent's own initiative.

## 4. Phase 1 — validate and improve our own stack

### 1A. Independently validate the `zynqsdr` ABI

Build a compatibility matrix with these columns:

| Interface/behaviour | Stock evidence | Our behaviour | web888d assumption | Verdict/test |
|---|---|---|---|---|

Cover at least:

- all 15 ioctl numbers, argument layouts, return values and error codes;
- single-open semantics and concurrent open attempts;
- RX/WF ring layout, frame widths, write-pointer wrap and overrun behaviour;
- read blocking, interruption, close and `-EINTR` behaviour;
- repeated and out-of-order RX/WF start, parameter, read and stop sequences;
- NCO words, sample rates, signatures and channel counts;
- PPS, GPIO, AD8370 and DNA-related interfaces where applicable;
- process crash/close followed by reopen;
- repeated open/read/close cycles and state residue.

Method:

1. Pin the upstream documentation/tools/web888d commit and record hashes.
2. Compare stock notes with `config/kernel/zynqsdr.c`; do not treat either a
   single userspace binary or our current driver as the sole ABI oracle.
3. Extend the existing `zynqsdr-smoke` path into automatically checkable
   conformance cases rather than creating an unrelated test framework.
4. Use the pinned web888d stock-backend call sequences as behavioural evidence,
   then implement the corresponding driver assertions in our own tools. The
   current gate has no web888d binary, UI, `/ws` client, Rust or Node
   dependency. `scripts/hw-test/zynqsdr-datapath.c` covers real I/Q framing,
   ring-wrap continuity, short/consumer-sized reads, armed retuning, WF mode
   polarity, changed decimation and simultaneous RX/WF streaming under the
   deterministic model. Earlier optional web888d model/hardware interoperability
   runs passed, but are historical evidence rather than a current test
   prerequisite.
5. Record observable inputs and outputs: ioctl results, byte counts, sample
   layout, signals/errors and reopen behaviour.

Fix policy:

- Fix genuine divergences in our driver and add a regression that fails on the
  old code.
- Do not blindly reproduce stock bugs. Determine whether web888d actually
  depends on the behaviour before choosing bug-for-bug compatibility.
- Keep any web888d compatibility patch small and suitable for upstreaming.
- Do not reintroduce the intentionally omitted stock MAC/DNA licence check.

Deliverables:

- Completed ABI matrix with explicit unknowns.
- Repeatable conformance tests.
- Driver fixes and regression evidence.
- A driver data-path report covering real samples and RX/WF sequences, with
  model/hardware boundaries recorded in `zynqsdr-abi-validation.md`.

### 1B. Evaluate and adapt the QEMU FPGA model

Start with a bounded feasibility investigation; do not make Phase 2 wait
indefinitely on a large emulator port.

Questions to answer:

1. Can the `web888-ng-hw` QEMU machine/PL model boot our kernel and rootfs?
2. Does it match our device-tree PL windows, signature and channel model?
3. Which ioctls, DMA rings, PPS and error paths does it really implement?
4. Can it execute our driver and userspace conformance tests deterministically?
5. Does it emulate devcfg writes, or must tests start with an already-loaded
   PL model? Document the distinction and keep the current prohibition on real
   xdevcfg writes unless evidence removes it.
6. What are the CI build/run costs and maintenance boundaries?

Preferred adaptation order:

1. Reuse the complete upstream model as a pinned external test dependency and
   adapt our existing QEMU harness.
2. If boot/machine coupling makes that disproportionate, port only the
   CFG/STS, DMA and PPS subset needed for driver conformance.
3. If the useful coverage is too small for the maintenance cost, stop this
   track, retain hardware gates and record the decision. ABI success may still
   allow Phase 2 to proceed.

If upstream test code is vendored rather than consumed externally, keep it in
an isolated location with exact provenance and its GPL-3.0-or-later licence.

The preferred test entry points (names may follow repository conventions) are:

- `scripts/test-zynqsdr-qemu.sh` for model-driven driver/system tests;
- extensions under `scripts/hw-test/` for the shared conformance corpus.

Target model-driven checks:

- driver probe, device creation and identification;
- single/multi-channel RX and supported WF modes;
- ring wrap, overflow, stop/reset and reopen;
- PPS and GPIO paths supported by the model;
- deterministic IQ/signal assertions using the project-owned datapath tool.

Implemented model harness (local milestone, 2026-10-31):

- `resources/qemu-web888/` vendors the complete machine/PL model and bare-metal
  test from web888-ng-hw v0.3.0 (commit
  `767030740a2fdecfebdd383efd23330e6455ff1b`) without source modifications;
  see its `PROVENANCE.md` for the tarball hash and licences.
- `scripts/build-qemu-web888.sh` builds only `arm-softmmu` from pinned QEMU
  11.1.2 into `work/qemu-web888/`; it never replaces the system QEMU.
- `scripts/test-zynqsdr-qemu.sh --baremetal-only` passes all 12 model checks,
  including signature, CFG, deterministic RX/WF DMA and PPS. The full system
  mode boots our own Debian image and is a separate gate; a bare-metal pass is
  not evidence that our kernel driver works.

Simulation remains incapable of proving analogue clock state, real ADC quality,
Vivado timing, physical AXI safety or hardware load behaviour.

### 1C. Fix and regress our implementation

For every driver change:

1. Add or identify a test that reproduces the defect.
2. Make the smallest driver/kernel/DT correction supported by the evidence.
3. Run host and available QEMU conformance tests.
4. Run `scripts/test-qemu.sh uboot` and the required package/image gates.
5. Re-run `zynqsdr-smoke hw`, stock WebSDR audio/waterfall and relevant RP
   switching tests on hardware before treating the fix as verified.
6. Update `docs/research/hardware-facts.md` only with live-verified facts;
   record unresolved limitations in `KNOWN-ISSUES.md`.

Test layers and owners:

| Claim | Minimum evidence | Verification owner |
|---|---|---|
| ABI behaviour matches the chosen contract | Host/model conformance plus discrepancy matrix | Driver implementer |
| Simulation is deterministic and diagnostically useful | Repeated QEMU runs with ioctl/ring/sample diffs on failure | Test implementer |
| Existing stacks did not regress | Stock WebSDR E2E and relevant RP round trips | Integrator |
| Real hardware behaviour is safe and correct | `zynqsdr-smoke hw`, real streams and reboot/reopen checks | Operator/hardware verifier |

### Phase 1 gate

Proceed to product integration only when:

- the ABI matrix is complete enough that every critical difference has a
  decision and test;
- agreed conformance cases pass, including reopen/reset paths;
- the project-owned datapath tool has exercised real RX/WF samples, ring wrap,
  WF mode changes and concurrent streams under the model;
- driver fixes have regression coverage and no stock WebSDR/RP regression;
- hardware smoke passes;
- the QEMU track either provides stable promised coverage or has a documented
  stop/defer decision;
- remaining uncertainties are explicit inputs to Phase 2 tests.

## 5. Phase 2 — optional web888d product integration

### 2A. Reproducible source build and optional debs

Artifacts:

- `packaging/web888-web888d/` and `packaging/web888-ng-bitstream/`;
- `config/web888-ng/versions.env` for the paired upstream pins and hashes;
- `scripts/build-web888d.sh`, `scripts/build-web888d-deb.sh` and
  `scripts/build-web888-ng-bitstream-deb.sh`;
- independent upstream-watch/build/APT workflows that never emit the image
  build's `debs-published` event.

Tasks:

- Pin the exact web888d/web888-ng-hw pair validated in Phase 1; track upstream
  prerelease tags explicitly rather than floating on `main` or using
  `/releases/latest`.
- Source-build the static `armv7-unknown-linux-musleabihf` daemon and matching
  UI. Upstream FPGA release artifacts may be redistributed with exact hashes
  and provenance because a Vivado build is not available in ordinary deb CI.
- Install the daemon, `/usr/share/web888d/ui/` and mutable config/state under
  `/var/lib/web888d`; do not make the admin-rewritten TOML a dpkg conffile.
- Keep `web888-web888d`, `web888-ng-bitstream` and all open FPGA artifacts out
  of the default image package list. Stock bitstreams remain owned by
  `web888-websdr`.
- Ship no default skimmers/uploads and no default password. Record sources,
  lockfiles, hashes, copyright and upstream license notices.

Package gate: reproducible build/install/remove, and installing or upgrading a
deb does not change the running/next-boot mode, selected FPGA or active
services.

### 2B. systemd, FPGA selection and switching

- Add default-off `web888-web888d.service` running as independent user
  `web888d` with supplementary group `web888`, no sudo/capabilities and no
  `/dev/xdevcfg` device allowance. Add start-rate limiting and size memory
  limits from measurements.
- Keep the shared helper in the existing `web888-redpitaya` runtime package,
  which already owns `web888-mode`; avoid duplicate PL owners. Its `select`
  operation only stages a choice, while `load` is the single web888d PL writer.
  WebSDR remains its own PL writer so its HF/VHF behavior is not rewritten.
- web888d uses a separate root oneshot `web888-web888d-pl.service` for `load`,
  waits for `prog_done`, then forces `--bitstream none`. The daemon unit never
  receives an xdevcfg allowance; a same-unit `ExecStartPre=+` is not sufficient
  because it remains subject to the main unit's `DevicePolicy=closed`.
  WebSDR consumes an explicitly staged HF snapshot through its existing
  firmware lookup, with stock fallback unchanged.
- Default to stock HF. `web888-mode APP` retains the current FPGA selection;
  `APP --fpga stock` restores stock. Changing FPGA validates and stages first,
  then stops all SDR stacks before any PL load even when the app name is
  unchanged. Reject FPGA selection for RP modes and preserve all
  stop/status/list transitions.
- Experimental `web888-ng-hf` works with web888d or stock WebSDR only after
  both `--experimental` and a root-owned acknowledgement naming the exact
  profile + SHA256. Snapshot the consented artifact into root-owned
  `/var/lib/web888-fpga/`; apt updates cannot silently change it. Open VHF and
  channelizer are not offered in this phase.
- Add explicit conflicts in all directions, including every RP instance;
  preserve an uncomplicated return to stock WebSDR after any failure.

Invariants: at most one active stack and one `/dev/zynqsdr` opener; installation
alone has no runtime effect; a failed optional server never disables the
default stack permanently; `prog_done` is a readiness check, not a bitstream
identity check.

### 2C. Product verification

Host/package:

- `systemd-analyze verify` and deb install/remove tests;
- prove package installation/upgrade cannot alter the selected or snapshotted
  FPGA, and that a new upstream digest invalidates the old experimental ack;
- extend `scripts/test-redpitaya-mode.sh` for every transition, status and
  stop case, including ordering and permission checks;
- run upstream tests relevant to the pinned source.

QEMU:

- retain `scripts/test-qemu.sh uboot`;
- use the real driver plus the Phase 1 FPGA model where supported;
- use `backend=sim` only for remaining service/UI paths, never as evidence of
  hardware compatibility;
- assert default-off state, switch state and no new failed units.

Hardware:

- install only the optional debs and confirm no service/mode/FPGA selection
  changes until an explicit `web888-mode` command;
- verify stock-HF web888d first, then the two separately acknowledged
  web888-ng-HF combinations (web888d and stock WebSDR), returning to stock
  WebSDR after each; keep open VHF/channelizer out of the acceptance matrix;
- verify actual browser audio/waterfall and HPSDR IQ, not just HTTP 200 or an
  open UDP socket;
- compare a known carrier against WebSDR and check for fixed proportional
  frequency error after every transition;
- exercise `websdr -> web888d -> websdr`, `RP HPSDR -> web888d -> websdr`, and
  `websdr -> RP -> web888d -> websdr` for ten total round trips with the
  existing 60-second port-wait allowance;
- measure 1/4/8/12 web sessions and the documented queue/degradation behaviour;
  advertise only the concurrency that passes;
- test skimmers separately and keep them disabled by default;
- perform reboot and soak testing proportional to the release decision.

### 2D. Documentation and rollout

Update the mandatory changelog/TODO/known-issues files, both root READMEs when
user-facing features change, usage/quick-reference/troubleshooting, the
WebSDR/RP coexistence document, and affected build/CI/research docs.

Documentation must distinguish the two different TCP-8073 UIs/protocols,
state the experimental scope, explain TLS/password/HPSDR behaviour, list
unimplemented or unverified functions, and give the WebSDR recovery command.

Rollout order:

1. Experimental optional deb, not preinstalled.
2. Only after sufficient operator hardware evidence, consider preinstalling
   the package while leaving the service disabled.
3. Default-server replacement is a separate future decision requiring feature
   and ecosystem compatibility analysis.
4. Public release/push requires the normal test evidence and explicit operator
   go-ahead.

## 6. Stop and rollback conditions

- A real driver ABI defect: fix our driver and add regression coverage.
- An undocumented web888d assumption: use a small upstreamable patch; do not
  create a large fork.
- Unreliable clock/frequency recovery or return to WebSDR: block release.
- Process/port startup without stable audio/IQ: not a functional pass.
- Lower concurrency than upstream claims: publish our measured limit or keep
  the package experimental.
- QEMU adaptation disproportionate to its coverage: stop/defer that track
  without discarding the ABI improvements.
- Any regression to existing users: do not publish; restore the last known-good
  package/image path.

## 7. Final acceptance criteria

### Phase 1

- Independent ABI evidence and repeatable tests exist.
- Critical driver differences are fixed or explicitly bounded.
- Existing WebSDR/RP behaviour remains verified.
- The QEMU result (usable coverage or reasoned defer) is documented.
- Hardware evidence supports the claims that simulation cannot cover.

### Phase 2

- The optional package leaves the default system unchanged.
- Three-way switching is exclusive, ordered and repeatable.
- Real web888d audio, waterfall and HPSDR data pass on hardware.
- Known-signal frequency and return-to-WebSDR behaviour are reliable.
- Host, QEMU, hardware, reboot and required soak gates pass.
- Documentation accurately lists limitations and recovery.
- No service, skimmer or upload is enabled by default.
- Provenance, source and licensing requirements are satisfied.

## 8. Phase 2 implementation and hardware record (2026-11-01)

The local Phase 2 implementation and its requested hardware matrix are
complete. The optional packages remain uninstalled by the image and nothing
was pushed to GitHub.

- Installing `web888-redpitaya` 2025.430-3, `web888-websdr` 2026.1020-2,
  `web888-web888d` 0.6.0-1 and `web888-ng-bitstream` 0.3.0-1 left stock
  WebSDR active and both web888d units static/inactive. A missing experimental
  acknowledgement rejected the requested switch without stopping WebSDR.
- Stock-HF web888d ran as `web888d:web888d` with every capability set at zero.
  HTTPS returned 200; the independent protocol-2 check passed with 174 audio
  frames and seven narrow waterfall frames. HPSDR P1 discovery succeeded and
  the pinned `p1probe` received 1145 packets (47975 samples/s for one receiver)
  with zero sequence gaps. A transient unit with the daemon's device policy
  proved that opening `/dev/xdevcfg` is denied; the service user can atomically
  replace its mutable config.
- Open-HF + web888d passed with 175 audio frames and seven narrow waterfall
  frames. Open-HF + stock WebSDR passed real audio and waterfall `E2E_OK`.
  The exact-digest snapshot was root-owned 0444. Replacing the apt-managed
  source artifact did not alter that snapshot; a later application switch
  continued to use the original open-HF snapshot. The source was then restored.
- `sdr_receiver` returned 65536 TCP1001 bytes (89.772% nonzero, 256 distinct
  values, stdev 74.51), demonstrating the RP transition from the experimental
  selection. Returning to stock removed the open snapshot and restored WebSDR
  with another `E2E_OK`. Final state: WebSDR active, stock selected,
  `prog_done=1`, no failed Web-888 application units.
- Hardware exposed two unit-sandbox defects before the successful runs. A root
  `ExecStartPre=+` could not write xdevcfg under the main unit's
  `DevicePolicy=closed`; PL loading therefore moved to the separate root
  oneshot. Its `/run/lock` directory then required an explicit writable path
  under `ProtectSystem=strict`. Both fixes have package sentinels and were
  retested on hardware.

No antenna was attached, so these are application/data-path results, not RF
frequency or signal-quality assertions. Multi-client concurrency, skimmers,
long soak/reboot campaigns and MemoryMax sizing remain rollout work, not
claims of this local implementation phase.
