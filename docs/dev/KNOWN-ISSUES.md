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

## 3. Admin-console DUC / reverse proxy — implemented; minor intentional divergences

RESOLVED 2026-08-30 (websdr 2026.730-11): the stock `noip2`/`frpc` admin
Network-tab pages are wired to the packaged `noip-duc` / `frpc` services
via the new `web888-duc` / `web888-frpc` root helpers (patch 0024;
sudoers + two-phase systemd-run sandbox escape mirror the 0023
wificonfig pattern; services stay disabled until the first successful
configure). Divergences from stock, all intentional:

- The DUC validates with a real No-IP `nic/update` probe (helper exit
  code = the form's status map). The stock "No hosts defined on your
  account" status (101) is unreachable — the protocol cannot enumerate
  an account's hosts, so a bogus host surfaces as 103 instead. Stock's
  300 ("DUC start failed") is a websdr-internal pclose code that a
  child process cannot produce (exit codes wrap at 255); helper-side
  failures surface as "DUC internal error: 1" with the reason in the
  websdr log.
- The DUC updates exactly the host in the form's Host field, which the
  form now sends (`-H`) — stock never passed it to noip2, and noip-duc
  requires an explicit hostname.
- Public-IP discovery is server-side (No-IP dns/http) instead of the
  stock `-I eth0` interface address — correct behind NAT, where stock
  reported an RFC1918 address.
- The reverse-proxy register reply still carries upstream's stale
  `status` variable (the UI shows "Existing account, registration
  successful" regardless of the tunnel's actual state) and
  `rev_status_query` still always answers 201 ("pending") — stock UI
  semantics, deliberately untouched; judge the tunnel via
  `systemctl status frpc` / `journalctl -u frpc`.
- Passwords containing a single quote break the form's `sq()` shell
  quoting upstream of the helper (stock limitation, unchanged).

## 4. Minor / watchlist

- **Admin-UI WiFi AP mode depends on the dongle** — the Network-tab
  AP switch and Console-tab hotspot button (added 2026-08-20, see
  CHANGELOG) probe `iw list` at runtime and refuse on incapable
  hardware. The commonly shipped RTL8188EUS (`rtl8xxxu`) is
  client-only (managed+monitor); AP needs ath9k_htc / mt7601u /
  carl9170-class dongles (firmware shipped). For a new buy, an
  RTL8812BU/8822BU (AC1200) is the best value (dual-band 5 GHz + AP).
  Not a defect — hardware capability. There is intentionally no UI "Off" option; the CLI
  escape hatch is documented in `docs/user/usage.md`.
- **0153 admin status-poll fix** — OBSOLETE 2026-10-12: dropped at the pin
  bump to `web-888-20260927`; the polls it removed only existed in 0145's
  resynced admin.js, which is itself dropped (upstream now ships its own
  modernized admin stack). No `ADMIN: unknown command` spam is expected
  from the new admin.js (it never had those polls); confirm on hardware
  after the 2026.1012-1 deb lands.
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

## 8. The board has no USB-A socket — only two Type-C ports, and adapter quality matters

The board physically has **two USB Type-C receptacles and no USB
Type-A connector at all**. One of the Type-C ports is the USB data
port (driven by `e0002000` / ULPI / SMSC USB3320, see
`docs/research/hardware-facts.md`); the other Type-C is **power-only**
(no USB data lines wired — it is only a 5 V charging input). Any
USB-A peripheral — including the RTL8188EUS WiFi dongle that
triggered the original 2026-08-19 investigation — therefore has to
go through a USB **Type-C→Type-A adapter** on the data Type-C. There
is no "direct USB-A plug" on this board.

Because the connector path always involves an adapter, **adapter
quality / power draw is the discriminating variable**. On the dev
unit, repeated on-device tests of the same RTL8188EUS dongle
(0bda:8179, high-speed, 480 Mb/s, `rtl8xxxu` driver) on the same
data Type-C port showed that **one** Type-C→Type-A adapter let it
enumerate and work fully (`rtl8xxxu` binds `rtlwifi/rtl8188eufw.bin`,
`wlan0` comes up, active scan finds APs), while a **different,
higher-power-draw** adapter prevented enumeration entirely (EHCI
`PORTSC` sweeps a 1-second state change with `CCS` (bit0) **0
throughout**; the 100 ms HUB debounce filter discards the brief
window, so **zero** `new XX-speed USB device` / descriptor /
disconnect lines are printed). No code or device-tree change was
needed either time — only the adapter was swapped.

### Evidence

- Same port, two adapters (the live-verified 2026-08-20 test):
  - **Adapter X (low-draw):** RTL8188EUS enumerates as `0bda:8179`
    high-speed, `rtl8xxxu` loads `rtlwifi/rtl8188eufw.bin`, `wlan0`
    is created, and an active scan returns APs — WiFi fully
    operational.
  - **Adapter Y (higher-draw):** `lsusb` shows only the root hub;
    the chipidea EHCI port sweeps `PORTSC` but `CCS` stays 0
    throughout the 1-second window, so the 100 ms HUB debounce
    filter discards it. No `new XX-speed USB device` / descriptor /
    disconnect lines. The host controller, SMSC USB3320 ULPI PHY,
    and driver stack are otherwise healthy — the same data port
    enumerates a Fanxiang U 盘 (0x058f:6387) as high-speed with a
    full descriptor dump when the test dongle is unplugged. The
    raw `lsusb`, `dmesg`, and `/sys/.../PORTSC` traces from the
    2026-08-19 failure investigation (under the now-superseded
    "direct USB-A VBUS inrush" framing) all still apply, verbatim —
    the diagnosis was wrong, not the measurements.
    Reference: `docs/dev/CHANGELOG.md` 2026-08-19 kernel/usb
    entry.
- The data Type-C port is single, fixed, and not multiplexed — only
  one Type-C on the chassis is wired to USB; **the other Type-C is
  power-only**. There is no second data port to fall back to.

### User-facing note

The hardware data path is fine — the chipidea USB host controller,
SMSC USB3320 ULPI PHY, drivers, kernel modules, and firmware are
all present and working. If a USB-A peripheral fails to enumerate
on the data Type-C port, the fix is to **swap to a different USB
Type-C→Type-A adapter** (low-draw preferred). Do **not** assume a
hardware fault on the board; do **not** keep retrying the same
adapter. A self-powered hub is still a valid belt-and-braces
workaround if no working adapter is available, but it is not the
required fix.

> **History note:** the earlier framing of this section (pre-2026-08-20,
> `git log docs/dev/KNOWN-ISSUES.md` shows the 2026-08-19 commits
> `85f762b`, `2b0a619`, `e8d5cd6`) described a "direct USB-A plug" and
> explained the working adapter as a contact-integrity fix on that
> non-existent plug. The underlying evidence — host controller /
> PHY / driver-stack health, an adapter that works — is still true;
> only the identifying hypothesis ("the USB-A plug is the marginal
> element") is wrong, because the board has no USB-A plug at all.
> The disciminating 2026-08-20 test is adapter-X vs adapter-Y on the
> **same** data Type-C: working vs failing with no other change.

## 9. Pin-bump image (websdr 2026.1012-1): no IP after hardware boot — RESOLVED 2026-10-19 (bad flash write)

Reported 2026-10-19: image built from branch `websdr-pin-bump-20260927`
(websdr pin 4dfecc46 + acarsdec split-out) flashes and boots on hardware
(image md5 verified, LEDs active) but the board never appears in
`arp-scan`. QEMU `uboot` gate passes — but QEMU cannot exercise Ethernet
(phy@1 vs QEMU phy@7 mismatch, no 24c64 EEPROM), so a hardware-only
network regression is invisible to the gate.

Statically ruled out (all byte-identical to the 2026-08-18 state or
provably non-network): boot.bin (FSBL+U-Boot), boot.scr/uEnv.txt/dtb,
kernel 6.12.100-10, `/etc` network config (ifupdown `eth0 dhcp` +
dhcpcd-base — dhclient was never installed), websdr.service ordering
(`Type=simple`, `After=network-online.target`), vendored FPGA
bitstreams, zynqsdr ioctl ABI (MODE_SET present in our driver), admin
`use_static=false` (netconfig helper only fires from the admin UI).
Image delta vs the last known-good flash is exactly web888-websdr
2026.730-11 → 2026.1012-1 plus the acarsdec package.

Bisect image built 2026-10-19 with `web888-websdr.service` **masked**
(single variable; QEMU gate re-passed) — **booted fine**, got DHCP
lease, SSH in. On-device findings: websdr.bin works perfectly when
started manually (prog_done=1, bitstream loaded, ACARS extension runs
the new `/usr/bin/acarsdec`, port 8073 listening, RSS 36 MB, no OOM);
unmasked websdr and rebooted — still boots fine. Successful-boot
timeline: growfs at ~9.5 s, DHCP lease at ~19 s, websdr starts ~25 s
(after the lease, `After=network-online.target`).

**websdr exonerated.** An 8-cycle warm-reboot loop with websdr enabled
passed 8/8 (~20 s to SSH each time). And the failing boot died before
the ~9.5 s growfs step (operator confirmed the failing card's partition
was NEVER expanded even after many power cycles → deterministic
per-flash failure, not a first-boot flake) — websdr wasn't even running
yet at that point.

Remaining suspects for the deterministic dead boot, in order:
1. **Bad flash write / marginal SD region** — the failing image and the
   working bisect image differ in rootfs layout; a bad NAND region or
   truncated write could corrupt ext4 blocks read before ~9.5 s
   (kernel boots — D2 went out — then userspace stalls on I/O).
2. Deterministic image-content bug in early boot (would have to be in
   the rootfs delta vs the bisect image, which is only the mask
   symlink — making this unlikely).

Debug image `output/web888-debian-uboot-debug-firstboot.img`
(2026-10-19, md5 `aa22ae8fcddc1733ccb02158e17f915d`) = pin-bump image
(websdr ENABLED, as the failing one) + blind-boot flight recorder
(`bootlog.service`, starts right after local-fs at ~12 s, appends
uptime/network/websdr/dmesg state every 3 s to
`/boot/firmware/bootlog.txt` on the FAT partition — readable from any
PC) + persistent journald (`/var/log/journal`). QEMU gate passed
(bootlog.service confirmed running at 12.2 s). Next: operator flashes
the debug image; if it boots, the original failure was media/write-
related; if it fails again, pull the card and read `bootlog.txt` +
journal from a PC.

**Resolution 2026-10-19:** operator flashed the debug image with
read-back verification (`head -c $(stat -c%s img) /dev/sdX | md5sum` ==
image md5) and the board booted perfectly — DHCP lease, SSH, websdr
running, prog_done=1, port 8073 up with all 4 DRM workers. Root cause
of the original dead card: **a bad flash write / marginal SD state**
(deterministic per-flash because the same corrupted blocks were hit on
every boot). websdr and the pin bump were never involved.
Countermeasures landed: `scripts/flash-image.sh` now always does a
read-back checksum verify after writing; the flight recorder is
committed as a reusable debug tool under `scripts/debug/`.

## 10. Pin-bump regressions in admin console: echo mojibake + missing TERM — FIXED 2026-10-20 (patches 0027/0028)

Found during hardware testing of branch `websdr-pin-bump-20260927`:
typing in the admin console displayed trailing garbage (`df` →
`dfÒà\±à\±Òà\±`) and `htop` failed with "Error opening terminal:
unknown", while commands still executed correctly.

Root cause of the mojibake (proven with an on-device instrumented
build logging hex dumps at the pty read/write points — the pty itself
was byte-clean): mongoose 7.14, pulled in by rebase patch 0144,
guards `mg_url_encode()` with `if (n + 4 >= len) return 0` — returning
0 and leaving the destination buffer UNTOUCHED when fewer than 4 bytes
remain at the current offset. `kiwi_str_encode()` sized its buffer
exact-fit (`slen*3+1`), so every 1-character payload (0+4 ≥ 4 — every
single-keypress console echo) returned raw heap garbage onto the
websocket. Random per session, 3–4 bytes, exactly matching the
observed symptoms. Fixed by `0027-str-encode-mongoose-guard-slack`
(buffer slack +4). Note the same latent bug exists for any exact-fit
caller; `kiwi_str_encode_static()` uses a 512-byte buffer and is safe
for realistic inputs.

The `htop` failure was independent: `console_task` execved the login
shell with a NULL envp (no `TERM`). Fixed by
`0028-console-child-term-env` (minimal env: `TERM=xterm-256color`,
`LANG`, `PATH`). Both verified on hardware 2026-10-20: exact character
echoes, `TERM=xterm-256color`, readline bracketed-paste active.
