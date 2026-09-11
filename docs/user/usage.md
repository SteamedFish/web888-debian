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
  RTL8188EUS (`rtl8xxxu`) is client-only; ath9k_htc / mt7601u /
  carl9170-class and the MediaTek MT7612U dongles support AP (their
  firmware ships in the image).
- **enable hotspot** (Console tab) — one-click AP with the stock
  defaults (SSID `web-888`, password `88888888`).

**Choosing a dongle.** Several dongles have been tested and all work. For a
new buy, an **RTL8812BU/8822BU (AC1200)** is the best value — dual-band,
5 GHz + AP capable. Faster cards only exceed the board's USB 2.0 bandwidth;
cheaper ones underperform in low signal and may lack 5 GHz or AP mode. If
you already have a working dongle, keep it.

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

## Dynamic DNS (No-IP) and reverse proxy (FRP)

The admin page **Network** tab's two remote-access features work on
Debian using the packaged `noip-duc` / `frpc`. Both services stay
**disabled until you configure them** here — nothing runs or contacts
any server before that.

**Dynamic DNS (DUC)** — gives the box a stable name like
`myradio.ddns.net` that follows its home IP:

1. Create the host on your No-IP account (no-ip.com; free hosts need
   re-confirming there every 30 days).
2. Fill the DUC form (username, password, update interval, and the
   **Host** field — e.g. `myradio.ddns.net`) and click **Click to
   (re)start DUC**. The helper validates the credentials against the
   real No-IP update service and only then renders
   `/etc/default/noip-duc` and enables + starts `noip-duc.service`.
3. The status box shows the outcome: *DUC started successfully*,
   *Incorrect username or password*, *Please specify a host*, or
   *Host given isn't defined on your account*. Any other code
   (*DUC internal error: N*) means the helper refused the input or the
   probe could not reach No-IP — the reason is in
   `journalctl -u web888-websdr | grep 'web888-duc:'`.

The form can be re-submitted any time to change credentials, interval
or host. To take manual control of the daemon instead, edit
`/etc/default/noip-duc` (`NOIP_*` variables) and
`systemctl enable --now noip-duc`; note the admin form overwrites that
file whenever it is used again. The public IP is discovered by the
No-IP service itself (dns/http), so it is correct behind NAT.

**Reverse proxy (FRP)** — reaches the WebSDR through the public
`proxy.rx-888.com` relay with your Web-888 user key, useful when the
box sits behind CGNAT or a firewall you cannot open:

1. Fill in the **User key** (from your Web-888 vendor registration)
   and a **Host name** (`a-z 0-9 -`), optionally a different proxy
   server, and click **Click to (re)register**. The helper verifies
   the generated config (`frpc verify`), installs it as
   `/etc/frp/frpc.toml` and enables + starts `frpc.service`; the
   receiver is then reachable at the URL the admin page displays
   (`<host name>.proxy.rx-888.com` with the default server).
2. The proxy server field defaults to `proxy.rx-888.com`; pointing it
   at your own `frps` instance works the same way.

For manual (non-admin-UI) use, edit `/etc/frp/frpc.toml` and
`systemctl enable --now frpc` — same file, same unit; the admin form
overwrites that file whenever it registers again. The WebSDR does not
need restarting for either feature.

Logs: `journalctl -u web888-websdr | grep -E 'DUC:|proxy register'`
(helper + config render), `journalctl -u noip-duc` / `journalctl -u
frpc` (the daemons themselves).

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

Everything is a Debian package. The image ships with this project's APT
repository preconfigured (`apt policy` shows `web888.steamedfish.org/apt`),
so day-to-day updates are plain apt:

```sh
apt update && apt upgrade      # websdr, redpitaya, kernel, bootloader
reboot                         # only needed for kernel/bootloader updates
```

| Package | Contains |
|---|---|
| `web888-websdr` | WebSDR server, extensions, FPGA bitstreams, systemd unit |
| `web888-redpitaya` | Red Pitaya app ports, `web888-mode`, switch config |
| `web888-boot` | FSBL + U-Boot + `boot.scr`/`uEnv.txt`/`web888.dtb` (postinst safely rewrites the FAT firmware partition) |
| `linux-image-6.12.100-web888` | Kernel |

Kernel upgrades repoint the `/boot/zImage` symlink automatically; no file
copying is involved. Config files under `/etc/web888/` and
`/etc/web888-redpitaya/` are conffiles — apt/dpkg prompts before overwriting
local changes.

If the APT repo is not preconfigured (or you built the deb yourself), use the
manual flow:

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

The board EEPROM stores factory metadata including the Si5351 reference
(TCXO) frequency, `refclock=24576000`. Current images honor `refclock=` as a
reference-frequency override at boot, so a board retrofitted with a
non-24.576 MHz TCXO works without further changes; factory-clock boards need
nothing. Details: [`../research/hardware-facts.md`](../research/hardware-facts.md).

## GPS

Use a 3.3 V active antenna (see `quick-reference.md`). After a cold start
the first fix takes 5–15 minutes with a clear sky view; the WebSDR admin
GPS page stays empty until that first fix (the chip only reports satellite
geometry once it knows its position).

## Power

Clean shutdown from SSH (`poweroff`) or the admin panel. The card is ext4
with a journal, but like any SD-card system it prefers not to lose power
mid-write.
