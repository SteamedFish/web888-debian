# zynqsdr ABI validation — web888-ng cross-check

Status: **static ABI and full-system QEMU gates passed; hardware gate pending**
(2026-10-31). This document records model evidence, not a claim that Phase 1
or hardware validation is complete. The optional web888d product service
remains outside Phase 1.

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
  PL model (HTTP + `/ws` audio/waterfall); hardware remains pending.

## Static ABI matrix

`config/kernel/zynqsdr_uapi.h` is now the single UAPI definition used by the
kernel driver and userspace tests. `scripts/hw-test/zynqsdr-abi-lock.c`
checks hand-derived numeric literals independently, then checks parity with
the vendored web888-ng-hw header. Both host and static armhf builds run the
same assertions.

| ABI item | Locked value/layout | Stock + web888-ng-hw parity | Runtime status |
|---|---|---|---|
| `AD8370_SET` | `0x40045a00`, u32 | Match | Model smoke passed; hardware pending |
| `MODE_SET` | `0x40045a01`, u32 | Match | Model smoke passed; hardware pending |
| `CLK_SET` | `0x40045a02`, u32 | Match | Model smoke passed; hardware pending |
| `GET_DNA` | `0x80085a03`, u64 | Match | Model smoke passed; hardware pending |
| `RX_START` | `0x40045a04`, u32 | Match | Fixed + pre-S1 negative control passed on model; hardware pending |
| `RX_PARAM` | `0x400c5a05`, packed 12-byte struct | Match | Model smoke passed; hardware pending |
| `RX_READ` | `0xc00c5a06`, packed 12-byte struct | Match | Model smoke passed; hardware pending |
| `SET_GPIO_MASK` | `0x40045a07`, u32 | Match | Model smoke passed; hardware semantics pending |
| `GET_GPIO_MASK` | `0x80045a08`, u32 | Match | Model smoke passed; hardware semantics pending |
| `GET_SIGNATURE` | `0x80045a09`, u32 | Match | Model smoke passed; hardware pending |
| `WF_START` | `0x40045a0a`, u32 | Match | Fixed + pre-S1 negative control passed on model; hardware pending |
| `WF_PARAM` | `0x400c5a0b`, packed 12-byte struct | Match | Model smoke passed; hardware pending |
| `WF_READ` | `0xc00e5a0c`, packed 14-byte struct | Match | Model smoke passed; hardware pending |
| `PPS_START` | `0x40045a14`, u32 | Match | Model smoke passed; hardware pending |
| `PPS_READ` | `0x80045a15`, u32 | Match | Model smoke passed; hardware pending |
| `WF_READ_CONTINUES` | `0x00010000` | Match | WF read/rearm passed on model; hardware pending |

The lock also rejects promotion of private `RX_STOP` or web888-ng extension
ioctls into this stock-compatible public ABI.

## Behaviour matrix and explicit unknowns

| Behaviour | Current evidence | Remaining gate |
|---|---|---|
| Single opener and concurrent-open exclusion | Full-system model smoke passed | Hardware |
| RX/WF ring geometry, wrap, reads and close/reopen | Model reads, rearm and close/reopen passed; driver wrap coverage remains limited | Hardware and any additional wrap-specific case |
| Successful RX/WF rearm resets consumer offset | **S1 fixed in driver** after successful MMIO/arm; fixed driver passed and pre-S1 driver failed with the exact stale-ring signature | Hardware |
| Blocking, interruption, `-EINTR`, crash/close residue | Basic model I/O and concurrent reads passed | Interruption/crash cases + hardware |
| NCO words, sample rates, signatures and channel counts | Model smoke and web888d 10 MHz tone/data-path checks passed | Hardware |
| PPS, GPIO, attenuator and DNA behaviour | Model ioctl smoke passed | Hardware for real semantics |
| web888d as an independent consumer | Model HTTP and `/ws` data path passed against the in-kernel driver | Hardware run + product integration still pending |

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

## Repeatable gates

```bash
bash scripts/ci/check-zynqsdr-abi.sh
bash scripts/test-zynqsdr-qemu.sh --baremetal-only
# After assembling the Debian image (fresh host/armhf tools are auto-built):
bash scripts/test-zynqsdr-qemu.sh
# Optional: additionally run the pinned upstream web888d binary in the
# guest as an independent stock-ABI consumer (model only, opt-in):
WEB888D=work/upstream/web888-ng/target/armv7-unknown-linux-musleabihf/release/web888d \
WEB888D_UI_DIR=work/upstream/web888-ng/ui/dist \
  bash scripts/test-zynqsdr-qemu.sh
```

The optional `WEB888D` step copies the fixed upstream `web888d` binary and its
UI into the guest scratch dir, stops `web888-websdr.service`, starts
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
