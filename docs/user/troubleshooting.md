# Web-888 Troubleshooting Guide

> This guide covers the **Debian image** from this repository (systemd, apt,
> ext4 rootfs on the TF card). Stock-firmware procedures are quarantined in
> **Part 2** at the bottom — they do NOT apply to the Debian system.
>
> Much of the diagnostic *reasoning* (browser audio, GPS, interference, LED
> behavior) is identical on both systems; only the commands and paths differ.

# Part 1 — Debian image

## Quick diagnostics

### Power-on sequence

1. **D2 (green)** on during boot, turns **off** when the system is up
2. **D0 (blue)** on when ready (see `../research/hardware-facts.md` for the
   exact LED sequence)
3. Web UI at `http://<device-ip>:8073` after ~1–2 minutes
4. SSH at `ssh -p 22 root@<device-ip>` (default password `changeme`)

### First commands for any problem

```sh
systemctl status web888-websdr.service     # is the server up?
journalctl -u web888-websdr.service -n 100 # what did it say last?
journalctl -b -p err                       # any boot-time errors?
df -h /                                    # rootfs full?
free -m                                    # memory pressure?
web888-mode                                # websdr or an RP app running?
```

## 1. Cannot reach the device at all

**Symptoms:** no ping, no SSH, no web UI.

1. **Find the IP.** There is no mDNS. The MAC prefix is always `ce:cf:3f:*`:
   ```sh
   sudo nmap -sn <your-lan-subnet>     # look for Ce:Cf:3f in the MAC column
   ip neigh | grep -i ce:cf:3f
   ```
   …or check the router DHCP lease table (hostname `web888`).
2. **Check the LEDs.** D2 stuck ON = boot failure → re-flash per
   `flashing.md` (and re-run `scripts/test-qemu.sh final` first). D2 off but
   no D0 = booted but userspace unhealthy.
3. **Check power.** The board needs a solid 5 V / 2 A+ supply; brownouts
   cause exactly this symptom (see `quick-reference.md` §Power).
4. **Check the card.** Class 10 SD/SDHC, not SDXC; re-flash if in doubt.
5. Worst case: swap the **stock TF card** back in to verify the hardware
   and network are fine, isolating the problem to the Debian card.

## 2. Device reachable, but web UI dead

```sh
ping <device-ip>
nc -zv <device-ip> 8073
ssh -p 22 root@<device-ip> 'systemctl status web888-websdr.service'
```

- **Unit inactive/failed:** `journalctl -u web888-websdr.service -n 200` —
  the last lines usually name the cause (config JSON syntax error, FPGA
  load failure, port already bound).
- **An RP app is running instead:** `web888-mode` shows the current mode;
  `web888-mode websdr` switches back. The two share the FPGA and cannot
  run simultaneously (the systemd units have `Conflicts=`, so this cannot
  happen by accident — only by an explicit mode switch).
- **Port open but browser fails:** try another browser / incognito window;
  the UI rate-limits rapid reconnects (wait a few seconds and reload).

## 3. Black waterfall / no RX data

The RX data path is the most intricate part of this port (the full story
and root cause are in `../research/hardware-facts.md`, "RX data path
regression"). Checklist, cheapest first:

1. `web888-mode` — confirm you are actually in `websdr` mode.
2. `systemctl restart web888-websdr.service` — a clean re-arm fixes most
   transient states.
3. Check the Si5351 clock lock:
   ```sh
   journalctl -u web888-websdr.service | grep -i si5351
   ```
   A PLL that never locks (LOL bits stuck) means the ADC/FPGA clock tree is
   unhealthy — on current images this was the gpio-polarity bug and is
   fixed; on a hand-modified DT, suspect your changes.
4. **Hardware RX self-test:**
   ```sh
   rx-matrix 0 20 40     # polls RX health properly
   ```
   Note: `zynqsdr-smoke` is a **QEMU-mode** binary — its "FAIL … (0 under
   QEMU)" messages on real hardware actually mean the hardware returned
   correct NONZERO values. Do not trust it as a hardware health check; use
   `rx-matrix`/`rx-dump`.
5. **Stale DT after a DT change:** the running device tree comes from the
   DTB **embedded in boot.bin**, not `/boot/web888.dtb`. If you changed
   `config/web888.dts` and just copied the .dtb file, nothing took effect.
   Deploy via `scripts/build-bootbin.sh final` → replace `/boot/boot.bin`
   → reboot. Verify with `od -A d -t x1 /proc/device-tree/<node>/gpios`.
6. **Partial FPGA wedge** (RX ring static while the waterfall ring stays
   live): only a full PL reconfiguration clears it — `web888-mode stop`
   then start, or reboot.
7. **Journal clock illusion:** journald rate-limiting can flush suppressed
   lines much later with old timestamps — a "frozen" websdr clock in the
   journal is NOT evidence of a wedge. Grep with absolute `--since`
   windows instead of judging by the last line's timestamp.

## 4. No audio (waterfall works)

Server side is almost never the problem; check in order:

1. **Browser autoplay policy** — click anywhere on the page; check the
   browser's autoplay permission for the site.
2. **WebSocket state** (browser console): `kiwi_ws.ws.readyState` —
   `1 = OPEN`.
3. **Mute/volume** in the UI (shortcut `M`).
4. Only then the server: `journalctl -u web888-websdr.service -f` while
   toggling audio.

## 5. GPS not locking

1. Active 3.3 V antenna, outdoors, clear sky view; cold start takes
   5–15 minutes.
2. Check what the receiver sees: the WebSDR GPS page in the admin panel
   shows satellite/lock status. Note: the satellite list stays empty until
   the *first* fix — the ATGM336H only reports elevation/azimuth once it
   knows its position, and gpsd hides zero-azimuth satellite sets.
3. Images built before 2026-08-06 had gpsd switching the GPS chip to
   UBX-only output (no NMEA), breaking the admin GPS page — fixed in
   current images. On an older install, apply the one-line fix: in
   `/etc/default/gpsd` set `GPSD_OPTIONS="-n -b -s 9600"`, then
   `systemctl restart gpsd`. Details in `../dev/KNOWN-ISSUES.md`.

## 6. Poor reception / high noise floor

Same physics as any SDR:

- Antenna connector (SMA) seated; try another antenna.
- Attenuator accidentally engaged (admin panel / `kiwi.att_val` in the
  browser console).
- Local interference: switching power supplies, LED lamps, computers.
  A **linear** PSU noticeably lowers the LF/MF noise floor
  (see `quick-reference.md` §Power).
- Wideband noise that moves with USB/network activity usually means a
  noisy supply or ground loop.

## 7. Web interface slow / unresponsive

```sh
top                    # CPU — how many active users/extensions?
free -m                # 512 MB total; watch for swap pressure
ping -c 10 <device-ip> # network latency/loss
```

- Reduce connected users and running extensions; lower the waterfall rate.
- Browser side: close other tabs, try another browser, clear cache.
- On 512 MB there is little headroom — see
  `../dev/armbian-optimizations.md` for the small-memory tuning research
  (zram etc.) if you want to experiment.

## 8. Extensions not working

```sh
journalctl -u web888-websdr.service | grep -i <extension>
dpkg -L web888-websdr | grep -i <name>    # is it shipped in the deb?
```

- Missing pieces are installed with `apt` (this is Debian — no `apk`).
- Some extensions are compile-time options; see
  `../research/extension-api-guide.md` and the cherry-pick plan in
  `../dev/web888-kiwisdr-cherry-pick-plan.md`.

## 9. Updating / recovery

- **Update packages:** `dpkg -i /tmp/<pkg>.deb` (see `usage.md` §Updates).
  Config under `/etc/web888/` is dpkg-conffile-protected.
- **Reset WebSDR config to defaults:** stop the unit, remove the files in
  `/etc/web888/` you want regenerated, start the unit — the seeder
  recreates missing files from `/usr/share/web888/dist/config/`.
- **Full reset:** re-flash the card (`flashing.md`). The stock card is the
  factory-firmware rollback.
- **Kernel/device-tree work:** follow `../dev/kernel-update-sop.md`; every
  image must pass `scripts/test-qemu.sh final` before flashing.

## Preventive maintenance (Debian)

```sh
apt update && apt upgrade          # normal Debian updates
df -h /                            # rootfs headroom
journalctl --disk-usage            # journal size (vacuum with --vacuum-size=)
cat /sys/class/thermal/thermal_zone0/temp   # millidegrees C
```

# Part 2 — Stock firmware reference (Alpine, NOT the Debian image)

> ⚠️ Everything below applies only to the **stock vendor firmware**
> (Alpine Linux 3.20, musl, OpenRC, tmpfs root). Commands like `apk`,
> `logread`, `/var/log/messages`, `/root/kiwi.config` do not exist or mean
> something else on the Debian system.

## Stock quick facts

| Item | Stock value |
|---|---|
| Web UI | `http://web-888.local` or `http://<ip>` port 8073 |
| Config | `/root/kiwi.config/` (`websdr.json`, `admin.json`, `dx.json`) |
| Logs | `logread`, `/var/log/messages` |
| Package manager | `apk` |
| Main binary | `/usr/local/bin/websdr.bin` (restart: `killall websdr.bin`) |

## Stock OTA firmware update failures

1. Verify connectivity: `ping downloads.rx-888.com`.
2. Check space: `df -h` and `df /tmp` (the stock root is a tiny tmpfs).
3. Manual update: download the firmware ZIP on a PC,
   `scp firmware.zip root@<device-ip>:/tmp/`, then on the device
   `cd /tmp && unzip firmware.zip && ./update.sh`.
4. Clean up space: `rm -f /tmp/*.zip`, `rm -rf /root/kiwi.config/*.bak`.

## Stock serial console

J3 header (3.3 V levels): Pin 2 = TX, Pin 3 = RX, Pin 4 = GND (do not
connect pin 1). 115200 8N1. This requires opening the enclosure and a
USB-serial adapter — the Debian project's workflow deliberately avoids
needing it (QEMU gate instead), but it works on both firmwares.

## Stock factory reset

- Web UI: Admin → Config → "Factory Reset", or
- Serial/SSH: `rm -rf /root/kiwi.config/* && reboot`, or
- Reflash the card with the vendor image (BalenaEtcher etc.).

## Vendor support

Stock firmware and hardware: https://www.rx-888.com/web/ and
https://www.rx-888.com/web/guide/ (vendor email: support@rx-888.com).
The vendor does not support the Debian image — for that, file an issue on
this project's repository.
