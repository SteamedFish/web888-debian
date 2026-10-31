#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""web888d WebSocket (protocol 2) independent-consumer data-path check.

Connects to web888d's /ws endpoint and proves real end-to-end data flow
through an unmodified stock-ABI consumer: RFC 6455 handshake, protocol-2
text control messages (hello/state/lease) and binary audio/waterfall
streams, using only the Python standard library (for the guest's python3).

Wire facts implemented here were written fresh from the pinned upstream
references (attribution, not copied code):
  - jeskko/web888-ng v0.6.0, commit 48e9914aac80e3f20c39838fe9b33193b6b3fb36
    - crates/web/src/proto.rs   (message shapes, binary frame layouts)
    - crates/web/tests/session.rs (session flow: hello -> state -> lease
      -> binary audio/waterfall after a narrowing {"type":"wf",...})
  Cross-checked against the local work/upstream/web888-ng checkout.

Binary little-endian layouts (proto.rs):
  audio kind 1: <BBHII f  = kind,flags,n,seq,rate,rssi_db  (16 bytes) + 2*n PCM16
  wf     kind 2: <BBHI d d f f d = kind,flags,bins,seq,first_hz,bin_hz,
                 db0,db_step,time_ms (40 bytes) + bins u8 levels

Scope note: a PASS here validates the data path of an independent
stock-ABI consumer under whatever backend serves it. Under QEMU this is
the PL model — NOT hardware verification and NOT a web888d product
integration claim.  --check-model-tone additionally asserts the QEMU
model's deterministic tone (backend zynqsdr, strongest WF bin within one
bin of 10 MHz, df == 117.1875 Hz); do not use it against the sim backend.

Usage: python3 web888d-ws-check.py [--host H] [--port P] [--timeout S]
          [--check-model-tone]
Exit 0 and "web888d WebSocket data path: PASS ..." only if every check
holds; exit 1 with a FAIL line otherwise.
"""
import argparse
import base64
import hashlib
import json
import math
import os
import socket
import struct
import sys
import time

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

KIND_AUDIO = 1
KIND_WF = 2
FLAG_OVERLOAD = 1
FLAG_GAP = 2
FLAG_STEREO = 4          # audio: two interleaved channels
FLAG_NEW_GEN = 2         # wf: first line of a new tuning/zoom
FLAG_STALE = 4           # wf: repeated line, no new samples

AUDIO_HDR = struct.Struct("<BBHII f")            # 16 bytes
WF_HDR = struct.Struct("<BBHI d d f f d")        # 40 bytes

CENTER_HZ = 10_000_000.0
# 122.88 MHz ADC / decim 4096 / 256 FFT bins = 117.1875 Hz per bin.
MODEL_DF_HZ = 117.1875


class CheckError(Exception):
    pass


def log(msg):
    print(msg, flush=True)


# ------------------------------------------------------------ websocket I/O
class WS:
    """Minimal RFC 6455 client: masked client frames, unmasked server
    frames, ping->pong, close handshake, fragmented message reassembly."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def _read(self, n, deadline):
        while len(self.buf) < n:
            left = deadline - time.time()
            if left <= 0:
                raise CheckError("timeout waiting for server data")
            self.sock.settimeout(max(0.1, left))
            chunk = self.sock.recv(65536)
            if not chunk:
                raise CheckError("server closed the connection")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _recv_frame(self, deadline):
        h = self._read(2, deadline)
        fin, op = h[0] & 0x80, h[0] & 0x0F
        masked, ln = h[1] & 0x80, h[1] & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", self._read(2, deadline))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", self._read(8, deadline))[0]
        mask = self._read(4, deadline) if masked else None
        payload = self._read(ln, deadline) if ln else b""
        if masked:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return fin, op, payload

    def send_frame(self, op, payload=b""):
        mask = os.urandom(4)  # client -> server frames MUST be masked
        header = bytes([0x80 | op])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def send_text(self, obj):
        self.send_frame(1, json.dumps(obj).encode())

    def send_close(self):
        try:
            self.send_frame(8, struct.pack(">H", 1000))
        except OSError:
            pass

    def recv_msg(self, deadline):
        """Returns ('text'|'binary'|'closed', payload), answering ping
        frames with pongs and completing fragmented messages."""
        parts, first_op = [], None
        while True:
            fin, op, payload = self._recv_frame(deadline)
            if op == 0x9:                       # ping -> pong
                self.send_frame(0xA, payload)
                continue
            if op == 0xA:                       # pong: ignore
                continue
            if op == 0x8:                       # close
                return "closed", payload
            if op in (0x1, 0x2):                # text / binary
                if first_op is not None:
                    raise CheckError("new message before fragmented one finished")
                first_op = op
                parts = [payload]
            elif op == 0x0:                     # continuation
                if first_op is None:
                    raise CheckError("continuation frame outside a message")
                parts.append(payload)
            else:
                raise CheckError(f"unexpected opcode {op}")
            if fin:
                op = "text" if first_op == 0x1 else "binary"
                return op, b"".join(parts)


def ws_handshake(host, port, timeout):
    """GET /ws upgrade; require 101 and a matching Sec-WebSocket-Accept."""
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
    except OSError as e:
        raise CheckError(f"cannot connect to {host}:{port}: {e}")
    sock.settimeout(timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET /ws HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    ).encode()
    sock.sendall(req)
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            raise CheckError("connection closed during WebSocket handshake")
        resp += chunk
        if len(resp) > 65536:
            raise CheckError("handshake response too large")
    status = resp.split(b"\r\n", 1)[0].decode(errors="replace")
    fields = {}
    for line in resp.split(b"\r\n")[1:]:
        if b":" in line:
            k, v = line.split(b":", 1)
            fields[k.strip().lower()] = v.strip()
    if " 101" not in status:
        raise CheckError(f"handshake: expected 101, got '{status}'")
    accept = fields.get(b"sec-websocket-accept", b"").decode(errors="replace")
    want = base64.b64encode(
        hashlib.sha1((key + WS_GUID).encode()).digest()
    ).decode()
    if accept != want:
        raise CheckError(
            f"handshake: bad Sec-WebSocket-Accept '{accept}' != '{want}'"
        )
    ws = WS(sock)
    rest = resp.split(b"\r\n\r\n", 1)[1]
    if rest:  # any bytes after the header belong to the first frame
        ws.buf = rest
    return ws


# ------------------------------------------------------------------- checks
def seq_ok(prev, cur):
    if prev is None:
        return True
    if cur > prev:
        return True
    return prev - cur > 2**31  # u32 wrap-around


def run(args):
    deadline = time.time() + args.timeout
    ws = ws_handshake(args.host, args.port, min(10, args.timeout))

    # Client hello: protocol 2, PCM16 codec only.
    ws.send_text({"type": "hello", "proto": 2, "codecs": ["pcm16"]})
    # Immediately narrow the waterfall: the default decim=2 full view spans
    # the whole ADC and would overload TCG; 4096 x 256 bins = 7.68 MHz view.
    ws.send_text(
        {
            "type": "wf",
            "center_hz": CENTER_HZ,
            "decim": 4096,
            "bins": 256,
            "fps": 2,
        }
    )

    got_hello = got_state = lease_granted = False
    backend = None
    audio_frames = []          # (seq, rate, n, rssi)
    wf_narrow = []             # (first_hz, bin_hz, bins, levels, flags)
    saw_ping = False
    grace_end = None           # set once minimum evidence is collected

    def minimum_met():
        return (
            got_hello and got_state and lease_granted
            and len(audio_frames) >= 2 and len(wf_narrow) >= 1
        )

    while True:
        left = deadline - time.time()
        if left <= 0:
            raise CheckError(
                f"deadline exceeded: hello={got_hello} state={got_state} "
                f"lease={lease_granted} audio={len(audio_frames)} "
                f"wf_narrow={len(wf_narrow)}"
            )
        if grace_end is not None and time.time() > grace_end:
            break  # minimum evidence collected and grace period expired
        kind, payload = ws.recv_msg(deadline)
        if kind == "closed":
            break
        if kind == "text":
            try:
                msg = json.loads(payload.decode())
            except (UnicodeDecodeError, ValueError) as e:
                raise CheckError(f"bad text frame: {e}: {payload[:80]!r}")
            mtype = msg.get("type")
            if mtype == "hello":
                got_hello = True
                if msg.get("proto") != 2:
                    raise CheckError(f"hello proto != 2: {msg}")
                if msg.get("audio_rate") != 12000:
                    raise CheckError(f"hello audio_rate != 12000: {msg}")
                radio = msg.get("radio") or {}
                backend = radio.get("backend")
                if args.check_model_tone and backend != "zynqsdr":
                    raise CheckError(
                        f"model-tone check requires the zynqsdr backend, "
                        f"got {backend!r}"
                    )
            elif mtype == "state":
                got_state = True
            elif mtype == "lease":
                if not msg.get("granted"):
                    raise CheckError(f"lease not granted: {msg}")
                lease_granted = True
            elif mtype == "pong":
                saw_ping = True
            elif mtype in ("error", "busy"):
                raise CheckError(f"server sent {mtype}: {msg}")
            continue
        # binary frame
        if len(payload) < 1:
            raise CheckError("empty binary frame")
        frame_kind = payload[0]
        if frame_kind == KIND_AUDIO:
            if len(payload) < AUDIO_HDR.size:
                raise CheckError("short audio frame")
            k, flags, n, seq, rate, rssi = AUDIO_HDR.unpack(
                payload[: AUDIO_HDR.size]
            )
            if len(payload) != AUDIO_HDR.size + 2 * n:
                raise CheckError(
                    f"audio length mismatch: {len(payload)} != "
                    f"16 + 2*{n} (flags={flags})"
                )
            if flags & FLAG_STEREO:
                n //= 2  # count is of samples, both channels'
            if n <= 0:
                raise CheckError("audio frame with no samples")
            if rate != 12000:
                raise CheckError(f"audio rate != 12000: {rate}")
            if not math.isfinite(rssi):
                raise CheckError(f"non-finite audio rssi: {rssi}")
            audio_frames.append((seq, rate, n, rssi))
        elif frame_kind == KIND_WF:
            if len(payload) < WF_HDR.size:
                raise CheckError("short wf frame")
            vals = WF_HDR.unpack(payload[: WF_HDR.size])
            k, flags, bins, seq, first_hz, bin_hz, db0, db_step, t_ms = vals
            if len(payload) != WF_HDR.size + bins:
                raise CheckError(
                    f"wf length mismatch: {len(payload)} != 40 + {bins}"
                )
            if bins <= 0 or bin_hz <= 0 or db_step <= 0:
                raise CheckError(
                    f"degenerate wf frame: bins={bins} df={bin_hz} "
                    f"db_step={db_step}"
                )
            levels = payload[WF_HDR.size:]
            if not flags & FLAG_STALE and bins == 256:
                wf_narrow.append(
                    (first_hz, bin_hz, bins, bytes(levels), flags)
                )
        else:
            log(f"note: ignoring unknown binary kind {frame_kind}")
        if grace_end is None and minimum_met():
            grace_end = time.time() + 3  # collect a few more lines, then stop

    # One app-level ping/pong round on the way out, then a clean close.
    try:
        ws.sock.settimeout(3)
        ws.send_text({"type": "ping", "t": time.time()})
        end = time.time() + 3
        while time.time() < end and not saw_ping:
            kind, payload = ws.recv_msg(end)
            if kind != "text":
                continue
            try:
                m = json.loads(payload.decode())
                if m.get("type") == "pong":
                    saw_ping = True
            except (UnicodeDecodeError, ValueError):
                pass
    except (CheckError, OSError):
        pass
    ws.send_close()
    try:
        end = time.time() + 5
        while time.time() < end:
            kind, _ = ws.recv_msg(end)
            if kind == "closed":
                break
    except (CheckError, OSError):
        pass
    try:
        ws.sock.close()
    except OSError:
        pass

    # ---- aggregate assertions
    if not (got_hello and got_state and lease_granted):
        raise CheckError(
            f"missing control messages: hello={got_hello} "
            f"state={got_state} lease={lease_granted}"
        )
    if len(audio_frames) < 2:
        raise CheckError(f"only {len(audio_frames)} audio frames (< 2)")
    for (a, b) in zip(audio_frames, audio_frames[1:]):
        if not seq_ok(a[0], b[0]):
            raise CheckError(f"audio seq not increasing: {a[0]} -> {b[0]}")
    if len(wf_narrow) < 1:
        raise CheckError("no valid narrow waterfall line (256 bins)")

    model_note = ""
    if args.check_model_tone:
        # Deterministic model tone at 10 MHz: the strongest narrow-view bin
        # must sit within one bin of the centre, at df == 117.1875 Hz. Stale
        # and default full-view frames were already excluded above.
        first_hz, bin_hz, bins, levels, flags = max(
            wf_narrow, key=lambda f: max(f[3])
        )
        peak_hz = first_hz + max(range(bins), key=lambda i: levels[i]) * bin_hz
        err_bins = abs(peak_hz - CENTER_HZ) / bin_hz
        if abs(bin_hz - MODEL_DF_HZ) > 1.0:
            raise CheckError(f"model wf df != {MODEL_DF_HZ}: {bin_hz}")
        if err_bins > 1.0:
            raise CheckError(
                f"model tone peak {peak_hz} Hz is {err_bins:.2f} bins "
                f"from centre {CENTER_HZ} (first_hz={first_hz}, "
                f"df={bin_hz})"
            )
        log(
            f"model tone: peak {peak_hz:.0f} Hz ({err_bins:.2f} bins from "
            f"10 MHz centre, df={bin_hz:.0f} Hz)"
        )
        model_note = " (QEMU model, not hardware)"

    log(
        f"stream summary: backend={backend} audio_frames={len(audio_frames)} "
        f"(n={audio_frames[0][2]}, rate={audio_frames[0][1]}, "
        f"seq {audio_frames[0][0]}..{audio_frames[-1][0]}) "
        f"wf_narrow={len(wf_narrow)} pong={saw_ping}"
    )
    log(f"web888d WebSocket data path: PASS{model_note}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8073)
    ap.add_argument(
        "--timeout", type=int, default=180,
        help="outer time bound in seconds (default 180)",
    )
    ap.add_argument(
        "--check-model-tone",
        action="store_true",
        help="assert the QEMU model tone: zynqsdr backend, df=117.1875 Hz, "
        "strongest narrow-view WF bin within 1 bin of 10 MHz",
    )
    args = ap.parse_args()
    try:
        run(args)
    except CheckError as e:
        log(f"web888d WebSocket data path: FAIL: {e}")
        sys.exit(1)
    except (OSError, struct.error) as e:
        log(f"web888d WebSocket data path: FAIL: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
