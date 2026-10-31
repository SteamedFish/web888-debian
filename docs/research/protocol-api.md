# Web-888 WebSocket Protocol & API Reference

> **Trust level:** AI-generated reverse-engineering material, consolidated from
> the former `websocket-protocol.md` and `api-reference.md`. The exact command
> names below were **not** reconciled against source (the source is in the
> upstream RaspSDR/server repo, not vendored here) — see the
> [§ command-name divergences](#command-name-divergences-unresolved) warning.
> Verify against `rx/rx_cmd.cpp` + `web/kiwi/kiwi.js` before relying on a
> specific spelling.

The Web-888 (RaspSDR, a KiwiSDR fork) talks to the browser over WebSocket on
port **8073**. Client→server text messages are `SET <cmd>`; server→client text
messages are `MSG <type>=<data>`; audio/waterfall are binary frames.

## Streams

The client opens multiple concurrent WebSocket streams:

```cpp
// from rx_cmd.h
typedef enum {
    STREAM_SOUND = 0,      // audio (SND)
    STREAM_WATERFALL = 1,  // spectrum (WF)
    STREAM_ADMIN = 2,      // administrative control
    STREAM_EXT = 3,        // extensions
    STREAM_MONITOR = 4,    // monitoring/debug
    STREAM_MFG = 5         // manufacturing test
} stream_t;
```

A normal user connection opens the SND stream first, authenticates, then opens
the WF stream. Admin/mfg connections use a different open path. Auth is
enforced server-side: until authenticated, only `keepalive`, `options`, and
`auth` commands are accepted (everything else is kicked, per `rx_cmd.cpp`).

## Connection & authentication

### Authentication

```
SET auth t=<type> p=<password> [ipl=<time_limit_exempt_password>]
```
- `t`: `kiwi` (user: tune/listen), `prot` (protected features), `admin`
- `p`: password (hashed client-side)
- Response: `MSG badp=<code>` (0 = OK)

**Bad-password codes (from `kiwi.js`)** — note the two docs disagreed on the
exact code names/values; treat as indicative, verify in source:

| Code | Meaning (indicative) |
|------|----------------------|
| 0 | OK |
| 1 | wrong password (try again) |
| 2 | server still determining local IP |
| 3 | IP not allowed |
| 4 | no admin password set |
| 5 | duplicate IP not allowed |
| 6 | DX database update in progress |
| 7 | admin connection already open |

### Keepalive
```
SET keepalive   →   MSG keepalive      # sent every ~5 s; prevents timeout
```

## Receiver control

### Frequency
```
SET freq=<frequency_hz>            # e.g. SET freq=14074000
```
Range: ~10 kHz – 150 MHz (HF 0–62 MHz, VHF 118–150 MHz).

### Mode
```
SET mod=<mode>      (or  SET mode=<mode>   — see divergence note)
```
Modes: `am amn usb usn lsb lsn cw cwn nbfm nnfm iq drm sam sau sal sas qam`.

### Bandwidth / passband
```
SET pbw=<low>,<high>     (or  SET bw=<bandwidth_hz>   — see divergence note)
# e.g. SET pbw=300,2700  (SSB), SET pbw=100,5000 (wide AM), SET pbw=400,900 (CW)
```

### AGC / mute / volume / squelch / record
| Command | Example | Notes |
|---|---|---|
| `SET agc=<mode>` | `agc=slow` | off/slow/med/fast, or hang-time ms (5/10/25/50/100) |
| `SET mute=<0\|1>` | `mute=1` | mute/unmute |
| `SET volume=<0-100>` | `volume=75` | audio volume % |
| `SET squelch=<0-100>` | `squelch=50` | 0 = off |
| `SET record=<0\|1>` | `record=1` | start/stop recording |

## Display (waterfall)

| Command | Example | Notes |
|---|---|---|
| `SET zoom=<0-14>` | `zoom=0` | 0 = widest (62 MHz HF / 32 MHz VHF) |
| `SET max_dB=<db>` (or `maxdb=`) | `max_dB=-30` | waterfall top dB |
| `SET min_dB=<db>` (or `mindb=`) | `min_dB=-130` | waterfall bottom dB |

## Configuration & status

| Command | Purpose |
|---|---|
| `SET save_cfg c=<json>` | save main config |
| `SET save_adm=<json>` | save admin config |
| `SET save_dxcfg=<json>` | save DX config |
| `SET GET_CONFIG` → `MSG config=<json>` | fetch config |
| `SET reload_cfg` | reload config from file |
| `SET need_status_msg` → `MSG status=<json>` | request status |
| `SET STATS_UPD` → `MSG stats=<json>` | statistics |
| `SET GET_USERS` | list connected users |

### DX (station) database
```
SET GET_DX                              → large JSON array of station markers
SET DX_UPD g=<id> f=<freq> lo=<low> hi=<high> o=<offset> s=<sig_bw> \
           fl=<flags> b=<begin> e=<end> i=<ident>x n=<notes>x p=<params>x
SET DX_FILTER i=<ident> n=<notes> c=<case> w=<wildcard> g=<grep>
```

## Extensions

```
SET ext=<name>            # open extension
SET ext=<name> <command>  # extension command
SET ext=                  # close current extension
MSG ext=<name> <data>     # extension message back
```
Built-in extensions: ALE_2G, ant_switch, CW_decoder, CW_skimmer, DRM, FAX,
FFT, FSK, FT8, HFDL, IBP_scan, IQ_display, Loran_C, NAVTEX, S_meter, SSTV,
TDoA, waterfall, WSPR, noise_blank, noise_filter, colormap, digi_modes, timecode.

## MSG response catalog

| MSG | Example |
|---|---|
| `version=<maj>.<min>` | `version=1.780` |
| `freq=<hz>` | `freq=14074000` |
| `mode=<mode>` | `mode=USB` |
| `audio_init` / `audio_delete` | audio stream start/stop |
| `audio_rate=<hz>` | `audio_rate=12000` |
| `wf_rate=<fps>` | `wf_rate=30` |
| `zoom=<level> max=<max>` | `zoom=5 max=14` |
| `status=<json>` | `status={"users":4,"gps":"locked"}` |
| `gps=<status>` | `gps=locked lat=.. lon=..` |
| `ext=<name> <data>` | `ext=FT8 decode:CQ ...` |
| `error=<message>` | `error=bad frequency` |

## Binary frames

### Audio (ADPCM)
Uncompressed: 16-bit PCM @ 12/24/36 kHz. Compressed: 4-bit ADPCM (4:1).

Frame layout — **the two source docs disagreed**; verify in `rx_cmd.cpp`:
- variant A: `[1 byte flags][2 bytes seq][N bytes ADPCM]`
- variant B: `[1 byte type=0x01][N bytes ADPCM]`

ADPCM decode (IMA-style, indicative):
```javascript
function decodeADPCM(data) {
    const stepTable = [/* 89 step sizes */];
    const indexTable = [-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8];
    let predictor = 0, stepIndex = 0; const samples = [];
    for (let i = 0; i < data.length; i++) {
        const byte = data[i];
        for (let n = 0; n < 2; n++) {
            const nibble = (byte >> (n * 4)) & 0x0F;
            let diff = stepTable[stepIndex] >> 3;
            if (nibble & 4) diff += stepTable[stepIndex];
            if (nibble & 2) diff += stepTable[stepIndex] >> 1;
            if (nibble & 1) diff += stepTable[stepIndex] >> 2;
            if (nibble & 8) diff = -diff;
            predictor = Math.max(-32768, Math.min(32767, predictor + diff));
            samples.push(predictor);
            stepIndex = Math.max(0, Math.min(88, stepIndex + indexTable[nibble & 7]));
        }
    }
    return samples;
}
```

### Waterfall (FFT)
8-bit unsigned magnitude values (0–255 → min_dB..max_dB, non-linear). Frame
layout also diverged between the docs:
- variant A: `[2 bytes freq][1 byte zoom][N bytes magnitude]`
- variant B: `[1 byte type=0x02][4 bytes seq][N bytes FFT magnitude]`

## Protocol constants

| Constant | Value |
|---|---|
| Keepalive interval | 5 s |
| Inactivity timeout | 60 s |
| `MAX_WF_BYTES` | 16384 |
| `MAX_SND_BYTES` | 4096 |
| `MAX_CMD_LEN` | 1024 |

## Rate limits (indicative)

| Operation | Limit |
|---|---|
| Frequency changes | 20/s |
| Mode changes | 5/s |
| Commands | 100/s |
| Connection time | 24 h (configurable) |

## Minimal client example (Python)

```python
import websocket, struct

class Web888Client:
    def __init__(self, host, port=8073):
        self.ws = websocket.create_connection(f"ws://{host}:{port}/kiwi/1")  # endpoint: see divergence note
        self.send("SET auth t=kiwi p=#")           # p=# = local/no-password placeholder
    def send(self, m): self.ws.send(m)
    def set_freq(self, hz): self.send(f"SET freq={hz}")
    def recv(self):
        data = self.ws.recv()
        if isinstance(data, str): return ("text", data)
        return ("binary", data[0], data[1:])        # frame type byte + payload
```

## Command-name divergences (unresolved)

The two source docs this was merged from disagreed on several spellings. They
were **not** reconciled against source (the upstream `RaspSDR/server` source is
not vendored here). Before relying on any of these, check `rx/rx_cmd.cpp` and
`web/kiwi/kiwi.js`:

| What | Variant A (`websocket-protocol`) | Variant B (`api-reference`) |
|---|---|---|
| WebSocket endpoint path | `/kiwi/1` | `/kiwi/ws` |
| Mode command | `SET mod=<mode>` | `SET mode=<mode>` |
| Bandwidth command | `SET pbw=<low>,<high>` | `SET bw=<hz>` |
| Waterfall dB command | `SET max_dB=` / `min_dB=` | `SET maxdb=` / `mindb=` |
| Audio frame layout | `[flags][2 seq][adpcm]` | `[type=0x01][adpcm]` |
| BADP code naming | BADP_TRY_AGAIN etc. | `bad`/`no_pwd`/`already_open` strings |

The KiwiSDR lineage (this is a KiwiSDR fork) historically uses `mod=`/`pbw=`/
`max_dB=`/`/kiwi/<n>`, which leans toward variant A — but **verify**, do not
assume.

## References

- WebSocket RFC 6455
- `rx/rx_cmd.cpp`, `rx/rx_server.cpp` — server command processing
- `web/kiwi/kiwi.js` — client implementation
- [`web-interface-architecture.md`](web-interface-architecture.md) — frontend
- [`extension-api-guide.md`](extension-api-guide.md) — extension C/C++ API
