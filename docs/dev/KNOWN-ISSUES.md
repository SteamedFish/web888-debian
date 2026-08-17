# Known Issues — web888-debian

Open defects and limitations of the Debian port, with current evidence and
next steps. For planned work (not defects), see [`TODO.md`](TODO.md).
Hardware-verified facts live in
[`docs/research/hardware-facts.md`](../research/hardware-facts.md).

Resolved items are removed from this file once verified — see
[`CHANGELOG.md`](CHANGELOG.md) for their history. Section numbers are
stable: historical references to them (e.g. in the changelog) may point
at removed entries.

---

## 3. noip2 DDNS and frpc reverse proxy unavailable

The stock firmware's `noip2` (dynamic DNS) and `frpc` (FRP reverse-proxy
client) features have no Debian packages in any release, so the WebSDR
admin pages for them are non-functional on Debian. Candidates if demand
materialises:

- noip2 → port the DUC to the ddclient protocol, or build noip2 from
  upstream source.
- frpc → vendor the upstream static arm binary as `/usr/local/bin/frpc`
  with its upstream unit (the WebSDR ExecStopPost already guards with
  `command -v frpc`).

## 4. Minor / watchlist

- **0148 mongoose EPOLLERR fix pending hardware verification** — the
  0148 SO_ERROR pre-check only quiets the close logging: the ~0.5 s
  `/admin` websocket drops it addressed are now known to be *caused by
  the frame corruption in §6* (browser kills the connection on malformed
  frames → server sees EPOLLERR). Keep 0148, but the real fix is §6;
  watch for real connection errors still closing/logging correctly.
- **PSKReporter UDP path untested** — the KiwiSDR cherry-pick batch touched
  this code; autorun is off on the development unit, so it has never
  exercised the path on hardware.
- **One transient masked-frame** was observed on the first waterfall
  websocket connect right after a deploy (not reproducible since) — watch.
- **WebSDR restart latency after Red Pitaya apps** — after an RF-active RP
  app releases the FPGA, websdr.bin needs ~33 s before the :8073 poll
  succeeds (FPGA re-init); expected behaviour, but it makes rapid
  round-trip switching slow.
- **Step-2 optional leftovers** (not blocking): IRQ arm/enable bit-field
  probing (stock does /dev/mem writes), XADC/temperature readout,
  waterfall decimate bits 26–31 live test, PPS circuit -EBUSY-without-fix
  semantics.

## 5. QEMU test-environment limitations (not device defects)

These constrain what the pre-flash gate can cover:

- QEMU's xdevcfg model hard-hangs the guest on bitstream WRITE →
  `load-bitstream` runtime checks are hardware-only (host-side mocks
  cover the fail-closed paths).
- FSBL → U-Boot handoff is not emulatable → full-U-Boot SSBL chain is
  verified in QEMU only from U-Boot onward; the FSBL handoff is a
  hardware gate. The QEMU gate never executes the FSBL at all
  (`scripts/test-qemu.sh` direct-boots `output/u-boot.bin` via
  `-device loader`; the DDR controller is unmodeled), so the source-built
  FSBL (default since 2026-08-15) — ps7_init/DDR init, Si5351/MAC/GPIO
  hooks, and the boot.bin handoff — is verified by the hardware battery
  only (passed 2026-08-15, see the FSBL=source CHANGELOG entry). The
  pre-publish smoke jobs in the deb publisher workflows
  (`scripts/ci/qemu-smoke-deb.sh`, 2026-08-17) inherit this: a broken
  FSBL inside `web888-boot` passes the smoke gate and is only caught on
  hardware.
- QEMU masks blank-PL AXI hangs (its Zynq model returns 0 for unmapped GP
  reads) — hardware does not; see `zynqsdr-port-notes.md` §11 for the
  load-bearing probe-must-not-touch-PL rule.

## 6. /admin websocket frame corruption (mongoose 7.14 send path lost its lock)

**FIXED (0151)** — the fix routes every `send_msg*()` send through the
s2c nbuf queue so only the web_server task touches `c->send`:
`config/websdr/cherry-picks/0151-kiwi-send-msg-via-s2c-nbuf-queue.patch`,
built as web888-websdr 2026.730-7, deployed 2026-08-14. Verified: frame
validator 4 × 60 s clean, dual-tab `/admin` browser soak with zero
console errors, zero `mg_error` in the server journal. Details:
[`mongoose-websocket-frame-corruption-investigation.md`](mongoose-websocket-frame-corruption-investigation.md).

Original symptom, kept for archaeology: probabilistic `/admin` disconnects
right after opening or when clicking buttons (e.g. log), in every browser.
Cherry-pick **0144 deleted mongoose's global `mongoose_lock`** and split
frame writes into two unlocked iobuf appends (`mg_ws_send`), while Kiwi
task threads still called `send_msg*()` directly — concurrent sends raced
the web task's poll flush (`write` + `mg_iobuf_del`) and emitted
**malformed frames**. The browser killed the connection on the protocol
error; the server then logged `socket error 2` (EPOLLERR) and
`ADMIN connection closed` ~0.5 s after auth. Corruption reproduced under
concurrent admin connections at the trailing boundary of the 47 KB
`load_dxcfg` frame. Validator: `scripts/test-websocket-frames.py`.

**Regression in the 0151 fix, FIXED (0152)** — routing control messages
through the s2c queue also gave them the stream-data drop policy:
`nbuf_allocq()` silently frees buffers once the queue exceeds
`ND_HIWAT=64` (latching `ovfl` until it drains below `ND_LOWAT=32`).
The /admin startup burst (~200 entries) could overflow it and lose the
entire `ext_call` extension-config batch → /admin Extensions tab
rendered only Antenna Switch, intermittently per page load
(2026.730-7 only). 0152 sends control messages via a new
`nbuf_allocq_critical()` that bypasses the latch (hard cap 1024, loud
log if ever hit); stream data keeps the original drop behaviour. Built
as web888-websdr 2026.730-8, deployed and verified 2026-08-14 (7/7
/admin reloads show all extensions).
