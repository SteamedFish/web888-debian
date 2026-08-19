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

- **0153 admin status-poll fix pending hardware verification** — patch 0153
  removes the 1 Hz `SET xfer_stats` / `ADM antsw_GetCurrentAnt` sends that
  0145's admin.js resync added (RaspSDR's server implements neither →
  `ADMIN: unknown command` twice per second while an admin status tab was
  open). Patch-applies and `node --check` verified; watch the device log for
  absence of the lines after the new deb is deployed.
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
- **`ulpi-phy` NULL-deref on manual unbind** — writing
  `e0002000.phy0` to `/sys/bus/platform/drivers/ulpi-phy/unbind`
  (drivers/usb/phy/phy-ulpi.c, 6.12.100-web888) oopses in
  `ulpi_phy_remove+0xc/0x14` with `PC` reading from a NULL pointer at
  `Code: ... (e5930000)`. Reproduced live on 2026-08-19 during the
  USB-WiFi probe; the calling shell was killed but the system stayed
  up. The wedged driver state (platform device bound to a dead
  driver) delayed the subsequent `reboot` by ~10 minutes (normal
  boot is 29 s). The crash is unreachable through normal operation
  — no internal caller unbinds the PHY — so it is a known-bad-only
  path. The reporter of the bug is the chipidea/USB stack, not the
  ulpi-phy driver itself; the right fix is upstream in
  `drivers/usb/phy/phy-ulpi.c::ulpi_phy_remove` (NULL-check the
  `uphy` pointer or guard against uninstall-mid-use). Documented
  for the next time someone tries to hot-reset the USB controller
  via `unbind`/`bind`; prefer a clean reboot (or temporarily
  `echo suspend > /sys/bus/platform/devices/e0002000.usb/power/control`
  if a soft reset is needed).

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

## 7. Fresh-flash boot failures: chronyd-restricted / noip-duc / frpc / networkd-wait-online (FIXED in build scripts, pending reflash)

Found on hardware 2026-08-18: three units in `systemctl --failed` on every
fresh flash — `chronyd-restricted.service` (wins a `Conflicts=` boot race
against chrony → NTP dead when it wins; fails itself because it cannot use
the image's SHM/PPS refclocks), `noip-duc.service` (web888-websdr Depends,
installed unconfigured), `systemd-networkd-wait-online.service` (networkd
enabled by Debian's preset but manages no links → ~2 min boot stall then
failure) — plus `frpc.service` crash-looping as `activating` (web888-websdr
Depends, unconfigured, RestartSec=5s keeps it out of --failed). Root cause:
the image ships an empty `/etc/machine-id`, so systemd's first-boot preset
pass force-enables every unit with an `[Install]` section regardless of what
the build enabled. Fixed in
`scripts/configure-rootfs.sh` (in-chroot disables +
`/etc/systemd/system-preset/80-web888.preset`), `install-debs-apt.sh` and
`install-websdr.sh` (noip-duc + frpc disables) with a QEMU regression check
in `scripts/qemu-verify-step35.sh` — see the 2026-08-18 CHANGELOG entries.
Follow-up same day: the preset was first shipped as `99-web888.preset`, but
systemd applies presets in lexicographic order with first match winning, so
`90-systemd.preset`'s `enable systemd-networkd{,-wait-online}` still beat it
and a fresh flash kept networkd enabled; renamed to `80-web888.preset` and
the QEMU check now asserts (any of the five printing `enabled` fails the
gate). Remove this section once a rebuilt image is flashed and
`systemctl --failed` comes back empty.

## 8. Board USB-A port VBUS cannot sustain RTL8188EUS-class WiFi dongles

Confirmed live on 2026-08-19 against an RTL8188EUS dongle (0bda:8179,
high-speed, 480 Mb/s, `rtl8xxxu` driver) on the running dev unit. The
DH repository side is fully ready for USB-WiFi — the kernel ships
`rtl8xxxu.ko` and `rtl8188eufw.bin`, `wpasupplicant` / `hostapd` /
`iw` / `rfkill` / `wireless-regdb` are all installed by `configure-rootfs.sh`
but the host USB-A port itself cannot deliver the dongle's inrush.

### Evidence (from the on-device probe, `usb-watch.log`)

- `lsusb` shows only the root hub; the dongle is never enumerated.
- When the dongle is plugged in, `PORTSC` (chipidea EHCI, read from
  `/sys/kernel/debug/usb/ci_hdrc.0/registers`) sweeps through a 1-second
  state change (0x8c501c00 → 0x8c501000) and settles back to the
  "no device" state. `CCS` (bit0) is **0 throughout** — the EHCI
  controller never confirms a connected device.
- The kernel HUB debounce filter (100 ms minimum stable connection,
  per USB 2.0 spec) silently discards the brief window, so the
  ring buffer records **zero** `new XX-speed USB device` lines, zero
  `device descriptor read/64, error`, and zero `USB disconnect` lines.
  The session is invisible to the stack.
- The same port enumerates a Fanxiang U 盘 (0x058f:6387) as a
  high-speed device with a full descriptor dump — the host controller,
  the ULPI PHY (SMSC USB3320, integrity check passes), and the
  driver stack are all healthy.
- `OTG Control` (ULPI reg 0x0A) reads `0x67` = `DRVVBUS=1`,
  `DRVVBUS_EXT=1`, `VbusValid=1` — VBUS is actively driven and
  measured valid at the PHY. The board is not simply failing to
  power the port.

### Conclusion

The dongle powers up, briefly asserts its D+ pull-up, then loses
power in <100 ms — the VBUS rail on the board's USB-A port cannot
absorb the 8188EU's ~500 mA inrush (the U 盘 draws ~100 mA and
survives). The host then sees a "connect → disconnect within the
debounce window" event it is required to ignore. The same dongle
enumerates correctly on every other host the user has tested, and
the kernel module is loaded cleanly via `modprobe rtl8xxxu` —
neither the driver nor the image is at fault.

### Discriminating test still owed

Plug the dongle through a **self-powered USB hub** (one with its
own wall adapter) — the hub supplies the dongle's inrush from its
own 5 V rail, the board only sees the hub's comparatively tiny
upstream draw. Successful enumeration would confirm the power
hypothesis and rule out the (low-probability) alternatives
(brownout in the dongle's own LDO, marginal cable, RF-domain
interference during the EHCI chirp). The probe was attempted on
2026-08-19 but a powered hub was not on hand; the user owns the
rerun.

### Next steps

No code change is required. If the powered-hub test confirms the
diagnosis, the only follow-ups are user-facing: a note in the
user docs pointing at the powering constraint, and (longer-term,
out of repo scope) a hardware revision of the USB-A port's VBUS
supply.
