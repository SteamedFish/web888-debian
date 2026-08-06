# Web-888 Quick Reference Guide

> Hardware and day-one facts for the Web-888 running the **Debian image**
> from this repository. Where the stock (factory) firmware behaves
> differently, that is noted explicitly. Install: [flashing.md](flashing.md);
> daily operation: [usage.md](usage.md).

## LED Status Reference

| LED | Color | Normal Behavior | Problem Indication |
|-----|-------|-----------------|-------------------|
| **D0** | Blue | Solid ON when system ready | OFF = System not booted |
| **D2** | Green | OFF during operation, flashes with activity | Solid ON = Boot failure |

### Boot Status

✅ **Normal Boot:**
- Power on → D2 turns on
- System loads → D2 turns off
- Ready → D0 (Blue) turns on
- D2 flashes during web activity

❌ **Boot Failure:**
- D2 stays ON continuously
- D0 never turns on
- **Solution:** Check TF card formatting and files

## TF Card Requirements

| Requirement | Specification |
|-------------|---------------|
| **Type** | SD or SDHC (NOT SDXC) |
| **Max Capacity** | 32GB |
| **Speed** | Class 10, not faster than 100MB/s |
| **Min Capacity** | 200MB |

**Debian image:** the card is written as a **whole-disk image** (FAT boot
partition + ext4 rootfs) with `scripts/flash-image.sh` — see
[flashing.md](flashing.md). Do NOT format it yourself.

**Stock firmware (for reference):** FAT32/FAT16 with the update files in
the card root.

### TF Card Insertion

⚠️ **Orientation:** Insert upside down (label side down, contacts facing up)

## Power Requirements

| Parameter | Minimum | Recommended |
|-----------|---------|-------------|
| Voltage | 5V | 5V ± 5% |
| Current | 2A | 2.5A+ (Fast Charger) |
| Connector | USB-C | USB-C |

⚠️ **Important:** Voltage must stay above **4.75V** under load

### Power Supply Recommendations

- ✅ Use "Fast Charger" rated adapters
- ✅ High-quality USB-C cables (low resistance)
- ✅ Linear power supply for LF/MF reception (reduces noise)
- ❌ Avoid cheap switch-mode supplies with high switching noise

## GPS Requirements

| Item | Specification |
|------|---------------|
| **Type** | Active antenna (required) |
| **Power** | 3.3V bias supplied |
| **Constellations** | GPS (Navstar), QZSS, Galileo |
| **Not Supported** | Passive antennas (will not work well) |

### GPS Status

- **Cold start:** 5-15 minutes for first lock
- **Lock indicator:** GPS LED behavior (if equipped)
- **Optimal:** Clear sky view

## Antenna Guide

### HF Antenna (SMA)

- **Frequency:** 0.01 - 62 MHz
- **Path:** 64MHz LPF → LNA → ADC
- **Recommended:**
  - Active/passive magnetic loops
  - Long wire with 9:1 balun
  - PA0RDT Mini-Whip (with proper installation)

### VHF Antenna (SMA)

- **Frequency:** 118 - 150 MHz (Air Band)
- **Path:** 129MHz BPF → +20dB LNA → ADC
- **Recommended:**
  - Ground plane (GP) antennas
  - Discone antennas

### GPS Antenna (SMA)

- **Required:** 3.3V active antenna
- **Installation:** Outdoor with clear sky view

## Network Access

### Default Access (Debian image)

- **URL:** `http://<device-ip>:8073` (no mDNS — the Debian image runs no Avahi)
- **SSH:** `ssh -p 22 root@<device-ip>` — default password `changeme`
  (change it with `passwd`)
- **Protocol:** HTTP / WebSocket

### Finding the IP Address

The Ethernet MAC always carries the stable prefix `ce:cf:3f:*`:

1. `sudo nmap -sn <your-lan-subnet>` and look for `Ce:Cf:3f` in the MAC column
2. `ip neigh | grep -i ce:cf:3f` after any contact attempt
3. Check the router DHCP client list (hostname `web888`)

## Common Issues Quick Fix

### Issue: Cannot Access Web Interface

1. ⏱️ Wait 2-3 minutes after power on
2. 🔌 Check power supply (minimum 2A)
3. 💾 Verify TF card (FAT32, files in root)
4. 🌐 Check router DHCP list
5. 🔧 Try accessing by IP instead of hostname

### Issue: D2 LED Stays On

**Problem:** Boot failure

**Solution (Debian image):**
1. Re-flash the card per [flashing.md](flashing.md) (whole image, not files)
2. Use a Class 10 SD/SDHC card (not SDXC)
3. Re-run `scripts/test-qemu.sh final` before flashing to confirm the image

**Solution (stock firmware):** reformat to FAT32 and extract the update
files to the card root (not a subfolder).

### Issue: Black Waterfall / No Audio

1. Disable "External ADC Clock" in Connect tab
2. Check antenna connection
3. Refresh browser page
4. Clear browser cache

### Issue: Can't Get GPS Lock

1. ✅ Use active GPS antenna
2. 📍 Place antenna outdoors
3. ⏱️ Wait 5-15 minutes (cold start)
4. 🔧 Check GPS antenna connection

### Issue: Slow Web Page Loading

1. Close and reopen browser tab
2. Wait a few seconds (rate limiting protection)
3. Check network connection
4. Reduce number of connected users

### Issue: Device Drops Out

1. 🔌 Check power supply rating (need 2A+)
2. 🔌 Replace USB-C cable (quality matters)
3. 🔌 Try different power socket

## Configuration Backup

### Backing Up Settings (Debian image)

```bash
scp -P 22 -r root@<device-ip>:/etc/web888 ./backup-etc-web888
```

### Files to Backup

- `/etc/web888/websdr.json` - Main configuration
- `/etc/web888/admin.json` - Admin settings
- `/var/lib/web888/` - Runtime state (DX database, recordings)

(The stock firmware kept these under `/root/kiwi.config/` on the card.)

## Specifications Summary

| Parameter | Value |
|-----------|-------|
| **ADC** | 16-bit, 130 MSPS (LTC2208) |
| **FPGA** | Xilinx Zynq-7010 (XC7Z010) |
| **CPU** | Dual ARM Cortex-A9 @ 667 MHz |
| **Channels** | 13 RX + 13 WF (TDM) |
| **HF Range** | 0.01 - 62 MHz |
| **VHF Range** | 118 - 150 MHz |
| **Network** | 1000 Mbps Ethernet |
| **GPS** | Multi-constellation, PPS |
| **Power** | 5V USB-C, 2A minimum |

## Keyboard Shortcuts (Web Interface)

| Key | Action |
|-----|--------|
| **Space** | Reset to RX frequency |
| **Z** | Center tuning mode |
| **M** | Mute/Unmute |
| **↑/↓** | Zoom in/out |
| **←/→** | Tune frequency |
| **S** | Toggle CAT sync |
| **Y** | Switch receiver (dual) |

## Extension Shortcuts

| Extension | Launch |
|-----------|--------|
| FT8 | Click extension button |
| WSPR | Click extension button |
| CW Decoder | Click extension button |
| S-Meter | Press 'M' key |

## Admin Panel Tabs

| Tab | Function |
|-----|----------|
| **Status** | Device info, serial number, temperature |
| **Control** | Frequency, mode, AGC settings |
| **Connect** | External ADC clock, GPS settings |
| **Config** | Main configuration editor |
| **Webpage** | UI customization |
| **Public** | Public access settings |
| **DX** | Station database |
| **Extensions** | Extension settings |
| **Security** | Passwords, access control |

## Support

- **This Debian project:** file an issue on the project repository
- **Stock firmware / hardware (vendor):** https://www.rx-888.com/web/ and
  https://www.rx-888.com/web/guide/ — vendor support does not cover this
  Debian image

## Reference Documents

For detailed information, see:

- [Flashing Guide](flashing.md) - Writing the Debian image to a TF card
- [Usage Guide](usage.md) - Services, mode switching, updates, backup
- [Troubleshooting Guide](troubleshooting.md) - Detailed problem solving
- [Hardware Reference](../research/hardware-reference.md) - Complete hardware details, pinout, GPSDO
- [Protocol & API Reference](../research/protocol-api.md) - WebSocket protocol and command reference

---

*Quick Reference - Print and Keep Handy*
