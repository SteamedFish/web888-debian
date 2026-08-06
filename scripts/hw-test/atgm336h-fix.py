#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""atgm336h-fix.py — diagnose and repair the Web-888 ATGM336H GPS when it is
stuck in UBX-only output mode with no fix (docs/dev/KNOWN-ISSUES.md item 1).

Device-side tool: runs on the Web-888 itself, talks UBX directly on
/dev/ttyPS1 (9600 8N1). No external dependencies.

Subcommands:
    status [SECONDS]        Listen and classify traffic: NMEA sentence counts,
                            UBX message counts, fix state (NAV-SOL + GGA).
    enable-nmea             Send UBX-CFG-MSG rate=1 for GGA/GSA/GSV/RMC
                            (3-byte form = current port, i.e. UART1).
    disable-ubx             Send UBX-CFG-MSG rate=0 for the UBX NAV messages
                            gpsd enables (DOP/SOL/TIMEGPS/POSECEF/VELECEF),
                            returning the port to pure NMEA so gpsd selects
                            the NMEA driver (it ignores NMEA GSV for SKY when
                            the u-blox driver owns the device).
    cold-start              Send UBX-CFG-RST navBbrMask=0xFFFF, resetMode=0x02
                            (GNSS-only restart, keeps RAM port/msg config).
    save                    Send UBX-CFG-CFG saving msgConf to BBR+flash so the
                            NMEA configuration survives cold starts and
                            battery loss.
    fix [--save]            enable-nmea -> cold-start -> watch until 2D/3D fix
                            (or --timeout, default 180 s) -> optionally save.

WARNING: gpsd must be stopped first (it holds ttyPS1):
    systemctl stop gpsd.service gpsd.socket chrony.service
"""

import argparse
import os
import select
import sys
import termios
import time

DEV = "/dev/ttyPS1"
BAUD = termios.B9600

SYNC = b"\xb5\x62"

# NMEA messages to enable at 1 Hz (u-blox msg ids, class 0xF0).
# GGA/RMC/GSA/GSV per docs/dev/KNOWN-ISSUES.md; GLL/VTG/ZDA are the rest of
# the classic NMEA set — harmless and useful for raw-port consumers.
NMEA_MSGS = {
    "GGA": 0x00,
    "GLL": 0x01,
    "GSA": 0x02,
    "GSV": 0x03,
    "RMC": 0x04,
    "VTG": 0x05,
    "ZDA": 0x08,
}

UBX_CLASS_NAMES = {
    0x01: "NAV",
    0x02: "RXM",
    0x04: "INF",
    0x05: "ACK",
    0x06: "CFG",
    0x0A: "MON",
    0x0B: "AID",
    0x0D: "TIM",
    0x10: "ESF",
    0x21: "LOG",
    0x27: "SEC",
    0x28: "HNR",
    0xF0: "NMEA-std",
    0xF1: "NMEA-pubx",
}

NAV_ID_NAMES = {
    0x01: "POSECEF",
    0x02: "POSLLH",
    0x04: "DOP",
    0x06: "SOL",
    0x07: "PVT",
    0x11: "VELECEF",
    0x12: "VELNED",
    0x20: "TIMEGPS",
    0x21: "TIMEUTC",
    0x30: "SVINFO",
    0x3B: "SVIN",
    0x60: "AOPSTATUS",
}

GPSFIX_NAMES = {
    0: "no-fix",
    1: "dead-reckoning",
    2: "2D",
    3: "3D",
    4: "GPS+DR",
    5: "time-only",
}


def ubx_frame(cls, mid, payload=b""):
    body = bytes([cls, mid]) + len(payload).to_bytes(2, "little") + payload
    ck_a = ck_b = 0
    for b in body:
        ck_a = (ck_a + b) & 0xFF
        ck_b = (ck_b + ck_a) & 0xFF
    return SYNC + body + bytes([ck_a, ck_b])


def open_port():
    fd = os.open(DEV, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    # raw 9600 8N1
    attrs[0] = 0  # iflag
    attrs[1] = 0  # oflag
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0  # lflag
    attrs[4] = BAUD
    attrs[5] = BAUD
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def drain(fd, seconds):
    """Read everything arriving within `seconds`; return raw bytes."""
    out = bytearray()
    end = time.monotonic() + seconds
    while True:
        left = end - time.monotonic()
        if left <= 0:
            break
        r, _, _ = select.select([fd], [], [], left)
        if not r:
            break
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        out += chunk
    return bytes(out)


class StreamParser:
    """Incremental splitter for mixed NMEA/UBX streams."""

    def __init__(self):
        self.buf = bytearray()
        self.nmea = {}          # sentence name -> count
        self.ubx = {}           # (cls,id) -> count
        self.last_gga = None    # (fix_quality, num_sv)
        self.last_navsol = None  # (gps_fix, num_sv)
        self.acks = []          # (acked, cls, id)

    def feed(self, data):
        self.buf += data
        while True:
            if not self.buf:
                return
            b0 = self.buf[0]
            if b0 == 0x24:  # '$' — NMEA to CRLF
                end = self.buf.find(b"\n")
                if end < 0:
                    return
                line = bytes(self.buf[: end + 1]).decode("ascii", "replace")
                del self.buf[: end + 1]
                self._nmea(line.strip())
            elif b0 == 0xB5 and len(self.buf) >= 2 and self.buf[1] == 0x62:
                if len(self.buf) < 6:
                    return
                cls, mid = self.buf[2], self.buf[3]
                plen = int.from_bytes(self.buf[4:6], "little")
                total = 6 + plen + 2
                if len(self.buf) < total:
                    return
                payload = bytes(self.buf[6 : 6 + plen])
                del self.buf[:total]
                self._ubx(cls, mid, payload)
            else:
                del self.buf[0]  # resync

    def _nmea(self, line):
        name = line[1:6] if len(line) >= 6 else line
        self.nmea[name] = self.nmea.get(name, 0) + 1
        if name.endswith("GGA"):
            f = line.split(",")
            if len(f) > 7:
                try:
                    self.last_gga = (int(f[6] or 0), int(f[7] or 0))
                except ValueError:
                    pass

    def _ubx(self, cls, mid, payload):
        self.ubx[(cls, mid)] = self.ubx.get((cls, mid), 0) + 1
        if cls == 0x01 and mid == 0x06 and len(payload) >= 52:  # NAV-SOL
            self.last_navsol = (payload[10], payload[47])
        elif cls == 0x05 and mid in (0x00, 0x01) and len(payload) == 2:
            self.acks.append((mid == 0x01, payload[0], payload[1]))

    def summary(self):
        lines = []
        if self.nmea:
            lines.append("NMEA: " + ", ".join(
                f"{k}x{v}" for k, v in sorted(self.nmea.items())))
        else:
            lines.append("NMEA: none")
        if self.ubx:
            parts = []
            for (cls, mid), v in sorted(self.ubx.items()):
                cname = UBX_CLASS_NAMES.get(cls, f"{cls:02X}")
                if cls == 0x01:
                    cname += "-" + NAV_ID_NAMES.get(mid, f"{mid:02X}")
                else:
                    cname += f"-{mid:02X}"
                parts.append(f"{cname}x{v}")
            lines.append("UBX:  " + ", ".join(parts))
        else:
            lines.append("UBX:  none")
        if self.last_navsol is not None:
            fx, nsv = self.last_navsol
            lines.append(f"NAV-SOL: gpsFix={GPSFIX_NAMES.get(fx, fx)} numSV={nsv}")
        if self.last_gga is not None:
            fq, nsv = self.last_gga
            lines.append(f"GGA: fix-quality={fq} numSV={nsv}")
        return "\n".join(lines)

    def have_fix(self):
        if self.last_navsol and self.last_navsol[0] in (2, 3, 4):
            return True
        if self.last_gga and self.last_gga[0] > 0:
            return True
        return False


def listen(fd, seconds, label=""):
    p = StreamParser()
    end = time.monotonic() + seconds
    while True:
        left = end - time.monotonic()
        if left <= 0:
            break
        r, _, _ = select.select([fd], [], [], min(left, 1.0))
        if r:
            p.feed(os.read(fd, 4096))
    if label:
        print(f"--- {label} ({seconds:.0f}s) ---")
    print(p.summary())
    return p


def send_and_ack(fd, frame, want_cls, want_mid, note, ack_timeout=1.0):
    os.write(fd, frame)
    p = StreamParser()
    end = time.monotonic() + ack_timeout
    while time.monotonic() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            p.feed(os.read(fd, 4096))
        for ok, cls, mid in p.acks:
            if (cls, mid) == (want_cls, want_mid):
                print(f"  {note}: {'ACK' if ok else 'NAK!'}")
                return ok
    print(f"  {note}: no ACK (continuing — some ATGM firmware builds do not ACK)")
    return None


def cmd_status(fd, seconds):
    listen(fd, seconds, f"port status: {DEV}")


def cmd_enable_nmea(fd):
    print("Enabling NMEA output at 1 Hz on UART1 (UBX-CFG-MSG, volatile RAM config):")
    for name, mid in NMEA_MSGS.items():
        frame = ubx_frame(0x06, 0x01, bytes([0xF0, mid, 0x01]))
        send_and_ack(fd, frame, 0x06, 0x01, f"CFG-MSG {name} rate=1")


UBX_NAV_MSGS = {
    "POSECEF": 0x01,
    "DOP": 0x04,
    "SOL": 0x06,
    "VELECEF": 0x11,
    "TIMEGPS": 0x20,
}


def cmd_disable_ubx(fd):
    print("Disabling UBX NAV output (UBX-CFG-MSG rate=0), returning to pure NMEA:")
    for name, mid in UBX_NAV_MSGS.items():
        frame = ubx_frame(0x06, 0x01, bytes([0x01, mid, 0x00]))
        send_and_ack(fd, frame, 0x06, 0x01, f"CFG-MSG NAV-{name} rate=0")


def cmd_cold_start(fd):
    print("Cold-starting GNSS (UBX-CFG-RST clear-all BBR, GNSS-only restart):")
    frame = ubx_frame(0x06, 0x04, b"\xff\xff\x02\x00")
    send_and_ack(fd, frame, 0x06, 0x04, "CFG-RST cold-start", ack_timeout=0.5)


def cmd_save(fd):
    print("Saving msgConf to BBR+flash (UBX-CFG-CFG):")
    # clearMask=0, saveMask=msgConf(0x0002), loadMask=0, devMask=BBR|flash(0x03)
    payload = (0).to_bytes(4, "little") + (0x0002).to_bytes(4, "little") \
        + (0).to_bytes(4, "little") + bytes([0x03])
    ok = send_and_ack(fd, ubx_frame(0x06, 0x09, payload), 0x06, 0x09,
                      "CFG-CFG save msgConf")
    if ok is False:
        print("  NAK received — flash save refused; config will persist only "
              "while V_BCKP holds. A boot-time re-send is then required.")


def cmd_fix(fd, save, timeout):
    cmd_enable_nmea(fd)
    cmd_cold_start(fd)
    print(f"Watching for a fix (up to {timeout}s; cold TTFF is typically 30-60s "
          "with a good sky view)...")
    p = StreamParser()
    end = time.monotonic() + timeout
    last_print = 0
    while time.monotonic() < end:
        r, _, _ = select.select([fd], [], [], 1.0)
        if r:
            p.feed(os.read(fd, 4096))
        now = time.monotonic()
        if p.have_fix():
            print(f"\nFIX acquired after {int(timeout - (end - now))}s:")
            print(p.summary())
            if save:
                cmd_save(fd)
            return 0
        if now - last_print >= 10:
            state = p.last_navsol or p.last_gga
            print(f"  [{int(timeout - (end - now)):4d}s] still no fix "
                  f"(last state: {state})")
            last_print = now
    print(f"\nNo fix after {timeout}s:")
    print(p.summary())
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("status", help="listen and classify traffic")
    sp.add_argument("seconds", type=float, nargs="?", default=5)
    sub.add_parser("enable-nmea", help="enable NMEA sentences at 1 Hz")
    sub.add_parser("disable-ubx", help="disable UBX NAV output (pure NMEA)")
    sub.add_parser("cold-start", help="cold-start the GNSS engine")
    sub.add_parser("save", help="save msg config to BBR+flash")
    sp = sub.add_parser("fix", help="enable-nmea + cold-start + wait for fix")
    sp.add_argument("--save", action="store_true",
                    help="save msg config to flash once a fix is acquired")
    sp.add_argument("--timeout", type=float, default=180)
    args = ap.parse_args()

    fd = open_port()
    drain(fd, 0.2)  # drop partial frames
    if args.cmd == "status":
        cmd_status(fd, args.seconds)
        rc = 0
    elif args.cmd == "enable-nmea":
        cmd_enable_nmea(fd)
        rc = 0
    elif args.cmd == "disable-ubx":
        cmd_disable_ubx(fd)
        rc = 0
    elif args.cmd == "cold-start":
        cmd_cold_start(fd)
        rc = 0
    elif args.cmd == "save":
        cmd_save(fd)
        rc = 0
    elif args.cmd == "fix":
        rc = cmd_fix(fd, args.save, args.timeout)
    os.close(fd)
    return rc


if __name__ == "__main__":
    sys.exit(main())
