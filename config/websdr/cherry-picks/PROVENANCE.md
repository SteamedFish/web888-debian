# PROVENANCE — KiwiSDR → Web-888 cherry-pick patch set

This directory holds patches ported from **KiwiSDR** (`jks-prv/KiwiSDR`) into the
**Web-888 / RaspSDR server** source tree (`work/websdr-src`, pinned at
`68a64e1b`), applied by `build-websdr-deb.sh` **after** the Debian-adaptation
patches (`config/websdr/patches/0001-0010`).

The quilt series order (both sets, Debian first then cherry-picks) lives in
`config/websdr/debian-patches-series`. The machine-readable summary is
`config/websdr/cherry-picks.manifest`.

> **Reality found during porting (2026-08-01):** Web-888's `web/kiwi/` frontend is
> **far more divergent** from KiwiSDR than the comparison doc implied. Web-888's
> `admin.js` (3329 lines) is an independent, older layout with **none** of
> KiwiSDR's modern `id-admin-top`/`id-admin-scroll`/`w3_inline_noencl`/
> `WIN_WIDTH_NOM` infrastructure. Consequently most UI cherry-picks (mobile,
> narrow-screen, admin) are **not portable** and are recorded as DROPPED below.
> The genuinely shared lineage is the **`net/` layer** and pure **data files**
> (`.cjson`), which is where the applied patches live.

## Applied patches

### 0101-kiwi-remove-chu.patch — REMOVE CHU time station
- **Source:** KiwiSDR `c3b4c06` "remove CHU" (jks-prv, 2026-07-19), part of v1.902.
- **What it does:** removes the "CHU time" frequency menu from
  `web/extensions/FSK/FSK_freq_menus.cjson` and the CHU reference station from
  `web/extensions/TDoA/refs.cjson`.
- **Why:** KiwiSDR dropped CHU from timecode/FSK/TDoA in v1.902; keeps the two
  trees' frequency databases in sync.
- **Portability:** **GREEN** — pure data-file edits, no code, no platform, no
  minification. The only adaptation: line-number context differs from the
  original Kiwi commit (Web-888's `FSK_freq_menus.cjson` lacks a later "updates"
  header line), so hunks were regenerated against the Web-888 file.
- **Verification:** `git apply --check` passes on both the clean tree and the
  tree after Debian patches 0001-0010.

### 0104-kiwi-ip-parse-security.patch — IP address parsing hardening
- **Source:** KiwiSDR `6f21031` "IP address parsing security improvements"
  (jks-prv, 2026-03-05), part of v1.840/841. (An earlier loopback fix `b0f36bc`
  is conceptually folded in — its `inet4_d2h` strictness is subsumed here.)
- **What it does:** adds strict IPv4/IPv6 parsing used by security-sensitive
  paths:
  - new `inet4_d2h_strict()` — rejects trailing junk, validates octet ranges and
    netmask bits, handles `::ffff:` mapped addresses and `a.b.c.d/nm` CIDR;
  - new `is_valid_ipv6_strict()` — `inet_pton` + scanf junk check;
  - `isLocal_ip()` gains an `error` out-param and validates ipv6 strictly.
- **Callers migrated to strict:** `net/ip_blacklist.cpp` (3 sites: add, check,
  get), `isLocal_ip` internal call, `net/net.cpp` `DNS_lookup` (2 sites),
  `ui/admin.cpp` DNS validation, `zynq/leds.cpp` LED IP display.
- **Adaptations from the upstream patch (4 points):**
  1. **Signatures kept `const char*`** (Web-888 standardizes on `const char*`;
     KiwiSDR used `char *`).
  2. **`kiwi_emptyStr()` not used** — Web-888 lacks this helper; replaced with
     `inet4_str == NULL || inet4_str[0] == 0`.
  3. **`ansi.h` color macros removed** — Web-888 has no `ansi.h`/`GREEN`/`RED`/
     `NONL`; warnings use plain `printf`.
  4. **`dev/leds.cpp` → `zynq/leds.cpp`** — the LED IP-display call site was
     relocated to the Web-888 platform directory.
- **Deliberately NOT touched:** `check_if_forwarded()` (KiwiSDR's version has
  `isLocal_ip`/`is_loopback` injection checks; Web-888's version is structurally
  different — simpler, no forwarded-local/loopback logic, different signature —
  so that portion of the upstream patch does not apply and was omitted). The
  `main.cpp` `TEST_IP_PARSE_STRICT` test harness and `support/stats.cpp`
  `#if 0` blocks were also omitted (dead/optional). This keeps the patch focused
  on the live security-sensitive paths.
- **Design choice:** the original non-strict `inet4_d2h()` is **kept intact**
  (not renamed away) so existing non-sensitive callers keep compiling
  unchanged; the strict variants are added alongside. This is a smaller,
  lower-risk surface than KiwiSDR's rename-everything approach.
- **Portability:** **YELLOW (adapted)** — not a verbatim cherry-pick; a hand
  port. `git apply --check` passes clean and after Debian patches. Full compile
  validation awaits the armhf chroot build (`build-websdr-deb.sh`).

## Dropped candidates (evaluated, not portable)

### 0102 — URL encode user & host fields (`1a4a1af`) — DROPPED (RED)
The patch hardens `my_kiwi_register()` and `reg_public()` in `net/services.cpp`
by URL-encoding the `rev_user`/`rev_host` reverse-DNS registration fields.
**Web-888 has none of this code:** its registration path was rewritten to talk
to `www.rx-888.com` via an `/api/update` API that sends `email`+`mac`+`url`
(there is no `my_kiwi_register`, no `rev_user`/`rev_host`/`rev_auto` config).
Web-888 already URL-encodes the `email` field it does send
(`kiwi_str_encode((char*)admin_email)`, `services.cpp:728`), so the underlying
vulnerability class does not apply to the code that exists. Nothing to port.

### 0103 — admin.js narrow-screen top bar (`c8f839c`) — DROPPED (RED)
Rewrites the admin top bar to scroll on narrow screens by restructuring
`id-admin-top`/`id-admin-scroll`/`id-admin-con1`. **Web-888's `admin.js` is a
completely different, older layout** — it has a 3-line `admin_resize()` (just
`log_resize()`+`console_resize()`) and uses `<header class="w3-container
w3-teal">` + `w3_navbar`, with **zero** of the `id-admin-top`/`id-admin-scr`/
`id-admin-scroll` DOM ids the patch modifies. The entire target structure does
not exist. Porting would mean rewriting Web-888's admin page, not cherry-picking.

## Dropped in later stages (stages 3-5 — all RED after hands-on verification)

The initial plan queued stages 3-5 as "pending, verify per-file." Verification
(2026-08-01) found **all of them RED** — they depend on Web-888's divergent
frontend or restructured code paths. Recorded here with the concrete evidence.

### 0105 — mobile/narrow-screen UI (`b7baae9`, `2ac60e5`, `09418b3`) — DROPPED (RED)
All three commits depend on `w3_inline_noencl()` and `kiwi.WIN_WIDTH_NOM`,
**neither of which exists in Web-888** (grep returns 0). The only standalone
piece, `b7baae9`'s `manifest.json`, is a generic placeholder
(`"name": "Your App Name"`, `"short_name": "App"`) — not a Web-888-tailored
PWA manifest, and its `<link rel="manifest">` HTML wiring also depends on the
divergent layout. Not worth extracting.

### 0106 — `time_display_width()` refactor (`53328ae`) — DROPPED (RED)
This renames `time_display_width()` → `kiwi.time_display_width` across 11
extensions' `.js`. **Web-888 has no `kiwi.time_display_width` property** —
`time_display_width` is still a standalone `function` at `web/kiwi/kiwi.js:734`,
and the `kiwi` object literal (lines 5-...) contains neither
`time_display_width` nor `WIN_WIDTH_NOM`. Those properties were added upstream
in the same mobile-optimization series Web-888 lacks. Applying `53328ae` in
isolation would make all 11 extensions call an undefined property → runtime
breakage. Not portable without the missing base.

### 0107 — ALE user-list guard (`c472a26`) — DROPPED (RED)
The patch adds `if (!ale.have_user_scan_list && rv.found_menu_match)` inside
`ALE_2G_environment_changed()`. While `ale.have_user_scan_list` exists in
Web-888 (`ALE_2G.js:55`), **Web-888's `ALE_2G_environment_changed`
(`ALE_2G.js:1178-1197`) is a far simpler function that contains none of the
`ale_2g_menu_match`/`found_menu_match` logic the patch edits** — that logic
lives elsewhere (`ALE_2G.js:422-590`) in a structurally different form. The
target code block does not exist at the patch site.

### 0108 — client-side FFT (`b1e0c84`..`f8f8fc7`) — DROPPED (RED)
12 commits; `web/extensions/FFT/FFT.js` grows 645 → 2004 lines. This is a
**new feature**, not a cherry-pick, and depends on the `WIN_WIDTH_NOM` /
`w3_inline_noencl` infrastructure Web-888 lacks. Backend `FFT.cpp` is unchanged
(349 lines both). Would require porting the whole mobile-infra base first;
treat as a future standalone feature port, not part of this patch set.

### 0109 — SNR kick (`ef22aeb`) — DROPPED (RED, reimplementation possible)
KiwiSDR's SNR kick lives in `rx/rx_snr.cpp` (`SNR_meas()`), **absent in
Web-888**. Web-888's SNR logic is in `rx/rx_util.cpp`
(`SNR_meas_task`/`SNR_calc`, structurally different). Web-888 *does* have the
`c->kick` plumbing (`rx_util.cpp:333,342,349,758`), so a feature-equivalent
reimplementation is feasible — but it is a reimplementation against Web-888's
code, not a cherry-pick of `ef22aeb`.

### Summary verdict

After full hands-on verification, the **portable surface is the `net/` C++ layer
and pure data files** — both already captured by 0101 (CHU) and 0104 (security).
The `web/kiwi/` and `web/extensions/` JavaScript is too divergent, and the SNR
code path was restructured. Further KiwiSDR alignment would need either (a)
upstreaming these features into Web-888 directly (feature ports, not
cherry-picks), or (b) waiting for Web-888 to independently rebase its frontend
closer to KiwiSDR's. The cherry-pick patch set is **complete at stages 1-2**.

---

## Second-pass expansion (2026-08-04/05): patches 0110-0143

A full re-survey of KiwiSDR history (`docs/dev/web888-kiwisdr-cherry-pick-plan.md`,
2026-08-04 second-pass section) found the first-pass "complete" verdict above
was premature. 34 further patches were produced in four hardware-verified
batches. Per-patch upstream hashes, adaptation notes and SKIP rationale live
in `../cherry-picks.manifest` (authoritative, machine-readable); per-batch
build/verification evidence lives in `docs/dev/CHANGELOG.md`.

Batch 1 — GREEN data/small (2026-08-05, deb md5 3f6e61ab):
0130 PSKReporter buf len, 0131 FT8 V/UHF+QO-100 freqs, 0132 WSPR QO-100 band,
0133 SSTV R36-BW.

Batch 2 — tier-3 leftovers (2026-08-05, deb md5 2152b869):
0122 admin-pwd==serno popup, 0126 gps_isValid placeholder lat/lon rejection,
0128 nbcmd exit-status passthrough, 0129 dx_print_search debug (reduced).

Batch 3 — scan/autorun/DRM/WSPR (2026-08-05, deb md5 70bbc2e7):
0134 MODE_FLAGS_SCAN + freqChangeLatch (ALE_2G from_menu), 0135 "(connecting)"
placeholder, 0136 disable-connections stops autorun (KICK_ALL), 0137 DRM
preemption subsystem (drm_max_rx, rx_autorun_kick_all_preemptable), 0138 WSPR
upload checkbox gate, 0139 WSPR clear button (minimal).

Batch 4 — VERIFY outcomes + DX sort (2026-08-05):
0140 AJAX_PHOTO uninitialized-fname crash fix (a591cddf adapted — bug was
present in Web-888), 0141 UTF-8 username server side (utf8makevalid at ingest,
log non-ASCII strip removed), 0142 timecode initial phase correction (8 JS
files applied clean; correction was JS-side, not in the PLL C++), 0143 DX
label freq+mode qsort (init/dx.cpp, mode_lc/mode_flags).

Deferred with rationale in the manifest: ipset blacklist (f175da8d et al. —
packaging + sudoers cost, marginal value unproxied), FAX recording rework
(f98b3779 — architectural divergence), kiwi_output_chars console rework
(c2487091 + bfdfc728 — 9 extensions + kiwi.js, epic-sized), and all RED
candidates from the plan tables.

---

## Feature ports (plan section B): patch 0144

0144 (2026-08-05, plan section B.1) is a feature port, not a cherry-pick:
the entire mongoose 5.6 web layer is replaced by KiwiSDR's mongoose 7.14
file set (`4eebfb3b` flipped Kiwi's own symlinks to the same files), with
Web-888's local deltas re-applied on top. Vendored: `pkgs/mongoose/`
(mongoose.cpp/h 7.14 + mongoose_config.h, Kiwi's `#ifdef KIWISDR` compat
fields on `struct mg_connection`), `web/web.{cpp,h}`, `web/web_server.cpp`,
`web/web_util.cpp` (Kiwi's `web_*_7.14` variants). Consumers adapted to the
new API: `net/net.cpp` (4-arg `check_if_forwarded` rejecting forwarded
local/loopback, 4th param defaulted), `net/update.cpp` (`update_in_progress`
exported), `support/misc.cpp`/`rx/rx_server.cpp` (`mg_ws_send` incl.
`WEBSOCKET_OP_CLOSE`), `support/str.cpp` (`kiwi_json_to_html` ported),
`rx/rx_server_ajax.cpp` (ev_data + `mg_http_next_multipart` in AJAX_PHOTO /
AJAX_DX, heap `vname`/`fname` freed via `kiwi_asfree`), `extensions/FT8/
PSKReporter.cpp` (`udp_connect`/`udp_send`, matching Kiwi HEAD — `web_connect`
dropped upstream). Upstream anchors: 028687cc cef6472b 4eebfb3b aeda0224
a70c1b06 bccebc9f 970b6072 c38ff40b 6b5c05b9; excludes 38079f38 (the FSK
UDP streaming feature itself). Unblocks FSK UDP streaming, DRM RSCI output,
multi-admin autokick (28b31980) and proxy-header robustness.

Two Web-888-specific collision/build fixes ride in the same patch:
(a) mongoose 7.14's built-in MQTT defines `enum { MQTT_OK, ... }` at
`mongoose.h:2351`, clashing with `MQTT_OK = 1` in the vendored LiamBindle
MQTT-C (`pkgs/mqtt-c/mqtt.h`) that `net/mqttpub.cpp` pulls in transitively.
The enum is hidden from `mongoose.h` under `#ifndef KIWISDR` and privately
re-declared inside `mongoose.cpp` under `#ifdef KIWISDR` so `mg_mqtt_parse`
still compiles (Web-888 uses no `mg_mqtt_*` API; MQTT-C is the production
publisher). (b) `CMakeLists.txt` adds `${UPSTREAM_DIR}/pkgs/sdrpp_server` to
the `websdr.bin` include dirs — patch 0144's `sdrpp_server.h` include in
`web/web_server.cpp` exposed a pre-existing omission (the sources were
globbed, the header dir never was). (c) `CMakeLists.txt` gains
`MG_ARCH=MG_ARCH_CUSTOM`: mongoose.h only includes `mongoose_config.h` when
`MG_ARCH` is unset or `MG_ARCH_CUSTOM`, but on Linux `__unix__` pre-sets
`MG_ARCH=MG_ARCH_UNIX`, so without the flag `MG_ENABLE_IPV6` silently
defaulted to 0 — `tousa()` built an AF_INET sockaddr for an AF_INET6 socket
and `bind("[::]:8073")` failed EINVAL, crash-looping websdr.bin on hardware
(2026-08-05). Kiwi passes the same flag globally via
`pkgs/mongoose/Makefile.inc` (`INT_FLAGS += -DMG_ARCH=MG_ARCH_CUSTOM`).

---

## Upstream-sync workflow

To re-check these candidates when KiwiSDR or RaspSDR advances:

```bash
# re-clone KiwiSDR (gitignored scratch tree), then:
scripts/refresh-cherry-picks.sh                    # report: drift + upstream-merged detection
scripts/refresh-cherry-picks.sh --regen            # regenerate only non-adapted (GREEN) patches
scripts/refresh-cherry-picks.sh --kiwi-tree /path  # point at an existing clone
```

The script reads `cherry-picks.manifest`, confirms each KiwiSDR commit/range
still resolves, regenerates the raw upstream diff, reports drift vs the stored
patch, and flags candidates whose changes RaspSDR may have already merged
upstream (so the patch can be dropped). It does **not** overwrite hand-adapted
patches (0104) — only reports drift on those.

### 0145-kiwi-admin-resync.patch — Admin-page stack re-sync to KiwiSDR v1.902 (plan B.2)
- **Source:** KiwiSDR `c40ecb47` (= v1.902) `web/kiwi/{admin.js,admin.html,w3_util.js,kiwi.css,w3_ext.css}`.
- **What it does:** wholesale replacement of Web-888's independently-forked admin-page
  stack with the v1.902 versions, re-applying every Web-888 customization on top, plus
  a one-line `admin_sdr.js` fix (`id-sdr_hu` → `id-public`; upstream v1.902 derives tab
  content ids from the lowercased tab label).
- **Why:** Web-888's admin.js was an independent older layout with none of upstream's
  modern infrastructure (see the 2026-08-01 reality note above), which made every admin
  UI cherry-pick unportable. After B.2 the admin stack tracks upstream again, so future
  Kiwi admin improvements become cherry-pickable.
- **Method:** per-file 3-way merges (`git merge-file --diff3`) against Beagle_SDR_GPS
  minimal-diff bases (admin.js `b13b4ebd`, w3_util.js `f80c2d0d`, kiwi.css `8b58cd74`,
  admin.html `2ae9316d`, w3_ext.css `a7f61ff6`), 64 admin.js conflicts resolved by hand,
  then a server-coupling audit against Web-888's `ui/admin.cpp` with protocol-compat
  splices. Outcome recorded in `docs/dev/CHANGELOG.md`.
- **Web-888 deltas re-applied (kept):** rx-888 branding/links and registration
  (`SET rev_register user=.. host=..` protocol, proxy.rx-888.com, downloads.rx-888.com
  blacklist URL), variable RX sample rates (`admin.c_rates`), HF-bandwidth/narrowband,
  wf_share, airband, WiFi mode/ssid/password, MQTT section, Update Channel
  Alpha/Stable, gpsd-based slim GPS tab (az/el canvas, `prn_name`, RSSI bars),
  hotspot/`ping rx-888`/`df -H /` console buttons, `#0533bd` blues, `w3_table_body()`,
  web-888.51x60 logo, private proxy-server widget (upstream had commented it out).
- **Upstream v1.902 adopted:** `admin.tabs` tab builder, `id-panels-container` layout,
  `admin_confirm_*` restart/reboot/poweroff scheme, GNSS SBAS menu, MTU/hostname/
  restart_delay network widgets, log/console Copy buttons, clean-logs (journalctl)
  button, `w3_header()` banners.
- **Compatibility splices (Web-888 server unchanged):** rev_register protocol reverted
  (upstream's `reg=/auto=` args have no server handler), blacklist apply reverted to
  clear→chunked-set→enable (upstream's lock/start/disable unhandled), dead sends
  (`restart_proxy`, `my_kiwi_register`) removed, `kiwi.*` compat shim added
  (NAM/DUC/PUB/SIP/REV, hw, WIN_WIDTH_NOM, PLATFORM_BBAI_64, RX8_WF3),
  `w3_restart_cb`/`w3_reboot_cb` restored, Kiwi 8ch-mode promo stubbed, Users tab
  hidden (no `SET get_user_list` server handler).
- **Known-dead cosmetic widgets (documented for future server work):** `SET hostname`,
  `SET ethernet_MTU`, `SET domain_check` — UI renders, server ignores.
- **Also:** `0003-state-paths.patch` loses its `admin.js` hunk (`df -H /` is folded
  into the new admin.js).
- **Portability:** YELLOW by nature (wholesale swap), but verified: byte-identical
  application on top of the full preceding quilt series, `node --check` clean on
  admin.js/w3_util.js.

  **v2 addendum (2026-08-06):** first hardware deployment broke the *user* UI —
  upstream v1.902 `w3_util.js` calls `isNumberElse()` which lives in upstream
  `kiwi_util.js`, absent from RaspSDR's fork. A static undefined-reference scan
  found the full gap; the patch grew to 9 files with verbatim upstream helper
  ports (each marked `// Web-888: ported verbatim ... (B.2 admin re-sync dep)`):
  `kiwi_util.js` (16 helpers incl. isEmptyString/isNumberElse/kiwi_store*/
  isdigit-family/kiwi_remove_escape_sequences), `kiwi.js` (kiwi_output_chars),
  `kiwi_ui.js` (sd_done), `admin_sdr.js` (config_init, dx_html_init, and
  `admin.reg_status.*` → `admin.status.*` x4), plus a `control_confirm_show()`
  alias in admin.js's shim block. Re-verified byte-identical slot application
  and `node --check` on all 6 JS files. See cherry-picks.manifest for the full list.

  **v3 addendum (2026-08-06, admin-page live test):** two ant_switch-extension
  coupling fixes — Web-888's admin page never loads the extension JS, so upstream's
  bare `ant_switch_config_html()` call (init case) and bare `ant_sw` reference
  (status_interval) ReferenceErrored. Fixed with `w3_call(...)` (silent no-op) and a
  `var ant_sw;` declaration in the shim block. `px(NaN)` trace from
  admin_draw→init_panel_toggle is identical upstream (admin.js:5056) — cosmetic, kept.

### 0146-webcpp-restore-ext-list-js.patch — Restore EXT_LIST_JS registration (0144 regression)
- **Source:** none (local bugfix of 0144's web.cpp port).
- **What:** removes the `#ifdef USE_SDR` guard around the `EXT_LIST_JS` iparams
  registration that 0144's mongoose-7.14 web.cpp brought from upstream. Web-888's
  cmake build never defines `USE_SDR` (Kiwi Makefile concept), so the registration
  was compiled out: admin.html served the literal `%[EXT_LIST_JS]` token and
  extension JS stopped loading on the admin page.
- **Why separate from 0144:** avoids regenerating the huge mechanical 0144 patch;
  a 4-line follow-up is far more reviewable.
- **Effect:** restores pre-0144 behavior — the admin page loads every registered
  extension's JS/CSS again, which also defines `ant_sw` / `ant_switch_config_html`
  (0145 v3's w3_call/`var ant_sw` guards stay as harmless defense-in-depth).

  **v4 addendum (2026-08-06, user-page live test):** the v1.902 w3_util.js inserted a
  `navbar` argument into `w3_nav`/`w3_navdef`/`w3_click_nav` and reworked
  `w3_fillText` options — RaspSDR's openwebrx.js/ext.js still call the old
  signatures, so the optbar navbar broke silently (control panel stuck at its
  index.html `height:0`, a 15px sliver). Added a compat dispatch in w3_util.js:
  new-style detected by `id-` prefix on the nav argument; RaspSDR's original bodies
  kept verbatim as `*_legacy` functions; old-style `w3_fillText` font-string arg is
  mapped to the new opts object.

## 0147-kiwi-fax-recording-info-leak.patch

- **Upstream:** KiwiSDR `f98b3779` (2026-06-29, post-v1.902), "use standard image
  save button like other exts".
- **Why cherry-picked:** security/info-leak. The FAX extension's server-side
  recording wrote every FAX received by any user to a fixed, world-downloadable
  file `/root/samples/fax.chN.pgm` (DIR_DATA) — anyone could download other
  users' receptions afterwards (the pre-fix upstream code even carries a
  "Little bit of a security hole" comment). Upstream removed recording entirely
  in favor of a browser-side Save button exporting the displayed canvas as a
  timestamped JPEG download, consistent with the other extensions. This also
  drops the pgmtoppm/ppmtogif conversion plumbing the close handler needed.
- **What it touches:** `extensions/FAX/FaxDecoder.{cpp,h}` (verbatim upstream
  diff — files were identical to upstream pre-fix), `extensions/FAX/fax.cpp`
  (remove `serno[]` + `SET fax_file_open`/`SET fax_file_close` handlers),
  `web/extensions/FAX/FAX.js` (remove record icon + `fax_download_avail`
  handling, add `fax_save_cb`).
- **Fork adaptations:** Web-888 ships no `.min.js`/`.gz` files (upstream's
  minified-file hunks are N/A). fax.cpp/FAX.js hunks were hand-applied around
  pre-existing fork tweaks (4-channel `SND_RATE` ProcessSamples signature,
  per-bandwidth `MIDDLE/NARROW` init, `w3-ext-retain-input-focus sfmt`, HF FAX
  panel layout). The commented-out `//fax_file_cb(0, 0, 0);` trace in
  `FAX_blur` is kept, matching upstream post-fix.
- **Verification:** `patch -p1 --dry-run` clean against the pristine pin tree
  (FaxDecoder.cpp hunk #2 applies with fuzz 2 — context-only drift).

## 0148-mongoose-epollerr-graceful-close.patch

- **Upstream:** none — Web-888-local fix (mongoose 7.14 and cesanta master both
  keep the plain `mg_error(c, "socket error")` behavior; verified in
  `docs/dev/mongoose-websocket-socket-error-investigation.md`).
- **Why:** on the Debian image the `/admin` websocket was dropped ~0.5 s after
  connect with `mongoose ... socket error 2` in the log. Code-traced: epoll
  reports `EPOLLERR` for the connection's socket; that also fires on a
  *graceful* peer close (browser navigating away / reconnecting), so the
  connection took the `mg_error` hard-close path and logged an error for a
  normal event.
- **What it does:** in `mg_iotest()`'s epoll branch, `SO_ERROR` is read via
  `getsockopt()` before deciding. Only a real pending socket error takes the
  `mg_error` path; a clean `SO_ERROR` treats the event as readable/HUP
  (same handling as the non-error branch, `EPOLLERR` included in the read
  mask) so the next read returns 0 and the connection closes quietly.
  Precedent: `pkgs/sdrpp_server/sdrpp_server.cpp` SO_ERROR check.
- **Scope:** epoll branch only. The poll/select `socket error 3/4` paths are
  not used by the Web-888 build (`MG_ENABLE_EPOLL`) and keep upstream
  behavior.
- **Verification:** `patch -p1 --dry-run` clean against the post-0147 series
  tree. QEMU + hardware smoke gate owed before release (watch for the
  absence of `socket error 2` lines while browsing /admin, and confirm real
  connection errors still close).

## 0149-kiwi-rx-snr-port.patch

- **Upstream:** KiwiSDR v1.902 `rx/rx_snr.{h,cpp}` + `web/kiwi/admin.js`
  SNR config UI + `web/kiwi/kiwi.js` `kiwi_snr_stats()`/`snr_stats` MSG
  handling (feature port, no single commit — the framework grew across many
  upstream commits; source: `.tmp/repos/KiwiSDR` at c40ecb4).
- **Why:** plan doc step B.4, the last feature epic of the KiwiSDR
  alignment work. Web-888's stock SNR support was hourly-interval only with
  an integer-edge `/snr` JSON and no custom band / ham-band measurements.
- **What it does:** imports `rx_snr.{h,cpp}` wholesale and adapts it:
  TaskSleepSec/TaskWakeupF(TWF_CANCEL_DEADLINE) scheduling (no
  TWF_TIME_REMAINING), plain-double `freq_offset_kHz` globals,
  `ZOOM_CAP -> MAX_ZOOM` (moved to `rx_waterfall.h`), `cfg_true()`/
  `cfg_int_()` local macros, and **no ant_switch SNR coupling**
  (`snr_meas_ant_sw`/`antsw.snr_ant` dropped). Replaces the hourly-only
  SNR block in `rx/rx_util.{h,cpp}` and the old int-edge `/snr` JSON with
  imin/ant + float band edges. `admin.js` gets the full upstream SNR
  options UI (1/5/10-min + custom intervals, custom band lo/hi/zoom,
  ham-band checkbox, measure-now spinner, countdown) minus the ant_switch
  checkbox; `kiwi.js` gets `kiwi.SNR_CUSTOM`, `kiwi.snr_intervals_min`,
  `kiwi_snr_stats()` and the `MSG snr_stats` case.
- **Scope:** 14 files — 2 new (`rx/rx_snr.{h,cpp}`), 10 C++ modified, 2 JS
  modified. All fork deviations marked `Web-888 0149:`.
- **Verification:** `patch -p1 --dry-run` clean against the post-0148
  series tree; host `g++ -fsyntax-only` pass on all touched C++; `node
  --check` on both JS files. QEMU + hardware smoke gate owed before
  release (watch `/snr` JSON for `imin`, "Measure SNR now" button, custom
  interval save/reload).

## 0150-antenna-switch-snr-remeasure.patch

- **Upstream:** adapted from KiwiSDR `pkgs/ant_switch/ant_switch.cpp`'s
  `SET antsw_snr` handler (re-wakes the SNR measurement task 5 s after an
  antenna change so the admin SNR page reflects the new antenna).
- **Why:** 0149 dropped the ant_switch SNR coupling on the assumption the
  fork had no ant_switch support — wrong: the fork ships an FPGA-direct
  ant_switch variant (`extensions/ant_switch/`), so an antenna change left
  stale SNR data until the next scheduled measurement.
- **What it does:** restores the `snr_meas_ant_sw` admin checkbox and
  calls a new static `ant_switch_snr_remeas()` hook from
  `ant_switch_setantenna()`/`ant_switch_toggleantenna()` after
  `fpga_set_antenna()`. Server-side hook instead of upstream's client
  `SET antsw_snr` message — the fork switches antennas entirely on the
  server, so this also covers server-initiated switches. Fork
  `coroutines.h` has no `TWF_NEW_DEADLINE_SEC`, so the wake is immediate
  (`TaskWakeupF` + `TWF_CANCEL_DEADLINE`, the fork's established on-demand
  pattern) and the checkbox label drops upstream's "(after 5 second
  delay)". Deviations marked `Web-888 0150:`.
- **Scope:** 2 files (`extensions/ant_switch/ant_switch.cpp`,
  `web/kiwi/admin.js`).
- **Rejected (evaluated, not ported):** upstream's SNR-gated default
  antenna selection (`ant_switch.antNdefault`, `ground_when_no_users`,
  `kiwi.snr_initial_meas_done` gating in `ant_switch_select_default_antenna()`).
  It needs upstream's whole pluggable ant_switch backend framework
  (`pkgs/ant_switch/backends`, `ant_switch.enable`, 10 s poll task, ADM
  antsw_* admin messages) re-platformed onto the fork's FPGA-direct
  variant, and serves public multi-antenna sites (idle default antenna /
  ground-when-idle); Web-888's variant already has thunderstorm mode.
  Revisit if a real deployment asks for it.
- **Verification:** `patch -p1 --dry-run -F 0` clean against the full
  post-0017 series tree; host `g++ -fsyntax-only` on ant_switch.cpp;
  `node --check` on admin.js. Hardware smoke owed: enable the checkbox,
  switch antennas from the user page, watch journal for an on-demand
  `SNR_meas` wakeup.

## 0151-websocket-send-via-s2c-queue.patch

- **Upstream:** none — KiwiSDR master has the same unlocked cross-thread
  `mg_ws_send()` pattern (support/misc.cpp), but upstream coroutine tasks
  are never truly parallel on the single-core BeagleBone, so the race does
  not manifest there. This port implements every kiwi task as a real
  pthread (`support/coroutines.cpp` `_CreateTask` → `pthread_create`),
  which turns the latent race into observed frame corruption on the
  dual-core Zynq-7010.
- **Why:** probabilistic /admin websocket disconnects — browser console
  `Received unexpected continuation frame` / `Invalid frame header`
  (kiwi_util.js:2111 → admin_close), server log `ADMIN connection closed`
  ~0.5 s after allow + `mongoose ... socket error 2`. Wire capture with
  `scripts/test-websocket-frames.py` showed the server emitting malformed
  frames exactly at the boundary after the 47821-byte `load_dxcfg` frame
  (zeroed 2-byte header, or declared length 4 bytes short + zeroed 4-byte
  extended header) whenever multiple admin connections were active.
  Root cause: 0144 removed the old mongoose's global `mongoose_lock` that
  made `mg_websocket_write()` frame-atomic from any thread; 7.14's
  `mg_ws_send()` does two separate `mg_send()` appends with no locking.
  Full analysis: `docs/dev/mongoose-websocket-frame-corruption-investigation.md`.
- **What it does:** `send_msg_buf()` and `send_msg_mc()` (the two leaves
  every `send_msg*()` wrapper funnels through) no longer call
  `mg_ws_send()` directly; they queue onto the locked per-connection s2c
  nbuf (`nbuf_allocq`, takes `nd->lock`), and the sole binary-frame
  `mg_ws_send()` caller is `iterate_callback()` in `web_server.cpp` — the
  mongoose poll thread. `send_msg_mc()` looks up the conn_t with
  `rx_server_websocket(WS_MODE_LOOKUP, mc)`. Restores the send-side
  architecture the nbuf queue was designed for; latency cost is
  poll-loop-paced (sub-ms), matching pre-7.14 upstream semantics.
- **Scope:** 1 file (`support/misc.cpp`). Deliberately unchanged: websocket
  CLOSE frames (`web/web.cpp` client-close reply — already poll-thread;
  `rx/rx_server.cpp` WS_MODE_CLOSE teardown — can still run on task
  threads but only touches dying connections; queueing CLOSE would need
  opcode-carrying nbufs). Residual risk documented in the investigation
  doc.
- **Verification:** `patch -p1 -F 0` clean against the full post-0019
  series tree; runtime verification on hardware with
  `scripts/test-websocket-frames.py` (previously reproduced corruption in
  ~5 s) plus an admin-page browser soak.

## 0152-websocket-control-msgs-no-drop.patch

- **Upstream:** none — Web-888-local fix on top of 0151. Upstream KiwiSDR
  never routes websocket control messages through the s2c nbuf queue (its
  unlocked direct `mg_ws_send()` is safe on the non-parallel BeagleBone
  coroutines), so there is nothing to cherry-pick; the bug only exists
  because 0151 put control traffic onto a queue whose watermarks were
  designed for stream data.
- **Why:** 0151 routed `send_msg_buf()`/`send_msg_mc()` through the locked
  s2c nbuf queue to fix cross-thread frame corruption, but that queue's
  stream-data watermarks (`ND_HIWAT=64`, ovfl latch until `< ND_LOWAT=32`)
  exist for audio/waterfall data where dropping under backpressure is
  correct — they silently dropped *control messages* too. The /admin
  startup burst (`load_cfg`/`load_dxcfg`/`load_dxcomm_cfg`/`load_adm` +
  ~170 `log_msg` frames + 25 `ext_call` extension-config messages, one
  queue entry each) exceeds 64 outstanding entries whenever the mongoose
  poll thread drains slower than the task threads produce;
  `nbuf_enqueue()` then latches `nd->ovfl` and `nbuf_allocq()` frees the
  message, so the client never receives its `ext_call` burst and the admin
  Extensions tab renders nothing (except ant_switch, which registers its
  admin config independently). Reproduced live on device (2026.730-7): one
  /admin load received all 25 `ADM ext_call=...` frames, the next load
  received zero (plus zero `extint_list_json`) while ~170 `log_msg` frames
  on the same connection still flowed — a drain-rate race, hence the
  per-page-load nondeterminism.
- **What it does:** adds `nbuf_allocq_critical()`, which bypasses the ovfl
  latch and only drops past a pathological `ND_CRIT_HIWAT=1024` cap —
  loudly, via `lprintf`, since tripping it would signal a wedged
  connection rather than normal load. `send_msg_buf()`/`send_msg_mc()`
  use the critical variant. `nbuf_allocq()` stays as-is for stream data,
  so audio/waterfall backpressure behaviour is unchanged.
- **Scope:** 3 files (`net/nbuf.cpp`, `net/nbuf.h`, `support/misc.cpp`).
- **Verification:** live reproduction on device documented above; the
  patch ships in the 01xx series (position-independent against the
  surrounding entries).

## 0153-admin-status-poll-unknown-cmd-noise.patch

- **Upstream:** none — Web-888-local fix (RaspSDR's server does not
  implement the polled commands; real KiwiSDR does, so there is nothing
  to cherry-pick).
- **Why:** 0145's admin.js resync to KiwiSDR v1.902 brought
  `status_focus()`'s 1-second interval that sends `SET xfer_stats` and
  `ADM antsw_GetCurrentAnt` while the admin status tab is open.
  RaspSDR's server implements neither, so `ui/admin.cpp` logged
  `ADMIN: unknown command: <ip> <...>` twice per second per open admin
  status tab, drowning real log entries and churning log2ram.
- **What it does:** removes the two sends from the interval. The
  surrounding ant_switch status display block is kept to stay close to
  upstream shape; it is inert on Web-888 (the ant_switch extension JS
  is never loaded on the admin page, so `ant_sw.status` is never set
  and `id-msg-antsw` stays hidden, exactly as before).
- **Scope:** 1 file (`web/kiwi/admin.js`), 2 lines replaced by an
  explanatory comment. `SET auto_nat_status_poll` (network tab, 2 s)
  IS implemented server-side and is untouched. Deliberately unchanged:
  the `xfer_stats_cb` / `status_xfer_cb` client callbacks (dead without
  a server, harmless) and the `stats.html` "Server Load" table (always
  empty on Web-888, before and after).
- **Verification:** `patch -p1 -F 0` clean against the full post-0152
  series tree (whole 54-patch series re-verified); `node --check` clean.
  Runtime confirmation owed on hardware: absence of `ADMIN: unknown
  command` lines while browsing /admin's status tab.
