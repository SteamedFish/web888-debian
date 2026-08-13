#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""WebSocket frame-structure validator / corruption reproducer for websdr.bin.

Opens N concurrent admin websockets (each streaming `SET xfer_stats` like a
live admin page) plus a churn thread of short-lived connections (like a page
reconnecting after a drop), and validates RFC 6455 framing byte-by-byte on
every connection. On the first violation it hexdumps the offending bytes and
the preceding context so the corruption can be classified.

Root-cause investigation for docs/dev/mongoose-websocket-frame-corruption-investigation.md:
cherry-pick 0144 removed mongoose's send-path locking, so concurrent
send_msg*() pushes interleave with the web task's poll flush and emit
malformed frames. A single quiet connection is always clean; corruption
requires concurrency.

Usage: test-websocket-frames.py [host [port [duration_s [n_main]]]]
Exit code 0 = no violation observed, 1 = frame corruption detected.
"""
import base64
import os
import socket
import struct
import sys
import threading
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.29.57"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8073
DURATION = int(sys.argv[3]) if len(sys.argv) > 3 else 90
N_MAIN = int(sys.argv[4]) if len(sys.argv) > 4 else 3
CHURN_INTERVAL = 2  # open+close a short-lived conn every N seconds

stop = time.time() + DURATION
lock = threading.Lock()
violations = []


def log(msg):
    with lock:
        print("%s %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def hexdump(b, off=0):
    out = []
    for i in range(0, len(b), 16):
        c = b[i:i + 16]
        out.append("%08x  %-47s  %s" % (off + i, " ".join("%02x" % x for x in c),
                   "".join(chr(x) if 32 <= x < 127 else "." for x in c)))
    return "\n".join(out)


def handshake(path):
    s = socket.create_connection((HOST, PORT), timeout=10)
    s.settimeout(15)
    key = base64.b64encode(os.urandom(16)).decode()
    req = ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
           "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
           "Sec-WebSocket-Version: 13\r\nOrigin: http://%s:%d\r\n\r\n"
           % (path, HOST, PORT, key, HOST, PORT))
    s.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        d = s.recv(4096)
        if not d:
            raise IOError("handshake closed")
        resp += d
    head, rest = resp.split(b"\r\n\r\n", 1)
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        raise IOError("no 101: %r" % head[:80])
    return s, rest


def send_text(s, msg):
    payload = msg.encode()
    hdr = bytearray([0x81])
    ln = len(payload)
    if ln < 126:
        hdr.append(0x80 | ln)
    elif ln < 65536:
        hdr.append(0x80 | 126)
        hdr += struct.pack(">H", ln)
    else:
        hdr.append(0x80 | 127)
        hdr += struct.pack(">Q", ln)
    mask = os.urandom(4)
    hdr += mask
    hdr += bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
    s.sendall(bytes(hdr))


class Reader:
    def __init__(self, s, tag, buf=b""):
        self.s, self.tag, self.buf = s, tag, buf
        self.off = 0
        self.n = 0
        self.frag = None
        self.hist = bytearray()   # ring of last consumed bytes (context before a violation)
        self.prev_hdr = None      # (opcode, fin, len, offset) of previous frame
        self.prev_tail = b""      # last 64 bytes of previous payload

    def need(self, k):
        while len(self.buf) < k:
            d = self.s.recv(k - len(self.buf) + 4096)
            if not d:
                raise EOFError
            self.buf += d
        r, self.buf = self.buf[:k], self.buf[k:]
        self.hist = (self.hist + r)[-256:]
        return r

    def run(self, stats):
        try:
            while time.time() < stop:
                h = self.need(2)
                b1, b2 = h[0], h[1]
                fin, rsv, op = b1 >> 7, (b1 >> 4) & 7, b1 & 0xF
                masked, ln = b2 >> 7, b2 & 0x7F
                ext = b""
                if ln == 126:
                    ext = self.need(2)
                    ln = struct.unpack(">H", ext)[0]
                elif ln == 127:
                    ext = self.need(8)
                    ln = struct.unpack(">Q", ext)[0]
                bad = None
                if rsv:
                    bad = "RSV=0x%x" % rsv
                elif op not in (0, 1, 2, 8, 9, 10):
                    bad = "opcode=0x%x" % op
                elif masked:
                    bad = "masked server frame"
                elif op == 0 and self.frag is None:
                    bad = "unexpected continuation"
                elif op in (1, 2) and self.frag is not None:
                    bad = "new frame mid-fragment"
                elif ln > 16 * 1024 * 1024:
                    bad = "absurd len %d" % ln
                if bad:
                    sample = h + ext + self.need(min(ln, 200))
                    with lock:
                        violations.append((self.tag, self.n, self.off, bad, sample))
                    ctx = bytes(self.hist[: -(2 + len(ext))]) if len(self.hist) > 2 + len(ext) else b""
                    log("!!! [%s] CORRUPTION after %d frames @%d: %s\n"
                        "    prev frame: %s prev payload tail: %r\n"
                        "    -- last %d bytes before violation --\n%s\n"
                        "    -- from violation point --\n%s"
                        % (self.tag, self.n, self.off, bad,
                           self.prev_hdr, self.prev_tail,
                           len(ctx), hexdump(ctx[-128:]) if ctx else "(none)",
                           hexdump(sample)))
                    return
                payload = self.need(ln)
                self.prev_hdr = (op, fin, ln, self.off)
                self.prev_tail = payload[-64:] if ln else b""
                self.n += 1
                self.off += 2 + len(ext) + ln
                if op in (1, 2) and not fin:
                    self.frag = op
                elif op == 0 and fin:
                    self.frag = None
                if stats:
                    send_text(self.s, "SET xfer_stats")
                    time.sleep(0.5)
        except (EOFError, OSError):
            log("[%s] closed by peer after %d frames, %d bytes" % (self.tag, self.n, self.off))
        except socket.timeout:
            log("[%s] idle timeout, %d frames OK" % (self.tag, self.n))


def main_conn(i):
    tag = "main-%d" % i
    s = None
    try:
        s, rest = handshake("/kiwi/%d/admin" % (time.time() * 1000 + i))
        send_text(s, "SET auth t=admin p=")
        log("[%s] connected" % tag)
        Reader(s, tag, rest).run(stats=True)
    except Exception as e:
        log("[%s] error: %s" % (tag, e))
    finally:
        if s is not None:
            try:
                s.close()
            except Exception:
                pass


def churn():
    i = 0
    while time.time() < stop:
        time.sleep(CHURN_INTERVAL)
        i += 1
        tag = "churn-%d" % i
        try:
            s, rest = handshake("/kiwi/%d/admin" % (time.time() * 1000 + 1000 + i))
            send_text(s, "SET auth t=admin p=")
            # read only the initial burst, then close abruptly (like a page that died)
            s.settimeout(3)
            r = Reader(s, tag, rest)
            try:
                end = time.time() + 3
                while time.time() < end:
                    h = r.need(2)
                    ln = h[1] & 0x7F
                    if ln == 126:
                        ln = struct.unpack(">H", r.need(2))[0]
                    elif ln == 127:
                        ln = struct.unpack(">Q", r.need(8))[0]
                    r.need(ln)
            except (EOFError, OSError, socket.timeout):
                pass
            s.close()
        except Exception as e:
            log("[%s] error: %s" % (tag, e))


threads = [threading.Thread(target=main_conn, args=(i,), daemon=True) for i in range(N_MAIN)]
threads.append(threading.Thread(target=churn, daemon=True))
for t in threads:
    t.start()
for t in threads:
    t.join()
log("done. violations=%d" % len(violations))
sys.exit(1 if violations else 0)
