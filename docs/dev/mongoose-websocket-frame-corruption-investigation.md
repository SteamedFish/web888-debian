# Mongoose websocket frame corruption (lost send-path locking) — investigation

**Status**: ROOT CAUSE IDENTIFIED — fix pending (see "Fix directions").
**Date**: 2026-08-13
**Scope**: probabilistic `/admin` websocket disconnects on web888-websdr
2026.807-1 (mongoose 7.14 web layer, first deployed to hardware with the
2026-08-12 upgrade from 2026.806-1).

Companion document:
[`mongoose-websocket-socket-error-investigation.md`](mongoose-websocket-socket-error-investigation.md)
(cherry-pick 0148) — the `socket error 2` drop analysed there is a
**downstream symptom** of the corruption documented here; see
"Relationship to 0148" below.

## Symptom

User report (2026-08-13): the `/admin` page probabilistically disconnects
immediately after opening, and clicking some buttons (e.g. the log button)
also probabilistically drops the connection. All browsers affected,
non-deterministic ("有概率…非必现").

Server log pattern (`journalctl -u web888-websdr`): a *new* admin connection
is authenticated and allowed, then closed within ~0.3–0.5 s, while an older
admin connection from the same client keeps streaming normally:

```
[01] PWD admin ALLOWED: no config pwd set, but is_local
[01] PWD admin admin ALLOWED: from 192.168.45.31
c149f27 1 mongoose.cpp:1364:mg_error    897 9 socket error 2   (occasionally)
[01] ADMIN connection closed
```

Browser console pattern (reproduced via Playwright):

```
WebSocket connection to 'ws://192.168.29.57:8073/kiwi/…/admin' failed:
Received unexpected continuation frame.    @ kiwi_util.js:2111
################ admin_close ################   @ admin.js:4492
WebSocket connection … failed: Invalid frame header   (reconnect attempt)
```

## Reproduction

`scripts/test-websocket-frames.py` — opens 3 concurrent admin websockets
(each streaming `SET xfer_stats` every 0.5 s, mimicking live admin tabs)
plus a churn thread that opens/closes a short-lived admin connection every
2 s (mimicking reconnect churn), and validates RFC 6455 framing
byte-by-byte on every connection.

- **Corruption reproduced in 2 of 6 runs**, ~5 s after the connect burst,
  always at byte offset **64097 = the boundary immediately after the
  47821-byte `load_dxcfg` frame**.
- A single quiet connection: 16 frames / 90 s, **always clean** → the
  corruption is concurrency-dependent, not data-dependent.
- The websocket handshake carries no `Sec-WebSocket-Extensions` →
  permessage-deflate bugs are ruled out.

## Wire evidence

Two corruption shapes at the same offset (raw captures in
`.tmp/ws_stress.log`, `.tmp/ws_stress_run2.log` — gitignored):

1. The next frame's 2-byte header is **zeroed** (`00 00`).
2. The previous frame's declared length is **4 bytes short**; the next
   frame's 4-byte extended header is **zeroed** (`00 00 00 00`); its
   payload (`MSG load_dxcfg=...`) follows headerless.

Both shapes are byte-level interleaves of two independent frame writes
racing a concurrent buffer-consume (`memmove`) on the same send buffer —
i.e. a **server-side send-path race**, not network corruption. The server
then closes the remaining connections ~18–30 s later (matches the
`ADMIN connection closed` + occasional `socket error 2` log lines).

## Root cause

### Kiwi threading model (unchanged by the 7.14 upgrade)

From the 0144 patch's own web_server.cpp comment: `app_to_web(buf)` queues
stream data via `nbuf_allocq(&c->s2c)`, flushed only by the `web_server`
task's `MG_EV_POLL` handler. But **`send_msg*()` — "server demand push of
websocket message data (no need to use nbufs)" — calls `mg_ws_send()`
directly from whatever task/thread is running** (command task, admin task,
extension callbacks). `web_server()` is the only task running
`mg_mgr_poll()`; everything else sends concurrently.

### Old mongoose: serialized, frame-atomic

`work/websdr-src/pkgs/mongoose/mongoose.cpp` (pre-0144, build tree):

```c
static lock_t mongoose_lock;                    // L362
size_t mg_websocket_write(struct mg_connection *conn, int opcode,
                          const char *data, size_t data_len) {
    lock_holder holder(mongoose_lock);          // L3140 — whole-frame buffer, single write
```

The same lock is taken by `iobuf_resize` (L369), `iobuf_free` (L385),
`iobuf_append` (L393), `iobuf_remove` (L421), `ns_out` (L429) and
`ns_write_to_socket` (L1070). Cross-thread sends were therefore serialized
at whole-frame atomicity.

### 0144 upgrade: locking deleted, send split into two unlocked appends

`config/websdr/cherry-picks/0144-kiwi-mongoose-7.14-upgrade.patch`:

- **Deletes `mongoose_lock` and every `lock_holder holder(mongoose_lock)`**
  (patch deletion lines 1135, 1153, 1180, 1191, 1240, 1254). No
  replacement synchronization is added anywhere — mongoose 7.x is
  documented single-threaded.
- New `mg_ws_send()` (patch line 19653) does **two separate unlocked
  `mg_send()` iobuf appends** — header, then payload — plus `mg_ws_mask`:

```c
size_t mg_ws_send(struct mg_connection *c, const void *buf, size_t len, int op) {
    uint8_t header[14];
    size_t header_len = mkhdr(len, op, c->is_client, header);
    mg_send(c, header, header_len);   // append #1
    mg_send(c, buf, len);             // append #2
    mg_ws_mask(c, len);
    return header_len + len;
}
```

- Meanwhile the `web_server` task's `MG_EV_POLL` handler concurrently does
  the socket write and `mg_iobuf_del()` on the same `c->send` iobuf
  (patch lines 28190–28245).

→ A `send_msg*()` issued from any non-webserver thread while the poll
handler is mid-flush interleaves its header/payload appends with the
consume path (`write` + `memmove` + possible `realloc`), producing exactly
the observed zeroed-header / 4-byte-misaligned corruption. The 47 KB
`load_dxcfg` frame (extended 4-byte header + large memcpy) widens the race
window, which is why the corruption lands at its trailing boundary.

### Why it is probabilistic

Three conditions must coincide: (a) 2+ admin connections (or reconnect
churn) active, (b) a `send_msg` push from a non-webserver thread (the
periodic per-second stats pushes), (c) a poll flush of a large frame in
progress. Browser cache/timing differences shift the timing — hence
"every browser, sometimes" and "not always reproducible".

## Full failure chain (explains all observed symptoms)

1. Concurrent admin connections → `send_msg*()` (command/admin task)
   interleaves with the poll flush (web task) → malformed frame emitted.
2. Browser receives it → RFC 6455 protocol error → kills the websocket
   (`Received unexpected continuation frame` / `Invalid frame header` →
   `admin_close`), usually with a RST.
3. Server epoll reports `EPOLLERR` → `mongoose.cpp:1364:mg_error …
   socket error 2` (the numbered diagnostic introduced by 0144 itself).
4. Connection kicked → `ADMIN connection closed` ~0.3–0.5 s after
   `PWD admin ALLOWED`.
5. Kiwi JS auto-reconnects → the cycle repeats probabilistically.

The `ADMIN: unknown command: <SET xfer_stats>` / `<ADM antsw_GetCurrentAnt>`
spam seen in the same logs is unrelated frontend/backend version skew
(0145 resynced admin.js against newer Kiwi), not part of the failure chain.

## Relationship to 0148 (previous "socket error 2" investigation)

`mongoose-websocket-socket-error-investigation.md` treated the ~0.5 s drop
as a client-initiated graceful close and patched only the close/logging
behaviour (0148, SO_ERROR pre-check). Wire capture now shows **why** the
client closes: it receives malformed frames and kills the connection per
RFC 6455. `socket error 2` is a downstream symptom of this corruption;
0148 remains correct as a close/logging fix but does not address the
corruption itself.

## Deployment timeline

- 0144 existed in the packaging tree by 2026-08-07 (analysed by the 0148
  investigation) but the device ran 2026.806-1 until **2026-08-12
  20:14:44**, when `apt upgrade` installed **2026.807-1** — the first
  hardware deploy of the 7.14 web layer plus the 0145 admin resync.
- User symptoms date from after that upgrade. The running server
  self-reports `version_maj=2026 version_min=812` in the post-auth banner.

## Fix directions (NOT implemented — this task was investigation only)

1. **Route all websocket sends through the `s2c` nbuf queue** — make
   `send_msg*()` enqueue instead of calling `mg_ws_send()` directly, and
   let only the web_server task touch `c->send`. This is the architecture
   the queue was built for and the smallest semantic change; admin stats
   pushes are preserved (flushed on the next poll tick).
2. **Reintroduce locking** around `mg_ws_send()`/`mg_ws_wrap()` vs the
   poll write+consume path. 7.14 has no lock hook, so this would be a
   local divergence from the upstream amalgam.
3. **Upstream-style single-threaded dispatch** (`mg_wakeup`-based
   cross-thread posts) — the cleanest layering, but the largest change.

## Evidence index

- `scripts/test-websocket-frames.py` — reproducer / frame validator
  (exit 1 on corruption).
- `.tmp/ws_stress.log`, `.tmp/ws_stress_run2.log` — raw corruption
  captures (gitignored scratch).
- 0144 patch (`config/websdr/cherry-picks/0144-kiwi-mongoose-7.14-upgrade.patch`):
  `mg_ws_send` L19653; `mg_ws_wrap` L19834; poll flush handler
  L28190–28245; threading-model comment L28090–28133; `send_msg_mc` body
  swap L25740–25758; `mongoose_lock` deletions L1135/1153/1180/1191/1240/1254;
  numbered `socket error` diagnostics (epoll branch) L10453.
- Old mongoose (build tree): `work/websdr-src/pkgs/mongoose/mongoose.cpp`
  L362 (`mongoose_lock`), L3140 (`mg_websocket_write`).
- `rx_server_send_config()` (the ~107 KB config burst: load_cfg,
  load_dxcfg, load_dxcomm_cfg, load_adm): `work/websdr-src/rx/rx_util.cpp:452`.
- `ADMIN connection closed` log: `work/websdr-src/ui/admin.cpp:1207`.

## Open questions

- Stress runs 3–6 showed no corruption but the server closed all three
  main connections ~30 s in, right after the config burst — most likely
  the reproducer not sending Kiwi keepalive messages (a real browser
  does). Confirm when verifying the eventual fix.
- Whether non-admin (sound/waterfall) connections are equally exposed in
  practice — the mechanism applies to any `send_msg*()` caller, but their
  push frequency is much lower.
