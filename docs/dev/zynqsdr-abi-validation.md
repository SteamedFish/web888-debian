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
- Independent userspace implementation: jeskko/web888-ng v0.6.0, commit
  `48e9914aac80e3f20c39838fe9b33193b6b3fb36`. Its workspace tests pass and a
  pinned armv7-musl `web888d` test binary builds and runs under qemu-user.
  Interoperability against our in-kernel driver is verified under the QEMU
  PL model and on hardware (HTTP + `/ws` audio/waterfall).

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
| RX/WF ring geometry, wrap, reads and close/reopen | Model and hardware reads/rearm/close-reopen passed; driver wrap coverage remains limited | Optional additional wrap-specific case |
| Successful RX/WF rearm resets consumer offset | **S1 fixed in driver**; fixed model positive and pre-S1 negative controls passed, and hardware rearm passed | Strict deterministic resync assertion is model-only; Phase 1 hardware gate complete |
| Blocking, interruption, `-EINTR`, crash/close residue | Basic model/hardware I/O and concurrent reads passed | Optional interruption/crash cases |
| NCO words, sample rates, signatures and channel counts | Model and hardware smoke/data-path checks passed | RF level/frequency accuracy not asserted (no antenna) |
| PPS, GPIO, attenuator and DNA behaviour | Model and hardware ioctl smoke passed | Electrical/timing semantics remain hardware-specific follow-ups |
| web888d as an independent consumer | Model and hardware HTTP + `/ws` data path passed against the in-kernel driver | Product integration remains a separate Phase 2 decision |

Deferred pending hardware evidence (do **not** change from source-level
speculation): WF status polarity (`0x9E`), blank-PL open gating, and initial
GPIO output levels.

## Full-system model evidence (2026-10-31)

The complete opt-in command below passed against the assembled Debian image:
12 bare-metal checks, the full smoke corpus (including 50 arm/disarm cycles),
RX/WF0/WF1 rearm, web888d HTTP readiness and the `/ws` data-path check. The
last web888d run received 584 audio frames and 7 narrow waterfall lines,
with pong and a 10000029 Hz model peak (`df=117.1875 Hz`, 0.25 bins from the
requested centre). A separate snapshot-boot negative control loaded the
pre-S1 module built from `78f91a7^`: RX rearm returned 131072 stale bytes and
both WF channels returned 16384 instead of the fresh 32768-byte block, so the
regression test rejected it with all three expected failures. The old module
was only a gitignored test artifact (SHA256
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
  single-opener, ioctl, concurrent-read and 50-cycle arm/disarm checks.
- `zynqsdr-rearm.armhf --hw` printed `ZYNQSDR_REARM_OK` for RX/WF0/WF1.
  Deterministic stale-offset assertions remain model-only as documented.
- The pinned web888d used `--backend zynqsdr --bitstream none` (no devcfg
  write). Its HTTP endpoint became ready and the unmodified
  `web888d-ws-check.py` client received 174 audio frames and 7 narrow
  waterfall lines with pong: `web888d WebSocket data path: PASS`.
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
# Optional: additionally run the pinned upstream web888d binary in the
# guest as an independent stock-ABI consumer (model only, opt-in):
WEB888D=work/upstream/web888-ng/target/armv7-unknown-linux-musleabihf/release/web888d \
  bash scripts/test-zynqsdr-qemu.sh
```

The optional `WEB888D` step copies the fixed upstream `web888d` binary and the
minimal `scripts/hw-test/web888d-test-ui/` HTTP fixture into the guest scratch
dir. No Node/pnpm or upstream UI build is needed; `WEB888D_UI_DIR` remains an
optional override for testing a real UI. The script stops
`web888-websdr.service`, starts
`web888d serve --backend zynqsdr --bitstream none --no-hpsdr --no-tls
--http 127.0.0.1:8073`, polls the guest-local HTTP endpoint until ready,
requires the process to stay alive with no fatal log line, runs the `/ws`
check below, then stops it. It validates that an unmodified stock-ABI
consumer can stream against the
in-kernel driver **under the QEMU model** — it is not hardware verification
and not a web888d product-integration claim.

The check does not stop at startup: `scripts/hw-test/web888d-ws-check.py`
(fresh GPL-2.0-or-later implementation of the wire facts, attributed to the
pinned web888-ng v0.6.0 `crates/web/src/proto.rs` and
`crates/web/tests/session.rs`, cross-checked against the local checkout) runs
on the guest's python3 stdlib and proves
the data path: RFC 6455 101 handshake with `Sec-WebSocket-Accept` on `/ws`,
masked client frames, protocol-2 text control (hello proto2 / backend
zynqsdr / audio_rate 12000, state, lease granted) and binary streams —
audio kind 1 (`<BBHII f` header, n=240 @ 12000 Hz, finite RSSI, increasing
seq) and waterfall kind 2 (`<BBHI d d f f d` header, 256 bins). With
`--check-model-tone` (set by the QEMU script) it additionally asserts the
deterministic model tone: strongest narrow-view WF bin within 1 bin of the
10 MHz centre at df=117.1875 Hz, skipping stale/default full-view frames.
Without that flag the same client can smoke any web888d instance (e.g. the
`sim` backend on the host, another port). Model-only evidence — hardware
and product-integration claims remain out of scope.

The static gate compiles/runs the ABI lock on host and armhf/qemu-user and
compiles all shared-header consumers for both targets. The GitHub
`static-checks.yml` workflow adds trigger-manifest drift checking, shell and
Python syntax checks, and static armhf cross-compilation of the hardware-test
tools. The 12-check bare-metal model gate validates the vendored PL model; it
is not a substitute for testing our kernel driver or real hardware.
