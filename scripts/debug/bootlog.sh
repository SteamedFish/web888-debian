#!/bin/sh
# bootlog.sh — blind-boot flight recorder.
#
# Installed on-device as /usr/local/bin/bootlog.sh together with
# bootlog.service (this directory). For ~5 minutes after each boot it
# appends uptime / eth0 state / top processes / websdr status / recent
# dmesg every 3 s to /boot/firmware/bootlog.txt on the FAT firmware
# partition — readable from any PC (even Windows) after a dead boot,
# which is the only telemetry available without a serial adapter.
#
# Proven 2026-10-19 during the pin-bump no-IP investigation
# (docs/dev/KNOWN-ISSUES.md #9). NOT shipped in release images;
# install manually when debugging a blind boot:
#
#   install -m 755 bootlog.sh     <rootfs>/usr/local/bin/
#   install -m 644 bootlog.service <rootfs>/etc/systemd/system/
#   ln -sf ../bootlog.service <rootfs>/etc/systemd/system/multi-user.target.wants/
LOG=/boot/firmware/bootlog.txt
mountpoint -q /boot/firmware || mount /boot/firmware 2>/dev/null
exec >> $LOG 2>&1
echo ""
echo "##### BOOT $(date) #####"
end=$(( $(cut -d. -f1 /proc/uptime) + 300 ))
while [ $(cut -d. -f1 /proc/uptime) -lt $end ]; do
  echo "--- up=$(cut -d" " -f1 /proc/uptime) $(systemctl is-system-running 2>/dev/null) ---"
  ip -4 addr show eth0 | grep -E "inet|NO-CARRIER|state" | head -3
  ip -4 link show eth0 | head -1
  ps -eo pid,pcpu,comm --sort=-pcpu | head -5
  pgrep -x websdr.bin >/dev/null && echo "websdr: RUNNING" || echo "websdr: not running"
  dmesg | tail -3
  sync
  sleep 3
done
echo "##### flight recorder done #####"
