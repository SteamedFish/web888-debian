#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Generate config/kernel-web888-6.12-lean.fragment from a fully-resolved
Debian armmp .config.

The Web-888 kernel starts from the Debian armmp config (broad, ~3.5k modules)
and trims everything the Zynq-7010 board can never use, following the same
strategy as Armbian's linux-zynq-legacy config: SoC's own IP stays, USB
peripheral breadth stays (users plug arbitrary dongles into the USB port),
everything else goes.

IMPORTANT: regenerate only against a FULL (untrimmed) resolved .config, i.e.
after running scripts/build-kernel-6.12.sh with KERNEL_LEAN=0. Regenerating
against an already-lean config produces an empty fragment.

Usage:
    scripts/gen-kernel-lean-fragment.py [KDIR] [OUT]
    KDIR defaults to work/linux-debian-6.12 (must contain .config)
    OUT  defaults to config/kernel-web888-6.12-lean.fragment
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KDIR = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "work/linux-debian-6.12"
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "config/kernel-web888-6.12-lean.fragment"

# ---------------------------------------------------------------- masters --
# (symbol, reason) — always emitted as "# CONFIG_X is not set".
MASTERS: list[tuple[str, str]] = [
    # Bus / platform infrastructure the board does not have
    ("PCI", "no PCI slot on Zynq-7010; cascades to NVMe, AHCI-PCI, PCI WiFi/NIC/sound/HDA"),
    ("VIRTIO", "no virtualization target; QEMU smoke test uses SD + cadence GEM"),
    ("XEN", "no Xen on a 512 MB SDR"),
    ("FPGA_MGR", "FPGA is programmed via /dev/xdevcfg (XILINX_DEVCFG), not fpga-mgr"),
    # Display / GPU — headless device, no HDMI
    ("DRM", "no display output; kills GPU/display ecosystem incl. PL330 DMA test path"),
    ("FB", "no framebuffer console; serial/SSH only"),
    # Storage the board does not have
    ("ATA", "no SATA/PATA"),
    ("MD", "no RAID/LVM-on-kernel; 512 MB ARM board"),
    ("MTD", "no QSPI/NAND flash node in web888.dts (dropped when adding I2C EEPROM)"),
    # Virtualization / server ecosystems
    ("INFINIBAND", "no RDMA"),
    ("TARGET_CORE", "no iSCSI target"),
    ("CORESIGHT", "no ARM coresight debug tracing"),
    ("ACCESSIBILITY", "no braille console"),
    # Exotic buses
    ("W1", "no 1-wire devices"),
    ("NFC", "no NFC"),
    # Media: keep USB UVC webcams only
    ("MEDIA_CEC_SUPPORT", "no HDMI CEC"),
    ("MEDIA_ANALOG_TV_SUPPORT", "no analog TV"),
    ("MEDIA_DIGITAL_TV_SUPPORT", "no DVB tuners; RTL-SDR users prefer direct libusb (no blacklist needed)"),
    ("MEDIA_RADIO_SUPPORT", "no AM/FM radio tuners"),
    ("MEDIA_SDR_SUPPORT", "no V4L2 SDR receivers; RTL-SDR users prefer direct libusb"),
    ("MEDIA_PLATFORM_SUPPORT", "no platform video capture (imx/rockchip/sunxi/bcm2835)"),
    ("MEDIA_TEST_SUPPORT", "no vivid test drivers"),
    ("RC_CORE", "no infrared remote"),
    # Sound: keep USB audio only (sound keep-regex retains core + SND_USB*)
    ("SND_SOC", "no ASoC codecs (ADI/HDMI audio IP unused in web888.dts)"),
    ("SND_DRIVERS", "no legacy ISA/platform sound drivers"),
    ("SOUNDWIRE", "no SoundWire audio bus"),
    # Network protocols nobody uses on an SDR receiver
    ("ATM", "no ATM networking"),
    ("X25", "no X.25 (AX.25 ham radio stays)"),
    ("LAPB", "X.25 link layer"),
    ("IEEE802154", "no 802.15.4 radios; cascades to 6lowpan"),
    ("RDS", "no RDS sockets"),
    ("SMC", "no IBM SMC"),
    ("PHONET", "no Nokia phonet"),
    ("CAIF", "no CAIF"),
    ("QRTR", "Qualcomm IPC router (PCI 5G modems only, dead with PCI)"),
    ("MHI_BUS", "Qualcomm MHI (PCI modems only)"),
    ("NET_DSA", "no switch fabric on a single-NIC board"),
    ("NET_PKTGEN", "no packet generator"),
    ("NET_DROP_MONITOR", "no drop monitor"),
    ("ATALK", "no AppleTalk"),
    ("IPX", "no IPX/SPX"),
    ("ARCNET", "no ARCNET"),
    ("UWB", "no ultra-wideband"),
    ("WIMAX", "no WiMAX"),
    ("FRAME_RELAY", "no frame relay"),
    ("HDLC", "no sync-serial HDLC"),
    # USB host controllers the Zynq-7010 does not have (chipidea is kept)
    ("USB_XHCI_HCD", "no USB3 xHCI on Zynq-7010"),
    ("USB_DWC3", "no DWC3 controller (Zynq USB is chipidea)"),
    ("USB_DWC2", "no DWC2 controller (Zynq USB is chipidea)"),
    # Build speed: module signing costs CPU per module; no secure boot here
    ("MODULE_SIG", "skip module signing (Debian enables MODULE_SIG_ALL)"),
    ("SECURITY_LOCKDOWN_LSM", "selects MODULE_SIG; no secure boot on this board"),
    ("IMA_APPRAISE_MODSIG", "module appraisal needs signing; off with MODULE_SIG"),
    # No remote processors on Zynq-7010 (that is ZynqMP R5 territory);
    # REMOTEPROC/RPMSG select VIRTIO and keep the whole virtio stack alive.
    ("VIRTIO_FS", "selects VIRTIO; no virtio"),
    ("VIRTIO_CONSOLE", "selects VIRTIO; =y in Debian base so dir rules miss it"),
    ("VIRTIO_ANCHOR", "selected by VIRTIO"),
    ("REMOTEPROC", "no remote processors on Zynq-7010"),
    ("RPMSG", "no remote processors; RPMSG_VIRTIO selects VIRTIO"),
]

# Symbols the trim must explicitly ENABLE (mostly to activate filter prompts
# whose absence makes the support switches below them promptless and
# unkillable — an invisible Kconfig symbol ignores user values).
SETS: list[tuple[str, str]] = [
    ("MEDIA_SUPPORT_FILTER", "y"),  # makes MEDIA_*_SUPPORT prompts killable
    ("MEDIA_CAMERA_SUPPORT", "y"),  # UVC webcams stay
]

# Exotic filesystems (explicit kills; popular ones stay: btrfs xfs f2fs
# ntfs3 exfat hfs/hfsplus vfat nfs cifs smb_server iso9660 udf fuse squashfs)
FS_KILLS = [
    "CEPH_FS", "GFS2_FS", "OCFS2_FS", "AFS_FS", "CODA_FS", "NILFS2_FS",
    "JFS_FS", "REISERFS_FS", "MINIX_FS", "ROMFS_FS", "QNX4FS_FS",
    "QNX6FS_FS", "SYSV_FS", "UFS_FS", "BEFS_FS", "BFS_FS", "EFS_FS",
    "AFFS_FS", "ADFS_FS", "NTFS_FS", "ORANGEFS_FS",
]

# ------------------------------------------------------------- dir rules --
# (kconfig dir prefix, recursive, keep set, keep regex, comment)
# All =m symbols whose Kconfig lives under the prefix and that are not kept
# are disabled. Keep lists protect the Zynq's own IP and USB-pluggable gear.
# recursive=False matches only the prefix dir itself (drivers/net, whose
# subdirs usb/wireless/ppp/slip/can/hamradio are kept by omission).
DIR_RULES: list[tuple[str, bool, set[str], str, str]] = [
    ("drivers/iio", True,
     {"XILINX_XADC"},
     r"^(IIO|IIO_BUFFER.*|IIO_KFIFO_BUF|IIO_TRIGGER.*|IIO_TRIGGERED_.*|"
     r"IIO_HRTIMER_TRIGGER|IIO_INTERRUPT_TRIGGER|IIO_SYSFS_TRIGGER|"
     r"IIO_CONSUMERS_PER_TRIGGER|IIO_SW_.*|IIO_SIMPLE_DUMMY.*)$",
     "keep IIO core + buffer/trigger plumbing + on-chip XADC; drop 300 platform sensors"),
    ("sound", True,
     set(),
     r"^(SOUND|SND|SND_TIMER|SND_PCM|SND_PCM_TIMER|SND_HWDEP|SND_RAWMIDI|"
     r"SND_JACK|SND_CTL_.*|SND_COMPRESS_.*|SND_SEQ.*|SND_SEQUENCER|"
     r"SND_OSSEMUL|SND_USB.*)$",
     "keep ALSA core + USB audio + MIDI sequencer; ASoC/HDA/OSS gone via masters/PCI"),
    ("drivers/media", True,
     {"MEDIA_SUPPORT", "MEDIA_USB_SUPPORT", "MEDIA_SUBDRV_AUTOSELECT",
      "MEDIA_CONTROLLER", "VIDEO_DEV", "VIDEO_V4L2", "V4L2_FWNODE",
      "V4L2_ASYNC", "VIDEOBUF2_CORE", "VIDEOBUF2_V4L2", "VIDEOBUF2_VMALLOC",
      "VIDEOBUF2_DMA_CONTIG", "VIDEOBUF2_DMA_SG", "USB_VIDEO_CLASS"},
     r"$^",
     "keep UVC webcams + v4l2 core ONLY (VIDEO_* blanket would keep USB TV sticks"
     " that reselect MEDIA_*_TV_SUPPORT); tuners/demods/platform capture gone"),
    ("drivers/gpu", True, set(), r"$^", "no GPU/display"),
    ("drivers/scsi", True,
     {"SCSI", "SCSI_MOD", "BLK_DEV_SD", "CHR_DEV_SR", "CHR_DEV_SG",
      "SCSI_CONSTANTS", "SCSI_LOGGING", "SCSI_PROC_FS", "SCSI_SCAN_ASYNC"},
     r"$^",
     "keep sd/sr/sg for usb-storage/UAS; drop every HBA"),
    ("drivers/mmc", True,
     {"MMC", "MMC_BLOCK", "MMC_SDHCI", "MMC_SDHCI_PLTFM",
      "MMC_SDHCI_OF_ARASAN", "MMC_CRYPTO"},
     r"$^", "keep SD host only"),
    ("drivers/net/appletalk", True, set(), r"$^", "no AppleTalk"),
    ("drivers/net/arcnet", True, set(), r"$^", "no ARCNET"),
    ("drivers/net/dsa", True, set(), r"$^", "no switch fabric"),
    ("drivers/net/ethernet", True, {"MACB", "MACB_USE_HWSTAMP"}, r"^MACB",
     "onboard cadence GEM only; NET_VENDOR_* masters kill the rest"),
    ("drivers/net/mdio", True, set(), r"$^", "no external MDIO buses"),
    ("drivers/net/pcs", True, set(), r"$^", "no SFP PCS"),
    ("drivers/net/phy", True, {"REALTEK_PHY"}, r"$^", "onboard RTL8211 only"),
    ("drivers/net/wan", True, set(), r"$^", "no sync-serial WAN cards"),
    ("drivers/net", False,
     {"TUN", "BONDING", "DUMMY", "EQL", "GTP", "IFB", "MACSEC", "MACVLAN",
      "MACVTAP", "NETCONSOLE", "NETPOLL", "NET_TEAM", "TEAM_MODE_ACTIVEBACKUP",
      "TEAM_MODE_BROADCAST", "TEAM_MODE_LOADBALANCE", "TEAM_MODE_RANDOM",
      "TEAM_MODE_ROUNDROBIN", "VETH", "VRF", "VXLAN", "GENEVE", "BAREUDP",
      "WIREGUARD"},
     r"$^",
     "root-level virtual netdevs kept; usb/wireless/ppp/slip/can/hamradio dirs untouched"),
    ("drivers/hwmon", True, {"HWMON", "HWMON_VID"}, r"$^", "no hwmon chips on the board"),
    ("drivers/watchdog", True,
     {"WATCHDOG", "WATCHDOG_CORE", "CADENCE_WATCHDOG", "SOFT_WATCHDOG"},
     r"$^", "onboard cadence wdt only"),
    ("drivers/input", True, {"INPUT", "INPUT_EVDEV", "INPUT_MOUSEDEV", "INPUT_JOYDEV"},
     r"$^", "USB HID covers keyboards/mice; drop platform key/touch/tablet drivers"),
    ("drivers/leds", True,
     set(),
     r"^(LEDS_CLASS|LEDS_GPIO|LEDS_TRIGGERS|LEDS_TRIGGER_.*)$",
     "keep GPIO LEDs + triggers"),
    ("drivers/spi", True,
     {"SPI", "SPI_MASTER", "SPI_CADENCE", "SPI_ZYNQ_QSPI", "SPIDEV", "SPI_MEM"},
     r"$^", "onboard cadence SPI only"),
    ("drivers/i2c", True,
     {"I2C", "I2C_CADENCE", "I2C_CHARDEV", "I2C_ALGOBIT"},
     r"^I2C_(MUX.*|TINY_USB|ROBOTFUZZ_OSIF|TAOS_EVM|DIOLAN_U2C|CP2615)$",
     "onboard cadence I2C + USB i2c adapters; drop platform bus drivers"),
    ("drivers/gpio", True, {"GPIO_ZYNQ", "GPIO_SYSFS", "GPIO_CDEV"}, r"$^",
     "onboard zynq GPIO only"),
    ("drivers/phy", True, {"GENERIC_PHY", "USB_ULPI_BUS"}, r"$^", "ULPI PHY core only"),
    ("drivers/crypto", True, set(), r"$^", "no HW crypto offload on Zynq-7010"),
    ("drivers/regulator", True, {"REGULATOR", "REGULATOR_FIXED_VOLTAGE"}, r"$^",
     "fixed regulators only"),
    ("drivers/power", True, {"POWER_SUPPLY"}, r"$^", "no battery/chargers"),
    ("drivers/pwm", True, {"PWM", "PWM_SYSFS"}, r"$^", "no PWM outputs"),
    ("drivers/rtc", True, set(), r"^RTC_(CLASS|HCTOSYS|SYSTOHC|INTF_).*",
     "no battery-backed RTC (chrony/gpsd set time)"),
    ("drivers/mfd", True, {"MFD_CORE", "MFD_SYSCON"}, r"$^", "no MFD chips"),
    ("drivers/video", True, set(), r"$^", "no backlight/LCD"),
    ("drivers/char", True,
     {"XILINX_DEVCFG", "ZYNQSDR", "HW_RANDOM"}, r"$^",
     "keep xdevcfg + zynqsdr SDR frontend"),
    ("drivers/nvmem", True, {"NVMEM", "NVMEM_SYSFS"}, r"$^", "keep nvmem core (EEPROM MAC)"),
    ("drivers/misc/eeprom", True, {"EEPROM_AT24", "EEPROM"}, r"$^",
     "keep AT24 EEPROM (board MAC address)"),
    ("drivers/staging", True,
     set(),
     r"^(R8188EU|R8712U|R8723BS|RTL8723BS|VT6656)$",
     "keep staging USB WiFi; drop bcm2835/imx/rockchip/sunxi media"),
    ("drivers/block", True,
     {"ZRAM", "BLK_DEV_LOOP", "BLK_DEV_NBD", "ZRAM_WRITEBACK", "ZRAM_MEMORY_TRACKING"},
     r"$^", "keep zram/loop/nbd; drop rbd/null_blk"),
    ("drivers/virtio", True, set(), r"$^", "no virtio transports"),
    ("drivers/vhost", True, set(), r"$^", "no vhost backends"),
    ("drivers/net/caif", True, set(), r"$^", "no CAIF"),
    ("drivers/rpmsg", True, set(), r"$^", "no remote processors; RPMSG_* select RPMSG"),
    ("drivers/cdx", True, set(), r"$^", "no Xilinx CDX fabric bus"),
    ("net/vmw_vsock", True, set(), r"$^", "no virtio sockets"),
]

# --------------------------------------------------------------- loading --

def load_config(path: Path) -> dict[str, str]:
    cfg: dict[str, str] = {}
    for line in path.read_text().splitlines():
        m = re.match(r"CONFIG_(\w+)=(y|m)", line)
        if m:
            cfg[m.group(1)] = m.group(2)
    return cfg


def build_symbol_dirs(kdir: Path) -> dict[str, str]:
    """Map config symbol -> Kconfig directory (relative to KDIR), one pass."""
    symdir: dict[str, str] = {}
    pat = re.compile(r"^\s*(?:menu)?config\s+(\w+)\s*$")
    for top in ("drivers", "sound", "fs", "net"):
        for root, _dirs, files in os.walk(kdir / top):
            for fn in files:
                if not fn.startswith("Kconfig"):
                    continue
                full = os.path.join(root, fn)
                rel = os.path.relpath(full, kdir)
                try:
                    with open(full, errors="ignore") as fh:
                        for line in fh:
                            m = pat.match(line)
                            if m and m.group(1) not in symdir:
                                symdir[m.group(1)] = os.path.dirname(rel)
                except OSError:
                    continue
    return symdir


def main() -> int:
    cfg_path = KDIR / ".config"
    if not cfg_path.exists():
        sys.exit(f"error: {cfg_path} not found — build a full config first "
                 f"(KERNEL_LEAN=0 scripts/build-kernel-6.12.sh)")
    cfg = load_config(cfg_path)
    symdir = build_symbol_dirs(KDIR)

    out: list[str] = [
        "# kernel-web888-6.12-lean.fragment — Web-888 kernel size/speed trim",
        "#",
        "# GENERATED by scripts/gen-kernel-lean-fragment.py — do not hand-edit.",
        "# Regenerate against a FULL config: KERNEL_LEAN=0 scripts/build-kernel-6.12.sh",
        "#",
        "# Strategy (mirrors Armbian linux-zynq-legacy): keep the Zynq's own IP",
        "# drivers and full USB peripheral breadth (serial/net/storage/UAS/audio/",
        "# BT/WiFi/gadget/UVC), drop everything the board can never host: PCI,",
        "# GPU/DRM/FB, DVB/analog/radio/platform media, ASoC, platform IIO,",
        "# ATA/NVMe/Infiniband/MD/Xen/target/coresight, exotic filesystems and",
        "# network protocols. This also fixes the RTL-SDR/DVB conflict (DVB",
        "# drivers no longer grab RTL2832 dongles).",
        "",
    ]
    total = 0

    def emit(sym: str) -> None:
        nonlocal total
        out.append(f"# CONFIG_{sym} is not set")
        total += 1

    # 0. explicit enables
    for sym, val in SETS:
        out.append(f"CONFIG_{sym}={val}")
    out.append("")

    # 1. masters
    out.append("# --- bus/platform/display/storage/protocol masters ---")
    for sym, why in MASTERS:
        out.append(f"# [{why}]" if len(why) < 70 else f"# [{why[:67]}...]")
        emit(sym)
    out.append("")

    # 2. NET_VENDOR switches (all but CADENCE)
    out.append("# --- ethernet vendor switches (keep CADENCE = onboard GEM) ---")
    for sym in sorted(s for s, v in cfg.items()
                      if s.startswith("NET_VENDOR_") and v == "y"):
        if sym != "NET_VENDOR_CADENCE":
            emit(sym)
    out.append("")

    # 3. exotic filesystems
    out.append("# --- exotic filesystems ---")
    for sym in FS_KILLS:
        if sym in cfg:
            emit(sym)
    out.append("")

    # 4. dir rules
    for prefix, recursive, keep_set, keep_re, why in DIR_RULES:
        rx = re.compile(keep_re) if keep_re != r"$^" else None
        killed: list[str] = []
        for sym, val in sorted(cfg.items()):
            if val != "m":
                continue
            d = symdir.get(sym)
            if d is None:
                continue
            if recursive:
                if d != prefix and not d.startswith(prefix + "/"):
                    continue
            elif d != prefix:
                continue
            if sym in keep_set or (rx and rx.match(sym)):
                continue
            killed.append(sym)
        if not killed:
            continue
        out.append(f"# --- {prefix}: {why} ({len(killed)} modules dropped) ---")
        for sym in killed:
            emit(sym)
        out.append("")

    OUT.write_text("\n".join(out) + "\n")
    print(f"wrote {OUT} ({total} symbols disabled)")

    # sanity: keep-set symbols must exist in the full config
    missing = []
    for prefix, _rec, keep_set, _re, _why in DIR_RULES:
        for sym in keep_set:
            if sym not in cfg:
                missing.append(f"{prefix}: {sym}")
    if missing:
        print("WARNING keep-list symbols not present in config:")
        for m_ in missing:
            print(f"  {m_}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
