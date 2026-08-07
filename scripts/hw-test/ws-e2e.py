#!/usr/bin/env python3
"""Minimal KiwiSDR/Web-888 websocket E2E probe (no external deps).

Protocol quirks handled (verified against work/websdr-src):
  - Server sends MSG frames with BINARY opcode (not text opcode).
  - SND: rx params are only accepted after "MSG audio_init=..." arrives.
  - Client must send "SET keepalive" every ~5 s or the server kicks the conn.

Verifies:
  1. WS handshake on /kiwi/<ts>/SND and /kiwi/<ts>/W/F
  2. Server MSG init frames (rx_chans, audio_init)
  3. Real binary audio frames (SND) and waterfall frames (W/F)

Exit 0 only if both streams deliver real data.
"""
import base64
import os
import socket
import struct
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "web888.local"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8073


def ws_connect(path, timeout=10):
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {HOST}:{PORT}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    s.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = s.recv(4096)
        if not chunk:
            raise RuntimeError("handshake: connection closed")
        resp += chunk
    status = resp.split(b"\r\n", 1)[0].decode()
    if "101" not in status:
        raise RuntimeError(f"handshake failed: {status}")
    return s


def ws_send_text(s, msg):
    payload = msg.encode()
    header = bytearray([0x81])  # FIN + text
    n = len(payload)
    if n < 126:
        header.append(0x80 | n)
    elif n < 65536:
        header.append(0x80 | 126)
        header += struct.pack(">H", n)
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", n)
    mask = os.urandom(4)
    header += mask
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    s.sendall(bytes(header) + masked)


def _recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise RuntimeError("connection closed mid-frame")
        buf += chunk
    return buf


def ws_recv_frame(s):
    b1, b2 = _recv_exact(s, 2)
    opcode = b1 & 0x0F
    n = b2 & 0x7F
    if n == 126:
        (n,) = struct.unpack(">H", _recv_exact(s, 2))
    elif n == 127:
        (n,) = struct.unpack(">Q", _recv_exact(s, 8))
    data = _recv_exact(s, n)
    return opcode, data


def probe(kind, params, ready_marker, want_tag, need_frames=5, duration=15):
    s = ws_connect(f"/kiwi/{int(time.time() * 1000)}/{kind}")
    ws_send_text(s, "SET auth t=kiwi p=#")
    s.settimeout(3)
    msgs = set()
    sent = False
    frames = 0
    nbytes = 0
    last_ka = time.time()
    deadline = time.time() + 20 + duration
    try:
        while time.time() < deadline and frames < need_frames:
            now = time.time()
            if now - last_ka > 4:
                ws_send_text(s, "SET keepalive")
                last_ka = now
            try:
                opcode, data = ws_recv_frame(s)
            except socket.timeout:
                continue
            if opcode == 8:
                raise RuntimeError(f"{kind}: server closed connection")
            if data[:4] == b"MSG ":
                txt = data.decode(errors="replace")
                parts = txt.split()
                if len(parts) > 1:
                    msgs.add(parts[1].split("=")[0].split(",")[0])
                if not sent and ready_marker in txt:
                    for m in params:
                        ws_send_text(s, m)
                        time.sleep(0.15)
                    sent = True
            elif data[:3] == want_tag:
                frames += 1
                nbytes += len(data)
    finally:
        s.close()
    return sorted(msgs), sent, frames, nbytes


failures = []

# --- audio stream: params accepted only after audio_init ---
got, sent, frames, nbytes = probe(
    "SND",
    ["SET mod=am low_cut=-4000 high_cut=4000 freq=14200.0",
     "SET compression=0",
     "SET agc=1 hang=0 thresh=-100 slope=6 decay=1000 manGain=50",
     "SET AR OK in=12000 out=12000"],
    "audio_init",
    b"SND",
)
print(f"SND: init_msgs={got} params_sent={sent} audio_frames={frames} bytes={nbytes}")
if not sent or frames == 0:
    failures.append("SND stream: no audio frames")

# --- waterfall stream ---
got, sent, frames, nbytes = probe(
    "W/F",
    ["SET zoom=0 start=0",
     "SET maxdb=-10 mindb=-110",
     "SET wf_speed=1",
     "SET wf_comp=1"],
    "cfg_loaded",
    b"W/F",
)
print(f"W/F: wf_frames={frames} bytes={nbytes}")
if frames == 0:
    failures.append("W/F stream: no waterfall frames")

if failures:
    print("E2E FAIL:", "; ".join(failures))
    sys.exit(1)
print("E2E_OK")
