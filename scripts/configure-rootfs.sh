#!/usr/bin/env bash
# configure-rootfs.sh — stage-3 configuration of the debootstrapped rootfs.
# Run AFTER debootstrap first+second stage, from the repo root or worktree.
# Uses qemu-arm binfmt to run everything inside the armhf chroot.
#
# Applies project decisions: hostname web888, root password changeme,
# TUNA apt mirror, DHCP via ifupdown + avahi mDNS (web888.local discovery),
# locale en_US.UTF-8, timezone Asia/Shanghai, openssh-server for SSH
# (openssh-server, not dropbear: the websdr admin
# console spawns its own sshd).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOTFS="$(readlink --canonicalize work/rootfs)"
MIRROR="${DEBIAN_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"
SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian-security}"

[[ -x "$ROOTFS/bin/sh" ]] || {
    echo "Error: $ROOTFS is not a populated rootfs (run debootstrap first)" >&2
    exit 1
}

# binfmt qemu-arm must be active; dynamically linked ARM binaries only
# resolve their loader INSIDE the chroot, so the smoke test uses chroot
if ! sudo -n chroot "$ROOTFS" /bin/true 2>/dev/null; then
    echo "Error: cannot execute ARM binaries — check binfmt (scripts/env-setup.sh)" >&2
    exit 1
fi

sudo -n tee "$ROOTFS/etc/hostname" <<<"web888" >/dev/null
sudo -n tee "$ROOTFS/etc/hosts" >/dev/null <<'EOF'
127.0.0.1	localhost
127.0.1.1	web888
::1		localhost ip6-localhost ip6-loopback
EOF

sudo -n tee "$ROOTFS/etc/apt/sources.list" >/dev/null <<EOF
deb $MIRROR trixie main contrib non-free non-free-firmware
deb $MIRROR trixie-updates main contrib non-free non-free-firmware
deb $SECURITY_MIRROR trixie-security main contrib non-free non-free-firmware
EOF

# DHCP on eth0 via ifupdown; avahi (installed below) advertises web888.local.
# eth0 uses the MAC the kernel reads from the board EEPROM via the DTB
# nvmem cell (config/web888.dts gem0/macaddr@10; prefix ce:cf:3f:*). We do
# NOT override it.
#
# Self-cleanup: build-all.sh reuses an existing work/rootfs/ (it only
# debootstraps when work/rootfs/etc is absent), so a rootfs configured by an
# older version of this script may still carry artifacts it used to install.
# Purge known-retracted ones here so a rebuilt image never ships them,
# regardless of when work/rootfs was made.
sudo -n rm -f "$ROOTFS/etc/udev/rules.d/70-web888-mac.rules" \
              "$ROOTFS/usr/sbin/web888-set-mac" 2>/dev/null || true
sudo -n mkdir --parents "$ROOTFS/etc/network/interfaces.d"
sudo -n tee "$ROOTFS/etc/network/interfaces.d/eth0" >/dev/null <<'EOF'
auto eth0
iface eth0 inet dhcp
EOF

# Boot partition mounted for easy kernel/dtb updates from userspace.
# x-systemd.growfs on /: systemd-fstab-generator turns it into
# systemd-growfs-root.service, an online resize2fs at every boot (no-op when
# the fs already fills the partition) — fs-layer half of first-boot growfs;
# the partition-layer half is web888-growroot below.
sudo -n tee "$ROOTFS/etc/fstab" >/dev/null <<'EOF'
/dev/mmcblk0p2	/	ext4	defaults,noatime,x-systemd.growfs	0 1
/dev/mmcblk0p1	/boot	vfat	defaults	0 2
EOF

# Device perms for the on-board GPS: ttyPS1 (ATGM336H NMEA) and pps0
# (pps-gpio EMIO[0]). Debian gpsd puts serials in dialout, but the pps-gpio
# device defaults to root — assign both explicitly so gpsd (user gpsd, group
# dialout) can open them at first boot, before any other rule fires.
#
# TAG+="systemd" makes udev register dev-ttyPS1.device / dev-pps0.device so the
# gpsd unit below can wait on them. pps0 is the real race victim: its driver
# (pps-gpio) is a module loaded by udev coldplug, so /dev/pps0 appears later
# than the built-in ttyPS1. gpsd, started at multi-user.target, would open
# DEVICES before pps0 exists, fail with "device activation failed, freeing
# device" and NEVER retry. The ENV{SYSTEMD_WANTS} on pps0 starts gpsd (again)
# the moment pps0 appears, recovering from any boot-time give-up.
sudo -n tee "$ROOTFS/etc/udev/rules.d/60-web888-gps.rules" >/dev/null <<'EOF'
KERNEL=="ttyPS1", GROUP="dialout", MODE="0660", TAG+="systemd"
KERNEL=="pps0",   GROUP="dialout", MODE="0664", TAG+="systemd", ENV{SYSTEMD_WANTS}="gpsd.service"
EOF

sudo -n chroot "$ROOTFS" /bin/sh -c '
set -e
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo "root:changeme" | chpasswd
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
apt-get update -qq
# Self-cleanup for reused rootfs trees (build-all.sh only debootstraps when
# work/rootfs/etc is absent): a rootfs configured before the
# dropbear→openssh-server switch still has dropbear installed+enabled.
# Purge it so the switch takes effect on any
# rootfs, then install the current package set below.
systemctl disable dropbear.service 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq dropbear dropbear-bin 2>/dev/null || true
# gpsd + chrony replace systemd-timesyncd: the Web-888 has an on-board
# ATGM336H GPS (UART1/ttyPS1) with 1PPS (pps-gpio EMIO[0] → /dev/pps0), so
# chrony disciplined by GPS PPS is a better time source than SNTP. chrony
# Conflicts/Replaces systemd-timesyncd in Debian, so installing it removes
# timesyncd. With no RTC the clock starts at build epoch each boot; the
# NMEA/PPS refclocks + makestep (see /etc/chrony/chrony.conf below) step it
# to the GPS fix, and the offline pool is a fallback when the network is up.
# iptables/miniupnpc/netcat-openbsd/sudo are the websdr Debian-compat set
# (the step-3.5 Debian-compat set): KIWI blacklist chain, upnpc NAT
# mapping, admin console, and the sudo root-helper mechanism. openssh-server
# also lets the websdr admin console spawn its own sshd -D instance.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    locales openssh-server gpsd chrony \
    iptables miniupnpc netcat-openbsd sudo \
    zram-tools log2ram cloud-guest-utils \
    avahi-daemon libnss-mdns
# Admin-console tooling: the websdr admin console tab has htop/tmux
# shortcut buttons and is generally more useful with curl/rsync around
# (update pulls, log captures). bash-completion gives the console bash
# --login shell tab completion. NB: no apostrophes anywhere inside this
# single-quoted sh -c block — one here once terminated the string early,
# ran the apt-get below on the HOST and aborted the build.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    htop tmux curl rsync bash-completion
# Step 6: firmware for the USB WiFi adapters websdr images support
# (rtl8xxxu/rtw88, ath9k_htc, brcmfmac) — sources.list carries
# non-free-firmware since step 3.5.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    firmware-linux-free firmware-brcm80211 firmware-realtek firmware-misc-nonfree \
    wireless-regdb
# WiFi tooling: wpasupplicant (client; integrates with ifupdown wpa-* options),
# hostapd (create an AP), iw (modern nl80211 config), wireless-tools (legacy
# iwconfig helpers used by many SDR/websdr scripts), rfkill (unblock radios).
# Install-only per user request — no config written here.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    wpasupplicant hostapd iw wireless-tools rfkill
# gpsd runs as user gpsd; make sure it can open the serial + PPS devices
# (the udev rule below assigns them to dialout; the gpsd Debian postinst
# adds user gpsd to dialout — re-add here in case of ordering).
id -u gpsd >/dev/null 2>&1 && adduser --quiet gpsd dialout 2>/dev/null || true
sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/default/locale
systemctl enable networking.service
systemctl enable ssh.service
# avahi-daemon publishes web888.local (hostname from /etc/hostname) and the
# ssh/http services; libnss-mdns (installed above, not just Recommended since
# we use --no-install-recommends) wires mdns4_minimal into nsswitch so the
# device also resolves other *.local hosts. RAM cost is a few MB.
systemctl enable avahi-daemon.service avahi-daemon.socket
# gpsd: socket-activated on :2947, but also enabled directly so it runs at
# boot regardless of whether anything connects. chrony replaces timesyncd
# (already removed by the chrony install above).
systemctl enable gpsd.socket gpsd.service
systemctl enable chrony.service
'

# openssh-server keeps the documented device-access contract (AGENTS.md):
# root + password login on port 22, same as dropbear had. Debian's sshd
# default is PermitRootLogin=prohibit-password, which would lock out the
# only documented credential on a headless, password-only appliance.
sudo -n tee "$ROOTFS/etc/ssh/sshd_config.d/web888.conf" >/dev/null <<'EOF'
# Managed by web888-debian image build (configure-rootfs.sh).
PermitRootLogin yes
PasswordAuthentication yes
EOF

# gpsd + chrony conffiles are dpkg-diverted (local, --rename) so future apt
# upgrades land the packaged version in *.distrib instead of clobbering ours.
# dpkg-divert needs absolute paths; the idempotency guard matches by basename
# glob (the diversion is registered under the absolute $ROOTFS-prefixed path,
# so --list must glob on the basename, not the in-rootfs path). Re-running the
# build on an already-configured rootfs must be a no-op, not an error.
divert_conffile() {
    rel="$1"          # in-rootfs path, e.g. /etc/default/gpsd
    base="$(basename "$rel")"
    # fix: older runs passed the HOST-prefixed path under --root,
    # which landed the host path in the image's diversion DB (matches nothing
    # inside the image; --rename never fired either — no .distrib files were
    # ever created). Drop such stale entries, then register the clean in-root
    # path. No --rename: dpkg honors the diversion at unpack time regardless;
    # the one consumer that needs the packaged original (log2ram.conf below)
    # snapshots it explicitly.
    if sudo -n dpkg-divert --root="$ROOTFS" --list "*$base*" | grep -q "$ROOTFS"; then
        sudo -n dpkg-divert --root="$ROOTFS" --no-rename --remove "$ROOTFS$rel"
    fi
    if ! sudo -n dpkg-divert --root="$ROOTFS" --list "$rel" | grep -q .; then
        sudo -n dpkg-divert --root="$ROOTFS" --local --no-rename \
            --divert "$rel.distrib" --add "$rel"
    fi
}

# gpsd config: fixed on-board devices (no USB hotplug → USBAUTO off), talk
# to them immediately (-n), at the ATGM336H's 9600 baud (-s 9600), and
# READ-ONLY (-b). The -b is load-bearing: gpsd 3.25's u-blox driver otherwise
# rewrites the chip's message config on connect, switching the ATGM336H to
# UBX-only output (NMEA GGA/RMC/GSA/GSV all disabled). Because the chip's
# V_BCKP keeps RAM config alive across reboots, one gpsd connect poisons the
# port permanently (the "UBX-only, no fix data anywhere" state fixed on
# 2026-08-06 — see docs/dev/CHANGELOG.md). Worse, gpsd enables no UBX SVINFO substitute on
# this chip, so SKY/satellite data vanishes too. With -b the chip keeps its
# own config (NMEA + UBX mixed, as shipped by scripts/hw-test/atgm336h-fix.py)
# and gpsd parses NMEA — matching the stock firmware's non-invasive gpsd.
divert_conffile /etc/default/gpsd
sudo -n tee "$ROOTFS/etc/default/gpsd" >/dev/null <<'EOF'
# Managed by web888-debian image build (configure-rootfs.sh).
# On-board ATGM336H GPS on UART1 (/dev/ttyPS1 @9600) + 1PPS (/dev/pps0).
USBAUTO=false
DEVICES="/dev/ttyPS1 /dev/pps0"
# Debian's /usr/lib/systemd/system/gpsd.service expands $GPSD_OPTIONS (NOT
# GPSD_OPTS) from this file. Stock Alpine uses the same GPSD_OPTIONS name, so
# this matches both. Without it, systemd reports
# "Referenced but unset environment variable ... GPSD_OPTIONS" and gpsd starts
# with no flags at all (no -n, no -s). -b (read-only) is required: without it
# gpsd 3.25 switches the ATGM336H to UBX-only output and the config sticks in
# the chip's battery-backed RAM (see docs/dev/CHANGELOG.md, 2026-08-06).
GPSD_OPTIONS="-n -b -s 9600"
EOF

# Ship the ATGM336H maintenance tool on the device so a unit stuck in
# UBX-only output mode can be repaired in the field:
#   systemctl stop gpsd gpsd.socket
#   atgm336h-fix.py fix            # enable NMEA + cold start
#   systemctl start gpsd gpsd.socket
sudo -n install -m 0755 scripts/hw-test/atgm336h-fix.py \
    "$ROOTFS/usr/local/sbin/atgm336h-fix.py"

# gpsd startup ordering: wait for the device units (created by the udev
# TAG+="systemd" above) before opening DEVICES. The pps-gpio module loads late
# (udev coldplug), and without this gpsd races it, frees /dev/pps0, and never
# retries. Wants (not Requires) so gpsd can still attempt to start if a device
# unit never becomes active; the udev ENV{SYSTEMD_WANTS} on pps0 is the real
# recovery if gpsd gave up at boot.
sudo -n mkdir -p "$ROOTFS/etc/systemd/system/gpsd.service.d"
sudo -n tee "$ROOTFS/etc/systemd/system/gpsd.service.d/wait-for-gps-devices.conf" >/dev/null <<'EOF'
# Managed by web888-debian image build (configure-rootfs.sh).
[Unit]
After=dev-ttyPS1.device dev-pps0.device chronyd.service
Wants=dev-ttyPS1.device dev-pps0.device
EOF

divert_conffile /etc/chrony/chrony.conf
sudo -n tee "$ROOTFS/etc/chrony/chrony.conf" >/dev/null <<'EOF'
# Managed by web888-debian image build (configure-rootfs.sh).
# Web-888 GPS-disciplined clock: ATGM336H NMEA on ttyPS1 via gpsd SHM 0,
# 1PPS on /dev/pps0 (pps-gpio EMIO[0]). No RTC → step on first GPS fix.

# gpsd's decoded NMEA time (coarse, ~ms).
refclock SHM 0 offset 0.5 delay 0.2 refid GPS precision 1e-6
# The GPS 1PPS edge (precise). Match stock's openrc build exactly: no
# `lock GPS` (would suppress PPS whenever SHM 0 is unhealthy, e.g. before
# first NMEA date) and no `trust prefer` (those modifiers only matter once
# both sources are already online, and we want PPS as an independent
# refclock for early-locking in degraded-sky conditions).
refclock PPS /dev/pps0 refid PPS

# Network fallback (offline = only poll when routes exist; suits no-RTC cold
# start where DNS may be up before the GPS has a fix).
pool pool.ntp.org iburst offline
makestep 1 -1
rtcsync
driftfile /var/lib/chrony/chrony.drift

# NTP service for the local LAN.
allow 192.168.0.0/16
allow 10.0.0.0/8
allow 172.16.0.0/12
EOF

# --- Armbian-inspired memory/flash optimizations (docs/dev/armbian-optimizations.md) ---

# zram compressed swap at 100% of RAM (user decision; Armbian
# default is 50%). Kernel side (CONFIG_ZRAM=m + CRYPTO_LZO) is in
# config/kernel-web888.fragment; here we drive it with Debian's zram-tools.
# No disk swap anywhere → zero TF-card wear. zswap stays compiled-in but
# disabled by default, user-toggleable at runtime.
divert_conffile /etc/default/zramswap
sudo -n tee "$ROOTFS/etc/default/zramswap" >/dev/null <<'EOF'
# Managed by web888-debian image build (configure-rootfs.sh).
ALGO=lzo-rle
PERCENT=100
PRIORITY=100
EOF

# zram swap best practice (Armbian §2.2): no readahead page clustering for
# compressed swap. Written unconditionally — /etc/sysctl.d wins over any
# /usr/lib/sysctl.d drop-in the package might ship.
sudo -n tee "$ROOTFS/etc/sysctl.d/90-web888-zram.conf" >/dev/null <<'EOF'
vm.page-cluster=0
EOF

# log2ram: /var/log on tmpfs, rsynced back to /var/log.hdd daily + at
# shutdown. 64M (upstream default 40M) leaves headroom for journald, whose
# own cap below (20M) keeps it from eating the whole tmpfs. Preserve the
# packaged defaults for every other key by sed-ing the .distrib copy.
divert_conffile /etc/log2ram.conf
if sudo -n test ! -e "$ROOTFS/etc/log2ram.conf.distrib"; then
    sudo -n cp "$ROOTFS/etc/log2ram.conf" "$ROOTFS/etc/log2ram.conf.distrib"
fi
sudo -n cp "$ROOTFS/etc/log2ram.conf.distrib" "$ROOTFS/etc/log2ram.conf"
sudo -n sed -i -e 's/^SIZE=.*/SIZE=64M/' -e 's/^USE_RSYNC=.*/USE_RSYNC=true/' \
    "$ROOTFS/etc/log2ram.conf"

sudo -n mkdir -p "$ROOTFS/etc/systemd/journald.conf.d"
sudo -n tee "$ROOTFS/etc/systemd/journald.conf.d/web888.conf" >/dev/null <<'EOF'
# Managed by web888-debian image build (configure-rootfs.sh).
[Journal]
SystemMaxUse=20M
EOF

# IO scheduler: TF card is non-rotational flash with its own internal
# queuing; mq-deadline's read-priority batching buys nothing at our near-zero
# steady-state disk I/O (logs are in RAM) while `none` is the shortest code
# path. Default is otherwise mq-deadline (verified live).
sudo -n tee "$ROOTFS/etc/udev/rules.d/60-web888-io-scheduler.rules" >/dev/null <<'EOF'
ACTION=="add|change", KERNEL=="mmcblk*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
EOF

# cpufreq: kernel default governor is ondemand (fragment). This layer lets
# the user switch to performance without rebuilding: edit
# /etc/default/web888-cpufreq, `systemctl restart web888-cpufreq-tune`.
sudo -n tee "$ROOTFS/etc/default/web888-cpufreq" >/dev/null <<'EOF'
# Managed by web888-debian image build (configure-rootfs.sh).
# Governor applied at boot by web888-cpufreq-tune.service.
# Change to "performance" to pin 666 MHz, then:
#   systemctl restart web888-cpufreq-tune.service
GOVERNOR=ondemand
EOF

sudo -n tee "$ROOTFS/usr/sbin/web888-cpufreq-tune" >/dev/null <<'EOF'
#!/bin/sh
# Apply $GOVERNOR from /etc/default/web888-cpufreq to every cpufreq policy;
# with GOVERNOR=ondemand also apply Armbian-style responsiveness tunables
# wherever the ondemand sysfs attributes exist (they appear only after the
# governor switch above, and live either globally or per-policy in 6.6).
set -eu
[ -r /etc/default/web888-cpufreq ] && . /etc/default/web888-cpufreq
GOVERNOR=${GOVERNOR:-ondemand}

for pol in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -w "$pol/scaling_governor" ] || continue
    echo "$GOVERNOR" > "$pol/scaling_governor"
done

if [ "$GOVERNOR" = ondemand ]; then
    for d in /sys/devices/system/cpu/cpufreq/ondemand \
             /sys/devices/system/cpu/cpufreq/policy*/ondemand; do
        [ -d "$d" ] || continue
        [ -w "$d/io_is_busy" ] && echo 1 > "$d/io_is_busy"
        [ -w "$d/up_threshold" ] && echo 25 > "$d/up_threshold"
        [ -w "$d/sampling_down_factor" ] && echo 10 > "$d/sampling_down_factor"
        [ -w "$d/sampling_rate" ] && echo 200000 > "$d/sampling_rate"
    done
fi
EOF
sudo -n chmod 0755 "$ROOTFS/usr/sbin/web888-cpufreq-tune"

sudo -n tee "$ROOTFS/etc/systemd/system/web888-cpufreq-tune.service" >/dev/null <<'EOF'
[Unit]
Description=Apply web888 cpufreq governor and ondemand tunables

[Service]
Type=oneshot
ExecStart=/usr/sbin/web888-cpufreq-tune
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# First-boot rootfs grow, partition layer (fs layer = x-systemd.growfs in
# fstab). The image is MBR (Zynq BootROM requirement) so systemd-repart is
# not an option; growpart (cloud-guest-utils) uses BLKPG ioctls and works on
# the busy mounted root disk. Runs before systemd-growfs-root.service so the
# same boot sees the enlarged partition; resize2fs here makes even that
# ordering non-critical.
sudo -n tee "$ROOTFS/usr/sbin/web888-growroot" >/dev/null <<'EOF'
#!/bin/sh
# Grow /dev/mmcblk0p2 (and its ext4) to fill the TF card. Idempotent: the
# gap check exits cleanly once the partition reaches the card's end, so
# running at every boot is a cheap no-op.
set -eu
DISK=mmcblk0
PART_NUM=2

disk_sectors=$(cat /sys/block/$DISK/size)
part_start=$(cat /sys/block/$DISK/${DISK}p${PART_NUM}/start)
part_size=$(cat /sys/block/$DISK/${DISK}p${PART_NUM}/size)

# 32768 sectors = 16 MiB tolerance for alignment slack at the card's end.
if [ $((disk_sectors - part_start - part_size)) -le 32768 ]; then
    exit 0
fi

growpart "/dev/$DISK" "$PART_NUM"
resize2fs "/dev/${DISK}p${PART_NUM}"
EOF
sudo -n chmod 0755 "$ROOTFS/usr/sbin/web888-growroot"

sudo -n tee "$ROOTFS/etc/systemd/system/web888-growroot.service" >/dev/null <<'EOF'
[Unit]
Description=Grow root partition and filesystem to fill the TF card
DefaultDependencies=no
After=systemd-remount-fs.service
Before=local-fs-pre.target systemd-growfs-root.service
ConditionPathExists=/usr/bin/growpart

[Service]
Type=oneshot
ExecStart=/usr/sbin/web888-growroot
RemainAfterExit=yes

[Install]
WantedBy=local-fs-pre.target
EOF

# Enable our units plus the package units (enable is idempotent; explicit so
# we don't depend on each package's preset defaults).
sudo -n systemctl --root="$ROOTFS" enable \
    web888-cpufreq-tune.service web888-growroot.service \
    zramswap.service log2ram.service

# Defensive: kernel-install's tmpfiles.conf carries "R /usr/lib/modules/*" +
# "r! %v" lines that wipe custom kernel module trees. --no-install-recommends
# keeps kernel-install out today; an empty mask here guards against any
# future package pulling it in.
sudo -n touch "$ROOTFS/etc/tmpfiles.d/kernel-install.conf"

echo "configure-rootfs: done"
echo "  hostname: web888 / root password: changeme / SSH: openssh-server port 22"
echo "  network: DHCP on eth0 (MAC = per-unit EEPROM value, prefix ce:cf:3f:*, read via DTB nvmem); avahi mDNS → web888.local"
echo "  time:    gpsd + chrony (GPS PPS-disciplined; ttyPS1 + /dev/pps0)"
echo "  memory:  zram swap 100% RAM (lzo-rle, pri 100); zswap off (toggleable)"
echo "  flash:   log2ram 64M + journald cap 20M; scheduler=none; growfs first boot"
echo "  cpu:     governor ondemand + tunables (/etc/default/web888-cpufreq)"