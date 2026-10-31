# zynqsdr ABI validation — web888-ng cross-check

Status: **static ABI locked; full-system QEMU and hardware gates pending**
(2026-10-31). This document records evidence, not a claim that Phase 1 is
complete. The optional web888d product service remains outside Phase 1.

## Independent references

- Stock userspace ABI: `resources/reference/raspsdr-server/ioctl.h`.
- Open driver ABI: jeskko/web888-ng-hw v0.3.0, commit
  `767030740a2fdecfebdd383efd23330e6455ff1b`; the unmodified
  `driver/web888_sdr.h` and its hashes are recorded in
  `resources/reference/web888-ng-hw/PROVENANCE.md`.
- Independent userspace implementation: jeskko/web888-ng v0.6.0, commit
  `48e9914aac80e3f20c39838fe9b33193b6b3fb36`. Its workspace tests pass and a
  pinned armv7-musl `web888d` test binary builds and runs under qemu-user.
  Interoperability against our in-kernel driver is **not yet verified**.

## Static ABI matrix

`config/kernel/zynqsdr_uapi.h` is now the single UAPI definition used by the
kernel driver and userspace tests. `scripts/hw-test/zynqsdr-abi-lock.c`
checks hand-derived numeric literals independently, then checks parity with
the vendored web888-ng-hw header. Both host and static armhf builds run the
same assertions.

| ABI item | Locked value/layout | Stock + web888-ng-hw parity | Runtime status |
|---|---|---|---|
| `AD8370_SET` | `0x40045a00`, u32 | Match | Model/hardware pending |
| `MODE_SET` | `0x40045a01`, u32 | Match | Model/hardware pending |
| `CLK_SET` | `0x40045a02`, u32 | Match | Model/hardware pending |
| `GET_DNA` | `0x80085a03`, u64 | Match | Model/hardware pending |
| `RX_START` | `0x40045a04`, u32 | Match | Rearm regression added; gates pending |
| `RX_PARAM` | `0x400c5a05`, packed 12-byte struct | Match | Model/hardware pending |
| `RX_READ` | `0xc00c5a06`, packed 12-byte struct | Match | Model/hardware pending |
| `SET_GPIO_MASK` | `0x40045a07`, u32 | Match | Hardware semantics pending |
| `GET_GPIO_MASK` | `0x80045a08`, u32 | Match | Hardware semantics pending |
| `GET_SIGNATURE` | `0x80045a09`, u32 | Match | Model/hardware pending |
| `WF_START` | `0x40045a0a`, u32 | Match | Rearm regression added; gates pending |
| `WF_PARAM` | `0x400c5a0b`, packed 12-byte struct | Match | Model/hardware pending |
| `WF_READ` | `0xc00e5a0c`, packed 14-byte struct | Match | Model/hardware pending |
| `PPS_START` | `0x40045a14`, u32 | Match | Model/hardware pending |
| `PPS_READ` | `0x80045a15`, u32 | Match | Model/hardware pending |
| `WF_READ_CONTINUES` | `0x00010000` | Match | Model/hardware pending |

The lock also rejects promotion of private `RX_STOP` or web888-ng extension
ioctls into this stock-compatible public ABI.

## Behaviour matrix and explicit unknowns

| Behaviour | Current evidence | Remaining gate |
|---|---|---|
| Single opener and concurrent-open exclusion | Existing driver contract retained | Shared smoke corpus on model + hardware |
| RX/WF ring geometry, wrap, reads and close/reopen | Existing driver and userspace tests retained | Deterministic model run + hardware |
| Successful RX/WF rearm resets consumer offset | **S1 fixed in driver** after successful MMIO/arm; strict deterministic `zynqsdr-rearm-test` added | Prove pass on fixed driver and failure on old driver in full-system model, then hardware |
| Blocking, interruption, `-EINTR`, crash/close residue | No new static ABI difference | Model + hardware |
| NCO words, sample rates, signatures and channel counts | ABI definitions match | Model + hardware |
| PPS, GPIO, attenuator and DNA behaviour | ioctl encoding matches only | Model where implemented; hardware for real semantics |
| web888d as an independent consumer | Fixed binary available | End-to-end data-path report; startup alone is insufficient |

Deferred pending hardware evidence (do **not** change from source-level
speculation): WF status polarity (`0x9E`), blank-PL open gating, and initial
GPIO output levels.

## Repeatable gates

```bash
bash scripts/ci/check-zynqsdr-abi.sh
bash scripts/test-zynqsdr-qemu.sh --baremetal-only
# After assembling the Debian image and armhf test payloads:
bash scripts/test-zynqsdr-qemu.sh
```

The static gate compiles/runs the ABI lock on host and armhf/qemu-user and
compiles all shared-header consumers for both targets. The GitHub
`static-checks.yml` workflow adds trigger-manifest drift checking, shell and
Python syntax checks, and static armhf cross-compilation of the hardware-test
tools. The 13-check bare-metal model gate validates the vendored PL model; it
is not a substitute for testing our kernel driver or real hardware.
