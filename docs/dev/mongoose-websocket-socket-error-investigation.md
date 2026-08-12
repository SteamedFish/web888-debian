# Mongoose WebSocket "socket error 2" (EPOLLERR) — investigation

**Status**: FIXED locally as cherry-pick 0148
(`config/websdr/cherry-picks/0148-mongoose-epollerr-graceful-close.patch`) —
the option-(b) fix below was implemented 2026-08-11. No upstream fix exists
to cherry-pick (still true as of mongoose master).
**Date**: 2026-08-07 (fix implemented 2026-08-11)
**Scope**: Web-888 `/admin` websocket drop ~0.5 s after connect, logged as
`mongoose.cpp:1364:mg_error ... socket error 2`.

## Symptom

On the Web-888 Debian image, the WebSDR `/admin` websocket connection is
dropped ~0.5 s after connect. The WebSDR log shows:

```
mongoose 1364:mg_error ... socket error 2
```

`mg_error()` is defined at amalgam `mongoose.cpp:1364` and logs
`conn-id, fd, message` (`%lu %ld %s`), so the message is the third field.

## Root cause (code-traced)

The string `"socket error 2"` is **not** an upstream mongoose string. It is
a Web-888-local diagnostic rename introduced by cherry-pick
`config/websdr/cherry-picks/0144-kiwi-mongoose-7.14-upgrade.patch`, which
renamed the four plain upstream `mg_error(c, "socket error")` sites to
numbered variants so the failing path can be identified in logs:

| # | Patch line | Upstream function | Branch | Amalgam line |
|---|---|---|---|---|
| 1 | 10283 | `connect_conn()` | `getpeername()` failure | 7538 |
| 2 | 10454 | `mg_iotest()` | epoll `EPOLLERR` | 7697 |
| 3 | 10500 | `mg_iotest()` | poll `POLLERR` | 7743 |
| 4 | 10550 | `mg_iotest()` | select `FD_ISSET(&eset)` | 7788 |

The logged `socket error 2` therefore means: **epoll reported `EPOLLERR`
for the connection's socket** in `mg_iotest()`:

```c
// amalgam mongoose.cpp L7697 (Kiwi 7.14 import)
if (evs[i].events & EPOLLERR) {
  mg_error(c, "socket error 2");
}
```

`EPOLLERR` on a connected TCP socket means the socket has a pending error
condition (e.g. `ECONNRESET`, `EPIPE`, or a half-open peer that closed
abruptly). The ~0.5 s timing after connect is consistent with the peer
(admin browser) closing the websocket, or a keepalive/read timeout on the
WebSDR side, rather than a mongoose bug.

## Upstream status — no fix exists to cherry-pick

- **mongoose 7.14** (the version Kiwi imported) and **mongoose master**
  both contain the same four plain `mg_error(c, "socket error")` sites —
  there is no upstream change that fixes or rewords this path.
- **mongoose issues** reviewed: #2874 (heartbeat/monitoring, closed) and
  #2302 (6.x download speed) are unrelated to the EPOLLERR drop.
- **KiwiSDR history** (`jks-prv/Beagle_SDR_GPS`, path
  `pkgs/mongoose/mongoose`): the 7.14 import is commit `028687c`
  "mongoose 7.14 support" (2024-06-13); a later revert `105abb56`
  "v1.693 (revert to v1.690)" (2024-07-16) exists but its content was not
  diffed in this investigation — treat its impact on mongoose.cpp as
  unverified.

## Conclusion

The drop is a Web-888-local behavioural observation, not a mongoose bug
with an upstream fix. The numbered strings are local diagnostics only.

## Recommended local fix (option b — IMPLEMENTED as 0148)

If the drop is confirmed to be a graceful client close (admin page
navigated away / closed), the epoll path should treat `EPOLLHUP`/graceful
close as non-fatal instead of hard-closing with `mg_error("socket error 2")`.
Precedent: `pkgs/sdrpp_server/sdrpp_server.cpp` L606 reads `SO_ERROR` via
`getsockopt()` before deciding to hard-close. Only real socket errors
should hard-close.

Implemented 2026-08-11 as
`config/websdr/cherry-picks/0148-mongoose-epollerr-graceful-close.patch`
(operator opt-in given; QEMU + hardware smoke gate owed before release):
the epoll branch reads `SO_ERROR` via `getsockopt()` first; only a real
pending error takes the `mg_error` path, a clean `SO_ERROR` falls through
to the readable/HUP handling so the connection closes quietly.

## References

- `config/websdr/cherry-picks/0144-kiwi-mongoose-7.14-upgrade.patch`
- `work/websdr-src/pkgs/mongoose/mongoose.cpp` (Kiwi 7.14 amalgam)
- `pkgs/sdrpp_server/sdrpp_server.cpp` L606 (SO_ERROR precedent)
- Upstream: `raw.githubusercontent.com/cesanta/mongoose/master/src/sock.c`
