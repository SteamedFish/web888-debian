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

## 8. Board USB-A host port is marginal for RTL8188EUS-class WiFi dongles (RESOLVED via Type-C→Type-A adapter)

The direct USB-A plug on the board could not reliably enumerate an
RTL8188EUS dongle (0bda:8179, high-speed, 480 Mb/s, `rtl8xxxu` driver)
on the dev unit. **RESOLVED live on 2026-08-19**: connecting the same
dongle through a **Type-C→Type-A adapter** makes it enumerate and work
fully (high-speed, `rtl8xxxu` binds, `wlan0` comes up and actively scans
APs). No code or device-tree change was needed.

The fix being a *passive* adapter (no added power) **superseded the
original "USB-A VBUS cannot sustain ~500 mA inrush / needs a powered
hub" hypothesis** — a weak-induction VBUS-inrush failure could not be
cured by a connector adapter. The real constraint is marginal
**contact / signal integrity on the board's direct USB-A plug** for
this power-hungry class of dongle; a good adapter gives a more reliable
physical/signal path. The `self-powered hub` advice is still a valid
belt-and-braces workaround, but it is not the required fix.

### Evidence

- Direct A-plug (earlier probe): `lsusb` shows only the root hub;
  `PORTSC` (chipidea EHCI) sweeps a 1-second state change with `CCS`
  (bit0) **0 throughout**; the 100 ms HUB debounce filter discards the
  brief window so **zero** `new XX-speed USB device` / descriptor /
  disconnect lines are printed. The same port enumerates a Fanxiang
  U 盘 (0x058f:6387) as high-speed with a full descriptor dump — host
  controller, SMSC USB3320 ULPI PHY, and driver stack are all healthy.
  Reference: `docs/dev/CHANGELOG.md` 2026-08-19 kernel/usb entry.
- Adapter fix (live 2026-08-19): with the Type-C→Type-A adapter the
  dongle enumerates as `0bda:8179` high-speed, `rtl8xxxu` loads
  `rtlwifi/rtl8188eufw.bin`, `wlan0` is created, and an active scan
  returns APs — WiFi fully operational.

### User-facing note

If an RTL8188EUS-class dongle fails to enumerate on the USB-A port,
try it through a **good USB Type-C→Type-A adapter** (or a powered
hub) before suspecting the image/kernel — the DH repository kernel
and driver stack already support it.
