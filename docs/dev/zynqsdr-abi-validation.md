# zynqsdr ABI validation — web888-ng cross-check

Status: **static ABI, full-system QEMU and Phase 1 hardware gates passed**
(2026-10-31). The optional web888d product service remains outside Phase 1;
hardware interoperability is not a commitment to product integration.

## Independent references

- Stock userspace ABI: `resources/reference/raspsdr-server/ioctl.h`.
- Open driver ABI: jeskko/web888-ng-hw v0.3.0, commit
  `767030740a2fdecfebdd383efd23330e6455ff1b`; the unmodified
  `driver/web888_sdr.h` and its hashes are recorded in
  `resources/reference/web888-ng-hw/PROVENANCE.md`.
- Independent userspace behavioural reference: jeskko/web888-ng v0.6.0, commit
  `48e9914aac80e3f20c39838fe9b33193b6b3fb36`. Its stock-backend call sequences
  informed the project-owned datapath assertions below. Earlier optional
  web888d model/hardware interoperability runs passed, but the current gate
  requires no external server binary, UI or protocol client.

## Static ABI matrix

`config/kernel/zynqsdr_uapi.h` is now the single UAPI definition used by the
kernel driver and userspace tests. `scripts/hw-test/zynqsdr-abi-lock.c`
checks hand-derived numeric literals independently, then checks parity with
the vendored web888-ng-hw header. Both host and static armhf builds run the
same assertions.

| ABI item | Locked value/layout | Stock + web888-ng-hw parity | Runtime status |
|---|---|---|---|
| `AD8370_SET` | `0x40045a00`, u32 | Match | Model + hardware smoke passed |
| `MODE_SET` | `0x40045a01`, u32 | Match | Model + hardware smoke passed |
| `CLK_SET` | `0x40045a02`, u32 | Match | Model + hardware smoke passed |
| `GET_DNA` | `0x80085a03`, u64 | Match | Model + hardware smoke passed |
| `RX_START` | `0x40045a04`, u32 | Match | Model positive/negative + hardware rearm passed |
| `RX_PARAM` | `0x400c5a05`, packed 12-byte struct | Match | Model + hardware smoke passed |
| `RX_READ` | `0xc00c5a06`, packed 12-byte struct | Match | Model + hardware smoke passed |
| `SET_GPIO_MASK` | `0x40045a07`, u32 | Match | Model + hardware ioctl smoke passed; electrical semantics not re-measured |
| `GET_GPIO_MASK` | `0x80045a08`, u32 | Match | Model + hardware ioctl smoke passed; electrical semantics not re-measured |
| `GET_SIGNATURE` | `0x80045a09`, u32 | Match | Model + hardware smoke passed |
| `WF_START` | `0x40045a0a`, u32 | Match | Model positive/negative + hardware rearm passed |
| `WF_PARAM` | `0x400c5a0b`, packed 12-byte struct | Match | Model + hardware smoke passed |
| `WF_READ` | `0xc00e5a0c`, packed 14-byte struct | Match | Model + hardware smoke passed |
| `PPS_START` | `0x40045a14`, u32 | Match | Model + hardware smoke passed |
| `PPS_READ` | `0x80045a15`, u32 | Match | Model + hardware smoke passed |
| `WF_READ_CONTINUES` | `0x00010000` | Match | Model + hardware WF read/rearm passed |

The lock also rejects promotion of private `RX_STOP` or web888-ng extension
ioctls into this stock-compatible public ABI.

## Behaviour matrix and explicit unknowns

| Behaviour | Current evidence | Remaining gate |
|---|---|---|
| Single opener and concurrent-open exclusion | Model and hardware smoke passed | Phase 1 gate complete |
| RX/WF ring geometry, wrap, reads and close/reopen | Project-owned model datapath drains beyond the complete RX ring and checks 12-channel I/Q framing across its non-frame-aligned wrap; hardware reads/rearm/close-reopen passed | Deterministic wrap assertion is model-only |
| Successful RX/WF rearm resets consumer offset | **S1 fixed in driver**; fixed model positive and pre-S1 negative controls passed, and hardware rearm passed | Strict deterministic resync assertion is model-only; Phase 1 hardware gate complete |
| Blocking, interruption, `-EINTR`, crash/close residue | Basic model/hardware I/O and concurrent reads passed | Optional interruption/crash cases |
| NCO words, sample rates, signatures and channel counts | Model checks strict per-channel DC/IQ statistics and armed-retune energy/sign changes; hardware smoke passed | RF level/frequency accuracy not asserted (no antenna) |
| PPS, GPIO, attenuator and DNA behaviour | Model and hardware ioctl smoke passed; AD8370 0..255 accepted and 256 rejected; GET_STATS extension rejected without buffer writes | Electrical/timing semantics remain hardware-specific follow-ups |
| WF modes and concurrent streams | Model checks continuous/one-shot polarity, armed decimation changes and interleaved RX/WF0/WF1 reads | RF/timing semantics remain model-specific |
| Historical web888d interoperability | Optional model and hardware HTTP + `/ws` runs passed | Not a current dependency; product integration remains a Phase 2 decision |

Deferred pending hardware evidence (do **not** change from source-level
speculation): WF status polarity (`0x9E`), blank-PL open gating, and initial
GPIO output levels.

## Full-system model evidence (2026-10-31)

The complete current command below passed against the assembled Debian image:
12 bare-metal checks, the full smoke corpus (including GET_STATS rejection,
front-end boundaries and 50 arm/disarm cycles), RX/WF0/WF1 rearm, and the
project-owned datapath tool. Datapath validated every RX channel's framing,
I/Q layout and statistics, drained 530304 bytes across the 0x7fc00 ring wrap,
retuned all channels while armed, changed WF decimation 1→2 with a fresh full
block, and completed interleaved RX/WF0/WF1 reads. It consumed 636480 RX bytes
in total. No web888d executable or protocol client participated.

A separate snapshot-boot negative control loaded the pre-S1 module built from
`78f91a7^`: RX rearm returned 131072 stale bytes and both WF channels returned
16384 instead of the fresh 32768-byte block, so the regression test rejected it
with all three expected failures. The old module was only a gitignored test
artifact (SHA256
`172aa292554c5a888ceee0ae82a4c064cb2b8b5fd56bbdfa6b47a6b8edf66e8a`);
it was never committed or installed into the deliverable image.

## Hardware evidence (2026-10-31)

The operator installed `linux-image-6.12.111-web888_6.12.111-2_armhf.deb`
(SHA256 `d771993b79ab8733b8c440a007a8545f28d3246f4a77c17e78bd501be01ed8b2`)
and rebooted the board. The running module matched the tested package byte for
byte (`zynqsdr.ko.xz` SHA256
`81f85955adce0baec082a9c0a966e9e181a375cc4853a3e5dc6fae71dd498dd2`).
Baseline and post-restart WebSDR `ws-e2e.py` checks both returned `E2E_OK`.
With WebSDR stopped and the already-programmed PL left running:

- `zynqsdr-smoke.armhf --hw` printed `ZYNQSDR_SMOKE_OK`, including the
  single-opener, ioctl, concurrent-read and 50-cycle arm/disarm checks. The
  updated smoke also rejected `GET_STATS 0x80405a20` with ENOTTY/EINVAL and
  an unchanged output sentinel, accepted AD8370 codes 0..255 while rejecting
  256, and exercised MODE_SET(0).
- `zynqsdr-rearm.armhf --hw` printed `ZYNQSDR_REARM_OK` for RX/WF0/WF1.
  Deterministic stale-offset assertions remain model-only as documented.
- In the earlier optional interoperability experiment, the pinned web888d used
  `--backend zynqsdr --bitstream none` (no devcfg write). Its HTTP endpoint
  became ready and the then-current, now-removed `/ws` test client received
  174 audio frames and 7 narrow waterfall lines with pong. This is historical
  evidence only; it is not part of the current gate.
- Returning to WebSDR took 33 seconds and `ws-e2e.py` again returned `E2E_OK`.
- One `web888-mode sdr_receiver` round trip returned 65536 bytes on TCP1001
  (73.105% nonzero, 256 distinct byte values, stdev 18976.35), then returned
  to WebSDR in 33 seconds with another `E2E_OK`.

The board had **no antenna**: these checks prove ABI, streams and mode
switching, not RF signal level or frequency accuracy. `chrony-wait.service`
later timed out because every configured network time source was unreachable
and GPS had no antenna; this unrelated environmental failure is not counted
as a pass for the separate fresh-image `systemctl --failed` gate. Final mode
was `websdr`, with no web888d process left running.

## Repeatable gates

```bash
bash scripts/ci/check-zynqsdr-abi.sh
bash scripts/test-zynqsdr-qemu.sh --baremetal-only
# After assembling the Debian image (fresh host/armhf tools are auto-built):
bash scripts/test-zynqsdr-qemu.sh
```

The full model command automatically builds and runs fresh host and armhf
smoke, rearm and `zynqsdr-datapath` tools. The libc-only datapath tool checks:

- 12-channel little-endian I/Q framing, per-channel energy/phase statistics,
  short reads, consumer-sized windows and continuity beyond the complete
  non-frame-aligned RX ring wrap;
- RX_PARAM retuning while armed, including energy and sign-change checks;
- continuous versus one-shot WF_START behaviour, changed versus unchanged
  WF_PARAM decimation, and fresh full blocks after a real parameter change;
- simultaneous RX/WF0/WF1 streaming with interleaved reads.

It refuses hardware (`--emu` is required) because deterministic sample and
timing assertions belong to the PL model. No web888d binary, `/ws` client,
Node/pnpm or Rust toolchain is used. The tool is a focused
GPL-2.0-or-later project implementation, with behavioural attribution to the
pinned references above.

The static gate compiles/runs the ABI lock on host and armhf/qemu-user and
compiles all shared-header consumers for both targets. The GitHub
`static-checks.yml` workflow adds trigger-manifest drift checking, shell and
Python syntax checks, and static armhf cross-compilation of the hardware-test
tools. The 12-check bare-metal model gate validates the vendored PL model; it
is not a substitute for testing our kernel driver or real hardware.
