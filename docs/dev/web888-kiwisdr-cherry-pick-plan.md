# KiwiSDR → Web-888 Cherry-Pick Plan (comprehensive)

> **Scope:** a commit-level plan to port changes from the KiwiSDR upstream lineage
> (`jks-prv/Beagle_SDR_GPS` → `jks-prv/KiwiSDR`) into the Web-888 / RaspSDR server
> (`RaspSDR/server`). Compiled by analysing the **full** history of all
> three repos (not just the recent 184-commit window the first pass looked at).

## The fork topology (this is the key fact the first plan got wrong)

```
jks-prv/Beagle_SDR_GPS  (5299 commits, 2015→2024-12)   ← TRUE upstream
        │
        ├── 2024-02-22 ── Web-888 imports a snapshot (commit 740ad75, "import server software")
        │                 as a SINGLE commit (1375 files). NOT a git fork — no merge-base.
        │                 Rewrites platform/+verilog/+pru/ → zynq/ (kernel driver), CMake,
        │                 hardware GPS (gpsd). Continues independently → 68a64e1b (568 commits).
        │
        └── 2024-11-10 ── jks-prv/KiwiSDR rebases out of Beagle_SDR_GPS into a new repo
                          (754 commits). Same lineage, new home. → c40ecb4 (= v1.902).
```

**Implication:** the "184 commits since the old comparison doc" was the wrong denominator.
Web-888 diverged from Beagle_SDR_GPS around **2024-02-22** — so the real upstream delta is
**everything Beagle_SDR_GPS/KiwiSDR changed from 2024-02-22 to now** (~2.5 years), not just
the last 6 months.

## How portability was assessed

For every commit touching the **62 files that exist in BOTH Web-888 and KiwiSDR and have
diverged** (the shared surface), the analysis checked:
1. Does each touched file exist in Web-888 at the same path? (`git cat-file -e websdr/master:<path>`)
2. Does the surrounding code context match? (`git show websdr/master:<path>`)
3. Are referenced symbols/macros present in Web-888?

The 62 shared-and-changed files break down as: **48 C++ backend** (rx/CuteSDR, rx/wdsp,
rx/Teensy, support/*, ui/admin.cpp, net/*), **12 web/ JS/data**, **2 misc**. The portable
concentration is the C++ backend + pure data files; the web/ frontend is deeply divergent.

### The recurring blockers (why so many commits are RED)

1. **`support/coroutines.cpp` was rewritten in Web-888** — 439 lines (POSIX `clock_gettime`
   deadlines, `TaskDump` is a `// TODO` stub) vs KiwiSDR's 2100 lines (`timer_us64()`/u64
   deadlines, full task dump). → *Every commit touching coroutines.cpp is RED.*
2. **The SPI/misc_miso layer is absent** — Web-888's kernel driver replaces it. `get_misc_miso`,
   `SPI_SHMEM`, `ecpu_use`, `spi_get_noduplex` don't exist. → *commits touching
   support/misc.cpp's SPI layer are RED.*
3. **`web/kiwi/` frontend is an independent, older layout** — no `id-admin-top`,
   `w3_inline_noencl`, `WIN_WIDTH_NOM`, `kiwi.time_display_width`. → *mobile/narrow-screen
   UI commits are RED.*
4. **SNR subsystem** — Web-888 has the older API in `rx/rx_util.cpp` (`SNR_calc(meas, type,
   int, int)`), KiwiSDR moved it to `rx/rx_snr.cpp` with a new API (`zoom`, `filter`, VDSL).
5. **`kiwi_str_clean` clean_table** — Web-888's is a hardcoded char-replace loop with no
   `KCLEAN_*` mechanism. → *the KCLEAN chain is RED without backporting the base.*
6. **kiwisdr.com-specific infra** — `my_kiwi_register`, `proxy.kiwisdr.com`, `FRPC_PROXY_UPD`,
   kiwirecorder/TDoA exemptions, `my.kiwisdr.com` hostname. Web-888 uses `rx-888.com`. →
   *that whole registration/proxy cluster is RED.*

---

## The cherry-pick candidates, by tier

### Tier 0 — Already done / already present (verify only)

| Commit | What | Status |
|--------|------|--------|
| `6f210319` | IP parse security (`inet4_d2h_strict`, `is_valid_ipv6_strict`, `isLocal_ip` error) | ✅ **Applied as patch 0104** |
| `c3b4c06` | remove CHU (data files) | ✅ **Applied as patch 0101** |
| `34f7728a` | `SEC_TO_USEC()` u64 fix | ✅ **Already in Web-888** (`timing.h:30` has `1000000LL`) |
| `d2371762` | `TaskWakeupF()` migration | ✅ **Already in Web-888** (`admin.cpp:387,1032`) |

### Tier 1 — GREEN (clean ports, do these next)

| Commit | What | Files | Notes |
|--------|------|-------|-------|
| `f296750d` | add `KSPLIT_PARSE_NUMERIC` to `kiwi_split()` | support/str.{cpp,h} | Additive enum+field, backward-compatible; `kiwi_split` body matches |
| `c14821d6` | copyright URL rename (holmea.demon→aholme.co) | 5 of 36 files apply | Trivial string replace: `_COPYRIGHT`, coroutines.{cpp,h}, timing.{cpp,h} |
| `f26a4dff` (types.h part) | `CLAMP_TO` macro | types.h | 1-line additive macro; **take only the types.h hunk**, skip admin.html/js (divergent) |
| `520a56c1` (types.h part) | `RANGE()` macro | types.h | 1-line additive macro; **take only the types.h hunk**, skip cfg.cpp (absent) |

### Tier 2 — YELLOW, self-contained (single function / small adaptation)

| Commit | What | Adaptation needed |
|--------|------|-------------------|
| `33a3e6ba` | `kiwi_str_ASCII_static()` fixed-length bufs | Add 3rd defaulted `len` param; same loop body exists in Web-888; backward-compatible |
| `e1480d0e` | `kiwi_fmt_usec()` | Self-contained fn (uses `asprintf`); insert manually near Web-888's `kiwi_str_clean` (context differs) |
| `1896689f` | `kiwi_nonEmptyStrRemNL()` | Web-888 lacks BOTH `kiwi_nonEmptyStr()` AND the `RemNL` variant — add both (base fn is small) |
| `086a9be4` | FT8 freq-sort checkbox | Port `decode_ft8_freq_sort()` into Web-888's `ft8_lib/decode_ft8.cpp` (.cpp not .c); FT8.{cpp,h} + types.h match |
| `ed30b89d` (minimal) | split `ansi.h` out of `bits.h` | Create `ansi.h` (31 lines, verbatim); strip the 9 color `#define`s from Web-888 `bits.h:132-140`; add `#include "ansi.h"` only where needed. **SKIP** the wire/reg typedef rewrite & absent files |
| `5e6a78e0` (selective) | simplify `#include` to reduce recompilation | Build-only refactor; Web-888 CuteSDR headers DO have `#include "kiwi.h"` (removable). Apply selectively; watch the I/Q/RX_CHAN0/CUTESDR_SCALE block |
| `f90d8ca5` | symmetrical FIR taps | `fir.{cpp,h}` + `FIR_COEFF_SYMMETRICAL` ports cleanly; **deemph table layout differs** (1-D vs 2-D) → manual `rx_filter.h`/`rx_sound_cmd.cpp` adaptation |

### Tier 3 — YELLOW, foundational (must precede related commits)

| Commit | What | Why foundational |
|--------|------|------------------|
| **`37f65b4b`** | **security: admin password == serial-number detection** | Adds `serno`/`admin_advisory` to `kiwi_t`; ports `admin_pwd_unsafe()` into security.cpp; the `net.cpp` hunk builds on patch 0104 (which is in the series). **Highest single security value.** Unblocks `5780bda4`. |
| `a58529d1` | `inet4_d_valid()` + `inet4_h2s()` improve | Builds on 0104's `inet4_d2h_strict`; adapt `inet4_h2s` to Web-888's signature (`u4_t` only, no `which`) |
| `cfea79e6` | better logging for bad-API bots | `ctprintf()` is clean; add `snd_cmd_recv`/`wf_cmd_recv` to `conn.h`; adapt `rx_server.cpp` |
| `575736bd` (1st hunk) | show IP for denied connections | Port only the fingerprint-1 hunk (`stats.cpp`); format differs (`TRIG=%d`); skip fingerprint-2 (absent) |
| `5971255c` | reject default lat/lon | `rx_gps` cfg exists; **add** `gps_isValid()` whole function (absent) |
| `e783fccd` | rx8wf2 preempt only if public | Add `isPublic` to `kiwi_t`; adapt `rx_server.cpp` (no `&preempt` arg in Web-888) |
| `10c68822` | `non_blocking_cmd_func_foreach` improvements | Extend `nbcmd_args_t` (add `cmd_poll_msec`/`cmd_stat`); update all callback callers in Web-888 |
| `d0075ae7` | small API changes/bug fixes | Move `debug_v` to `shmem->debug_v`/`debug_v_set` (add to shmem.h); JS w3 changes extensive (assess separately) |
| `5780bda4` | popup warn admin pwd=serno | **Blocked on `37f65b4b`** (needs `kiwi.serno`/`admin_advisory`/`SM_ADMIN_ALL`) |

### Tier 4 — RED (not portable as cherry-picks; needs reimplementation or is N/A)

| Commit | Why RED |
|--------|---------|
| `64f94da9` 8-channel (rx8wf8) | FPGA bitstream + verilog/e_cpu/platform; rx/support C++ not separable |
| `a5d7300e` rx_snr.{cpp,h} + VDSL | API rewrite of SNR (Web-888 has older API in rx_util.cpp) |
| `ee25ecc4`, `79883fdd` SNR fixes | Depend on `a5d7300e` |
| `de658478` FASTFIR_OUTBUF_SIZE | Beagle SPI word-budget math (NRX_SAMPS_CHANS); kernel-driver based in Web-888 |
| `25b2b3b0`, `616a3742` KCLEAN fixes | `clean_table`/KCLEAN architecture absent in Web-888 |
| `31eb6295` arch/platform cleanup | 95% platform/arch (absent) |
| `42a8f98e` TaskSleep child | `taskSleepCommon` absent (Web-888 coroutines rewrite) |
| `3218ed72` get_misc_miso | SPI-miso layer absent (kernel driver) |
| `5ae5e8f1` dump_direct | rx_util dump structure differs + coroutines call site absent |
| `a972e978` non_blocking SD-card cmd | substantive change in `ui/kiwi_ui.cpp` (absent) |
| `1f7c848b` rename itask→snd_itask | coroutines TaskDump regions absent |
| `096c0375` TaskDump deadlines | Web-888 TaskDump is a `// TODO` stub |
| `93d540b6` domain_check fix | `domain_check` absent (rx-888.com API) |
| `bb2f88fe`, `ea689934`, `9e1cc5d1`, `fe95ae07`, `0e30918b`, `e9781983` proxy/my.kiwisdr.com/MTU | kiwisdr.com proxy + my.kiwisdr.com + MTU infra absent |
| `92036924`, `b6ec9e69` kiwirecorder/TDoA exemptions | need kiwisdr.com DNS + isLocal_ip 5th param |
| `796e45b4`, `f26a4dff`(UI), `5780bda4`-without-base | divergent admin.js / my.kiwisdr.com subsystem |
| `51c9110e` rx_in_HFDL_bands refactor | nothing to refactor (HFDL fingerprint logic absent) |
| `82743138` antsw exclude autorun | ant_switch backend stripped in Web-888 |
| `a0296aa1`, `8e6e5265` + all gps/ | software-GPS engine (e_cpu/verilog/GNSS-SDRLIB) absent; Web-888 uses gpsd |
| mobile/narrow-screen UI (`b7baae9`,`2ac60e5`,`09418b3`,`c8f839c`,`53328ae`) | `w3_inline_noencl`/`WIN_WIDTH_NOM`/`kiwi.time_display_width` infra absent |
| client-side FFT (`b1e0c84`..`f8f8fc7`) | FFT.js 645→2004 lines; needs the missing mobile-infra base |
| ALE guard `c472a26` | `ALE_2G_environment_changed` is a different, simpler function in Web-888 |
| SNR kick `ef22aeb` | `rx_snr.cpp` absent; logic in `rx_util.cpp` differs (reimplementable but not a cherry-pick) |

---

## Recommended execution order

**Batch A (Tier 1 — trivial greens, ~30 min):**
`c14821d6`, `f26a4dff`(types.h), `520a56c1`(types.h), `f296750d` → one commit each, low risk.

**Batch B (Tier 2 — self-contained yellow, ~2-3 hrs):**
`1896689f`, `33a3e6ba`, `e1480d0e`, `ed30b89d`(minimal), `5e6a78e0`(selective), `086a9be4`, `f90d8ca5`.

**Batch C (Tier 3 — foundational, do `37f65b4b` first):**
`37f65b4b` → then `5780bda4`, `a58529d1`, `cfea79e6`, `575736bd`, `5971255c`, `e783fccd`, `10c68822`, `d0075ae7`.

**Batch D (Tier 4 — not cherry-picks):** documented as dropped. If any feature is wanted
(SNR improvements, mobile UI, client-side FFT, 8-channel), it must be a Web-888-native
reimplementation or feature port, tracked separately.

---

## Second-pass deep survey: beyond the 62 shared files

> **Motivation:** the first pass surveyed only the **62 files that exist in both trees
> and have diverged** — i.e. it could only find *modifications to shared code*. It could
> not see (a) whole features Kiwi added in new files/areas, (b) features whose Web-888
> side was deleted or never existed, or (c) library/vendoring upgrades. This second pass
> read the **entire KiwiSDR CHANGE_LOG v1.664 → v1.902** (the true fork delta) and
> cross-checked every entry against the live Web-888 tree (`68a64e1`). Every claim below
> was verified by grep/diff against both trees.

### What the first pass missed — headline findings

1. **Web-888 runs Mongoose 5.6; Kiwi upgraded to Mongoose 7.14** (v1.818, Aug 2025).
   Verified: `pkgs/mongoose/mongoose.h` — `MONGOOSE_VERSION "5.6"` vs `MG_VERSION "7.14"`.
   This is the single largest hidden divergence. Kiwi upgraded to fix a real bug
   (dropped proxy headers) and it now gates several other features (FSK UDP output,
   multi-admin autokick, backward-compat ws URLs). **Not in the first plan at all.**
2. **Web-888's frontend still uses browser cookies; Kiwi migrated to localStorage**
   (v1.666) saving ~1 kB per HTTP request. Verified: Web-888 `kiwi_util.js` still has
   `createCookie()/writeCookie()`; `localStorage` appears only twice in `kiwi.js`.
3. **Web-888's admin.js (3329 lines) vs Kiwi's (5875 lines)** — virtually the entire
   v1.666→v1.902 admin feature set is absent (verified by keyword survey below).
4. **Web-888's ant_switch is the old 291-line extension; Kiwi's is a 775-line
   integrated subsystem** (`pkgs/ant_switch/` + frontend/backend shell scripts) with
   ~2.5 years of features Web-888 lacks.
5. **Web-888 still has the PSKReporter fragmentation bug** Kiwi fixed in v1.800:
   `PR_BUF_LEN 2048` vs Kiwi's `1190` (per dchristle PR #928).
6. **Reverse direction already happened:** Kiwi's `c2d81a1c` "perf improvements from
   raspsdr" — upstream is absorbing Web-888's work. Web-888 is *ahead* in: FT8 OSD
   decoding + per-CPU tuning, variable rx rates (12/24/36 kHz) + FT8 at non-12 kHz,
   faster waterfall, shared-mode zoom 11, wspr 8m band, FT8 5m (60074), CTC.

### A. New small candidates found (not in the first-pass tables)

| Commit / version | What | Files (Web-888 side) | Verdict |
|---|---|---|---|
| v1.800 (dchristle) | **PSKReporter fragmentation fix** — `PR_BUF_LEN 2048→1190` | `extensions/FT8/PSKReporter.cpp` (1 line) | **GREEN** — Web-888 confirmed still at 2048 |
| v1.695/1.700 | **FT8 V/UHF + QO-100 freqs** (144174, 222065, 432174, 1296174, 10489540 + FT4 144150) | `extensions/FT8/FT8.cpp` freq table + `web/extensions/FT8/FT8.js` menu | **GREEN** (data only; keep Web-888's own 8m/5m entries) |
| v1.900-era | **WSPR QO-100 band** (10489569.5, band 24) | `extensions/wspr/wspr_main.cpp` `wspr_cfs[]` + JS menu | **GREEN** (data only) |
| v1.806 | **SSTV R36-BW mode + Robot B/W fixes** — the only SSTV modes Web-888 lacks | `extensions/SSTV/sstv_modespec.cpp` | **GREEN** — everything else from v1.803/805 already ported by Web-888 (`037a57c`) |
| v1.830 `188a45fd` | **DX labels: sort by freq+mode** (adjacent-label overlap fix) | dx label sort in `web/kiwi/kiwi.js` | **YELLOW** — small JS fix in divergent file; verify Web-888's sort fn first |
| v1.838 | **WSPR "upload spots" checkbox actually stops uploading** | `extensions/wspr/wspr_main.cpp` | **YELLOW** — Web-888's `_upload_task` is the old `(rx_chan, kstr)` signature; port logic not shmem plumbing |
| v1.843 | **WSPR "clear" button clears log without stopping processing** | `wspr_main.cpp` + `wspr.js` | **DONE → 0139** (minimal: dropped `wspr_reset()`/`wspr_test_cb` from `wspr_clear_cb`; full `kiwi_output_chars` console rework c2487091+bfdfc728 deferred — 9 exts + kiwi.js) |
| v1.801/1.703 `MODE_FLAGS_SCAN` | **scan-mode flag** — `SET tune=freq,scan`; scanning no longer resets the inactivity timer / steals UI focus | `rx/rx_sound.h`, `rx/rx_sound_cmd.cpp` (~10 lines) + ALE_2G `SET tune=%lf,%d` | **YELLOW** — Web-888 has only `MODE_FLAGS_SAM` (verified); self-contained in shared-lineage rx_sound_cmd |
| v1.816/817 | **"(connecting)" placeholder** in user lists while a channel authenticates | `rx/rx_util.cpp` (Kiwi line 1077) | **DONE → 0135** (583cbf15) |
| v1.804 | **"Disable user connections" also stops autoruns** | `rx/rx_util.cpp` / admin control path | **DONE → 0136** (a131d4db adapted: `down` guard in ft8/wspr_autorun_start + KICK_USERS→KICK_ALL) |
| v1.806 | **DRM may kick preemptable (autorun) channels to start** | `extensions/DRM/DRM.cpp` | **DONE → 0137** (c9a7881b adapted: drm_max_rx rename, heavy-excludes-preemptable, `rx_autorun_kick_all_preemptable()`, victim_conn, FT8/WSPR `is_locked` guards; `-nmulti`/admin is_multi_core hunks skipped — no MULTI_CORE in Web-888) |
| v1.837 | **Admin photo upload server-crash fix** | actually `rx/rx_server_ajax.cpp` (a591cddf) | **VERIFIED PRESENT → 0140**: Web-888 prints uninitialized stack `fname` on error paths (rc=1/5) + leaks `current_authkey` when `!isLocalIP`; adapted fix (zero-init arrays, restructured authkey free) |
| v1.682 | **ipset + iptables blacklist filtering** (and the v1.666 lockout elimination it enables) | `net/ip_blacklist.cpp` | **YELLOW** — Web-888 confirmed iptables-shelling only, no `ipset`; self-contained addition, scales to 65k entries vs 512-entry hash |
| v1.843 | **FAX recording rework** — drop the intermediate `.pgm` file scheme (Web-888's own comment admits the fixed filename is an info-leak: any user can download another session's image) | `extensions/FAX/FaxDecoder.cpp` + FAX.js | **YELLOW** — backend deletion + JS recording path; has a genuine security angle |
| v1.694 | **UTF-8 username handling** (admin users tab no longer breaks; correct in logs) | cdde3a7d | **VERIFIED PARTIAL → 0141**: client side already fixed (kiwi.js users-list iterative decodeURIComponent fallback); server side missing `utf8makevalid(ident_user)` in rx_cmd.cpp + non-ASCII log strip in printf.cpp → ported. SKIPPED: ASCII table `\x%2X` cosmetics, kiwi_decodeURIComponent admin.js (no user_list case in Web-888 admin.js) |
| v1.694 | **timecode initial phase correction** (stations sync in all cases) | d2e468cf | **VERIFIED MISSING → 0142**: correction is JS-side (8 files, `ACQ_PHASE` state); Web-888 timecode.js still pre-fix. All 8 JS applied clean; timecode.cpp housekeeping adapted (DIR_SAMPLES/`__UINT64_FMTx__` kept) |

### B. Feature ports worth the investment (NOT cherry-picks), ranked

Ranked by (value to Web-888-on-Debian) / (effort). "Blocked" means gated on another
item in this list.

#### B.1 Mongoose 7.14 upgrade — HIGH value, HIGH effort, **foundational**

Web-888's entire HTTP/WebSocket layer (`web/web_server.cpp`, `web/web.cpp`) is written
against the 2018-era Mongoose 5.6 API. Kiwi upgraded to 7.14 in v1.818 and kept
backward-compat for old non-`/ws`-format URLs in v1.819 (3rd-party apps like
KiwiKonnect). Upgrading unblocks, in one move:

- the **dropped-proxy-header bug** (v1.818 root cause — matters if Web-888 ever fronts
  the server with a reverse proxy / frp, which Debian deployments commonly do),
- **FSK UDP streaming output** (v1.830 — Kiwi's fsk.cpp literally `#warning`s "no UDP
  support for older Mongoose"; verified),
- **multi-admin autokick** reliability fix `28b31980` (uses 7.x `mg_ws_send` CLOSE;
  Web-888 already has the JS side `no_reopen_retry`),
- **DRM RSCI output** (v1.901) and any future UDP-egress features,
- years of upstream WebSocket/TLS bug fixes.

Effort: rewrite `web_server.cpp` glue to the 7.x event API (Kiwi's own 5.6→7.14 port
commits are the template), re-verify SpyServer/HPSDR/MQTT (they have their own sockets,
unaffected), QEMU + hardware test. Risk: medium — the WS protocol is unchanged.

#### B.2 Admin page feature bundle — HIGH value, HIGH effort — **DONE** (strategy (a); patches 0145+0146, hardware-verified)

Web-888's `admin.js` predates v1.666. Verified absent (keyword sweep of Web-888
`admin.js`, all zero hits): **Users tab** (connection history w/ sublists — the main
bot-spotting tool), **top-bar search field**, **keyboard shortcuts + help panel**,
**copy-to-clipboard buttons**, **small-screen support**, **tab-select-in-URL**
(`/admin?dx`), **Debian hostname field**, **lower MTU values**, **power-on restart
delay**, **blacklist subnet guard** (refuses subnets covering LAN/loopback),
**require-name/callsign on connect**, **"show user names to users" privacy toggle
(`(private)`)**, **admin password reset scheme** (v1.803) + **save-pwd-in-localStorage**,
**README/password panel customization**, **geolocated-city display toggle**,
**RF atten startup-preset semantics**, **initial-value menus** (compression/display/
option bar), **bold-fonts mode**, **DX import merge options** ("keep masked", "merge
files"), **custom DX database name**, **3-high DX stacking**.

Strategy choice (must be decided before work): **(a) wholesale re-sync** — take Kiwi's
`admin.js` + `admin.html` + supporting `w3_util.js` wholesale and re-apply Web-888's
customizations (MQTT tab, OTA update tab, rx-888.com registration, VHF/dual-band
config, 13-channel model). Higher short-term cost, but ends the permanent
admin-feature deficit — every future Kiwi admin improvement becomes cherry-pickable
again. **(b) per-feature ports** — pick ~6 highest-value items (Users tab, search,
require-name, private-names, blacklist subnet guard, DX import merge) into Web-888's
layout. Cheaper now, deficit persists. **Recommendation: (a), as a dedicated
milestone, after B.1.** Note the plan's earlier finding stands: the
`id-admin-top`/`w3_inline_noencl` DOM infra must come over with it (i.e. `w3_util.js`
and its CSS must be synced too — Kiwi's `w3_util.js` gained 1662 diff-lines).

#### B.3 User-UI (kiwi.js) feature bundle — MEDIUM value, HIGH effort

Web-888 already has its own **mouse-wheel tune** (`7675524`, incl. persistence + 100 Hz
LSB/USB step) and **passband adjust in the sound panel** (`432bc51`) — so the two
biggest v1.694 UX items are covered (differently). Verified still absent:

- **DX label system upgrades**: day-of-week / time-of-day **scheduling for masked
  labels** (v1.832, `50cd5e68`), **click-hold multi-label frequency menus** (v1.823,
  `b6be7f0f`), label sort-by-mode fix (above), community-db label time/DOW display fix.
- **Spectrum passband marker** (transparent rect on the RF spectrum) + **edge-drag
  passband adjust** (v1.666/1.694) — Web-888 has no `passband_marker` code.
- **AMW (AM wide) mode** (v1.666) — no `AMW` in Web-888 kiwi.js. Note: Web-888's
  variable-rate architecture (24/36 kHz) may make AMW less necessary, or easier.
- **1 Hz frequency readout toggle** (`$` shortcut, v1.666).
- **Mouse-wheel two-speed velocity detection + device presets** (v1.694) — Web-888's
  wheel tune is single-rate; Kiwi's locks to fast rate on quick scrolling.
- **cookies → localStorage migration** (v1.666) — bandwidth + hygiene; touches
  `kiwi_util.js` + every `readCookie` call site (mechanical).
- Small polish: right-click-menu dismiss by clicking anywhere, Esc closes readme
  panel, frequency-memory fixes (ctrl-N no longer re-pushes stack; wrong-mode bug).

Strategy: per-feature ports only. A wholesale kiwi.js re-sync is **not** recommended —
Web-888's user UI has too much of its own value (variable rates, faster waterfall,
openwebrx co-frontend, CTC UI) and Kiwi's mobile/narrow-screen work is entangled with
the `w3_inline_noencl`/`WIN_WIDTH_NOM` infra the first plan already graded RED.

#### B.4 SNR subsystem reimplementation — MEDIUM-HIGH value, MEDIUM effort

The first plan graded the SNR cluster RED (API fork: Web-888 `SNR_calc()` in
`rx_util.cpp` vs Kiwi `rx/rx_snr.cpp`). As a *feature port* this is one of the most
user-visible gaps — SNR shows on the user page and public listing. What a
reimplementation buys (v1.813–1.902): **VDSL/strong-signal filter** (v1.816, later
tuned), **minute-granularity + custom intervals**, **custom band definition**,
**ham/AM-broadcast-band measurements**, **measure-on-antenna-change** (5 s settle),
**kick button** (v1.902, verified working), **`/snr` JSON `ihr`→`imin` + `ant`
field**, works with waterfalls disabled, `ZOOM_CAP` separation. Approach: port Kiwi's
`rx_snr.cpp` wholesale (it is largely self-contained), adapt the scheduler-call sites
to Web-888's pthreads (no coroutine constraints — *easier* than on Kiwi), keep
Web-888's `SNR_calc` callers compiling via a shim until migrated.

#### B.5 Extension-level ports

| Feature | Value | Effort | Notes |
|---|---|---|---|
| **FreeDV** | MED | MED | Kiwi backend is a **235-line stub** (`freedv.cpp`, no codec2 linked) — decoding is client-side via 92 KB `FreeDV.js` loading WASM from **`freedv.kiwisdr.com`** (hosted service; external dependency on jks's infra staying up). Port = stub + JS adaptation + decide whether to self-host the WASM |
| **sig_gen** | LOW-MED | **LOW** | Kiwi-only; 148-line backend injecting RF tone/AF noise into the IQ path via the standard `ext_register_receive_iq_samps` API — **fully portable**; purpose: S-meter calibration / self-test. Web-888's S_meter + attn work makes this genuinely useful |
| **iframe multi-instance** | MED | MED | Kiwi: up to 16 instances, alias menu names, "populate with standard entries" (solar/K-index/propagation/lightning/aurora), iframe-can-tune-Kiwi (DX spots). Web-888: single instance (163-line JS vs Kiwi's 500). Nice dashboard value |
| **Integrated ant_switch** | MED | HIGH | Kiwi's `pkgs/ant_switch` (775 lines + frontend/backend scripts): per-antenna **curl fields** (+ escaping), **ground-when-no-users decoupled from default-antenna**, **queued command delivery**, Kmtronic-2ch / LZ2RR MS-S5A/S6A/S7A / Arduino-Netshield backends, **per-antenna freq-offset + hi-side-injection modes**, **autorun/kiwirecorder exclusion from "users"**, backend init error checking. Web-888's extension already has thunderstorm/denymixing/ground-all. Port piecemeal (curl fields + queued delivery first) or adopt wholesale |
| **FSK UDP streaming** | LOW-MED | LOW *(after B.1)* | `SET udp_text` → `udp_send`, local connections only; use case: external FSK/SYNOP decoders (DF6DBF) |
| **DRM RSCI output** | LOW-MED | MED | dream already carries the RSCI/MDI classes in Web-888's tree; the work is wiring `SET rsci_ip=` + UDP/TCP egress through Web-888's divergent `DRM.cpp` (shmem/yield differences) |
| **TDoA** | MED | HIGH | Web-888 has the JS frontend + a 61-line backend stub. Kiwi's TDoA = JS + kiwirecorder sampling clients + **kiwisdr.com correlation service**. Feasibility hinges on GPS-locked sampling — Web-888's gpsd + hardware PPS is arguably a *better* foundation than Kiwi's software GPS, but the service-side dependency remains |
| **HFDL dep vendoring** | LOW | n/a | Kiwi vendored liquid-dsp + libacars in-tree (36k lines); Web-888 already builds dumphfdl its own way (`externals/dumphfdl` + CMake, `b86c6a5`). Parity — do nothing |

#### B.6 Service / API endpoints

| Feature | Value | Effort | Notes |
|---|---|---|---|
| **`/gps` AJAX/JSON endpoint** (v1.821, local-net only, seq number added later) | MED | LOW-MED | Kiwi reads its software GPS; a Web-888 version would query **gpsd** — reimplementation, not port. Useful for monitoring integrations (N2CWV's use case); `AJAX_GPS` slot confirmed absent in Web-888's `rx_server.cpp` |
| **`/status` params** `sm_cal`, `wf_cal`, `mode=`, `ext_api=` (v1.837/1.838) | LOW | LOW | small additions to the shared-lineage status code |
| **`/s-meter` optional mode param** (`/s-meter?14200usb`, v1.809) | LOW | LOW | |
| **Continuous GPS update of grid/lat/lon** ("marine mobile", v1.694) | LOW-MED | LOW *(verify)* | `WSPR.GPS_update_grid` and `ft8.GPS_update_grid` cfg keys **already exist** in Web-888 (verified) — likely backported by Howard; verify they're actually wired to gpsd updates before scheduling anything |
| **kiwirecorder camp mode server support** (v1.813) | LOW | VERIFY | Web-888 has `force_camp` in `rx_server.cpp`; the v1.813 kiwirecorder-specific changes are unverified either way |

### C. Confirmed parity / not worth pursuing (so nobody re-researches these)

- **FT8 protocol parity**: Web-888 has FT4 (`FT4_BAND_IDX 13`), pskreporter-syslog,
  autorun decode-count display — and is **ahead** (OSD decoder, non-12 kHz operation).
  Remaining FT8 gaps are only the A-table items above.
- **FSK preset menus**: present in Web-888 (JS line 730). Kiwi only adds UDP output.
- **SSTV**: parity except R36-BW.
- **DRM station-schedule sort**: Web-888's `a053b67` "improve DRM sort" ≈ Kiwi's v1.813
  change (likely already ported).
- **CAT interface**: DEPRECATED in both trees; the v1.683 `\r\n` fix is moot.
- **EiBi**: both at A26 (Web-888 regenerates at build time via `eibi_proc`).
- **CW_skimmer**: Web-888 has its own (`587c0d7`, control ported from Kiwi `26f5582`).
- **3-channel-mode fixes** (v1.837 glitching, SSTV-on-3ch, CIC gain 3ch): Kiwi-mode-
  specific; Web-888 deleted the 3ch concept (`794faff`).
- **rx8wf2 autorun preemption tweaks** (`63bb3117`, `e783fccd`, `ea529eca`): Kiwi-mode-
  specific; Web-888's 13-channel model differs. (The first plan's `e783fccd` entry
  should be re-graded RED on this basis.)
- **"Run server without FPGA"** (v1.822), LED failure patterns, manufacturing builds,
  Debian-11-upgrade SD function, binary-update mechanism, EEPROM recovery: Beagle/Kiwi-
  ecosystem only.
- **"expansion interface"** `cbe0330a` (`exp.h`, sound/wf tap for external apps):
  Web-888's SpyServer/HPSDR servers already cover external streaming better.
- **proxy/frpc/my.kiwisdr.com/kiwirecorder-exemption cluster**: still RED (kiwisdr.com
  infra), unchanged from first pass.
- **8-channel mode / CIC-comp FPGA taps / ZOOM_CAP**: FPGA-RTL-gated, still RED —
  Web-888 lacks the Verilog source.
- **`extint_vars()` per-extension config-default mechanism** (`17e83496` et al.):
  Kiwi's config-init refactor; pure housekeeping, no user value.

### D. Dependency graph for the feature ports

```
B.1 Mongoose 7.14 ──► FSK UDP streaming, DRM RSCI, multi-admin autokick,
                      proxy-header robustness, old-ws-URL compat
~~B.2 admin.js re-sync (needs w3_util.js+CSS sync)~~ DONE ──► all future Kiwi admin
                      improvements become cherry-pickable again
B.4 rx_snr.cpp port ──► ZOOM_CAP separation, kick button, /snr JSON v2
B.3 per-feature (independent of B.1/B.2, but shares w3 infra for marker/scheduling)
```

Suggested sequencing: **B.1 → B.2** (one "web stack modernization" milestone),
then **B.4**, then the B.5/B.6 items à la carte alongside the A-table smalls.

## Methodology to keep this current

The patch set + this plan live in `config/websdr/cherry-picks/` with `cherry-picks.manifest`
(status + KiwiSDR commit anchors) and `PROVENANCE.md` (per-patch rationale). Run
`scripts/refresh-cherry-picks.sh` after either upstream advances — it re-resolves each
manifest commit, reports drift, and flags changes RaspSDR may have merged itself. To re-survey
the full delta when KiwiSDR publishes a new version, re-run the shared-file analysis:

```bash
# in the unified repo (.tmp/repos/KiwiSDR with bsg + websdr remotes):
git diff --name-only websdr/master HEAD | …  # the 62 shared-and-changed files
git log --oneline --since=<last-survey-date> -- <shared cpp files>
```

---

*Second-pass plan. Based on Beagle_SDR_GPS (efb38e2), KiwiSDR
(c40ecb4/v1.902 — confirmed still HEAD of origin/master at time of analysis), Web-888
(68a64e1b). First pass: 62 shared-and-changed files surveyed; ~50 commits assessed.
Second pass: full CHANGE_LOG v1.664→v1.902 read + tree-level diffs of extensions/,
web/, pkgs/, rx/ against both live trees.*
