# Using the Web-888 Debian system

Day-to-day operation of the Debian image. For installation see
`flashing.md`; for hardware facts (LEDs, antennas, power, GPS) see
`quick-reference.md`; for problems see `troubleshooting.md`.

## Access

| Channel | Details |
|---|---|
| SSH | `ssh -p 22 root@<device-ip>` — default password `changeme` (change it with `passwd`) |
| Web UI (WebSDR) | `http://<device-ip>:8073/` |
| Admin panel | `http://<device-ip>:8073/admin` |
| Hostname | `web888` — reachable as `web888.local` via mDNS/Avahi (IPv4 + IPv6); fallback: find the IP by MAC prefix `ce:cf:3f:*`, see `flashing.md` §3 |

The system is a normal Debian trixie (armhf): `apt`, `systemctl`,
`journalctl` all work as usual. The root filesystem is a real ext4
partition on the TF card — changes persist across reboots (unlike the
stock firmware, which ran from RAM).

## WebSDR service

WebSDR runs as a systemd unit:

```sh
systemctl status web888-websdr.service     # status
journalctl -u web888-websdr.service -f     # live logs
systemctl restart web888-websdr.service    # restart
```

Important locations:

| Path | Contents |
|---|---|
| `/etc/web888/` | Live configuration (`websdr.json`, `admin.json`, …) — **back this up** |
| `/var/lib/web888/` | Working directory of `websdr.bin` (state, DX database, recordings) |
| `/usr/share/web888/dist/config/` | Factory-default configs (seed source) |
| `/usr/share/web888/firmware/` | FPGA bitstreams (`websdr_hf.bit`, `websdr_vhf.bit`) |
| `/usr/share/web888/samples/` | kiwi.config sample files |

The unit's `ExecStartPre` seeds missing config files from the dist
directory into `/etc/web888/` on every start — your edits are never
overwritten, only absent files are created.

### Admin console tab

The admin page (`http://<device-ip>:8073/admin`) has a **Console** tab
with an in-browser root shell (xterm.js over websocket, spawning
`bash --login`) plus shortcut buttons: `htop`, `disk free`
(`df -H /`), `clean logs`, `ping DNS`, `ping rx-888`, and
`enable hotspot`.

Notes:

- **tmux button needs a large enough terminal.** The console window
  size follows your browser window; tmux requires at least 80x24.
  If tmux fails with "open terminal failed: terminal too small",
  enlarge the browser window, disconnect, and reconnect.
- **enable hotspot** configures a WiFi AP with the stock defaults
  (SSID `web-888`, password `88888888`, wlan0 = 192.168.42.1) via the
  `web888-wificonfig ap-defaults` helper — see the WiFi section below.
  It only works with an AP-capable USB WiFi dongle attached.

## WiFi (USB dongle)

The admin page **Network** tab has a "USB WIFI Dongle Mode" switch
(**AP** / **Client**) plus SSID and password fields. Editing any of
them applies on the following websdr restart (the page offers one
automatically after an edit):

- **Client** — joins the configured SSID via wpa_supplicant + DHCP
  (`/etc/wpa_supplicant/wpa_supplicant.conf`,
  `/etc/network/interfaces.d/wlan0`).
- **AP** — the unit becomes an access point on wlan0
  (192.168.42.1/24, DHCP via dnsmasq 192.168.42.20-254,
  WPA2-PSK). Requires a dongle whose driver supports AP mode — check
  with `iw list | grep -A4 "Supported interface modes"`. The common
  RTL8188EUS (`rtl8xxxu`) dongle does **not** support AP; ath9k_htc /
  mt7601u / carl9170-class dongles do (their firmware ships in the
  image).
- **enable hotspot** (Console tab) — one-click AP with the stock
  defaults (SSID `web-888`, password `88888888`).

By default (fresh image, never touched the WiFi controls) **nothing is
configured** — Ethernet stays the only managed interface. NAT/internet
forwarding for AP clients is not set up.

To stop WiFi management entirely (no UI switch for this):

```sh
sudo /usr/lib/web888/root-helpers/web888-wificonfig off
# then in /var/lib/web888/config/admin.json set "wifi_configured": false
```

Logs: `journalctl -u web888-websdr | grep WIFI` for the hook result,
`journalctl -u web888-wificonfig-apply` for the apply run.

## Switching between WebSDR and Red Pitaya apps

If the `web888-redpitaya` package is installed, the unit can run either
WebSDR **or** one Red Pitaya application at a time (they share the FPGA):

```sh
web888-mode                 # show current mode
web888-mode list            # list installed RP apps
web888-mode websdr          # switch to WebSDR (the default mode)
web888-mode <app>           # switch to an RP app, e.g. web888-mode sdr_transceiver_hpsdr
web888-mode stop            # stop everything (FPGA left as-is)
```

The switch is a **runtime** operation — no reflashing, no reboot. The
systemd units have `Conflicts=` declarations, so bare `systemctl start` is
also safe; `web888-mode` just adds correct ordering (stop the other side
before touching the FPGA).

RP app bitstreams live in `/usr/share/web888-redpitaya/apps/<app>/<app>.bit`.
Clock-restore behavior on switching is controlled by
`/etc/web888-redpitaya/switch.conf` (`SI5351_RESET`, default 0).

## Software updates

Everything is a Debian package. Images since 2026-08-16 ship with this
project's APT repository preconfigured (`apt policy` shows
`web888.steamedfish.org/apt`), so day-to-day updates are plain apt:

```sh
apt update && apt upgrade      # websdr, redpitaya, kernel, bootloader
reboot                         # only needed for kernel/bootloader updates
```

| Package | Contains |
|---|---|
| `web888-websdr` | WebSDR server, extensions, FPGA bitstreams, systemd unit |
| `web888-redpitaya` | Red Pitaya app ports, `web888-mode`, switch config |
| `web888-boot` | FSBL + U-Boot + `boot.scr`/`uEnv.txt`/`web888.dtb` (postinst safely rewrites the FAT firmware partition) |
| `linux-image-6.12.100-web888` | Kernel (new releases built per `../dev/kernel-update-sop.md`) |

Kernel upgrades repoint the `/boot/zImage` symlink automatically; no file
copying is involved. Config files under `/etc/web888/` and
`/etc/web888-redpitaya/` are conffiles — apt/dpkg will prompt before
overwriting local changes.

On images older than 2026-08-16 (no repo preconfigured) or for a
hand-built deb, fall back to the manual flow:

```sh
scp -P 22 web888-websdr_<version>_armhf.deb root@<device-ip>:/tmp/
ssh -p 22 root@<device-ip> 'dpkg -i /tmp/web888-websdr_<version>_armhf.deb'
```

## Backup

Minimum useful backup:

```sh
scp -P 22 -r root@<device-ip>:/etc/web888 ./backup-etc-web888
```

For a full system backup, image the whole TF card on a PC (`dd` /
`ddrescue`). The stock card remains the factory-firmware rollback.

## Reference clock override (EEPROM `refclock=`)

The board EEPROM (24c64 @0x50, offset 0x1800) holds a U-Boot-style env
with factory metadata (`hw_rev`, `serial`, `prod_date`, …) including
`refclock=24576000` — the Si5351 reference (TCXO) frequency in Hz.

Images since 2026-08-15 boot a **source-built FSBL** whose Red Pitaya
hooks read this env at boot and honor `refclock=` as the Si5351
reference-frequency override (the stock FSBL ignored it). This only
matters for boards retrofitted with a non-24.576 MHz TCXO — with the
factory clock no action is needed. The hooks also drive MIO49 HIGH
(internal TCXO select) and MIO10 LOW at boot; on the stock firmware
those lines were left floating. Details:
`docs/research/hardware-facts.md`.

## GPS

Use a 3.3 V active antenna (see `quick-reference.md`). After a cold start
the first fix takes 5–15 minutes with a clear sky view; the WebSDR admin
GPS page stays empty until that first fix (the chip only reports satellite
geometry once it knows its position).

## Power

Clean shutdown from SSH (`poweroff`) or the admin panel. The card is ext4
with a journal, but like any SD-card system it prefers not to lose power
mid-write.
