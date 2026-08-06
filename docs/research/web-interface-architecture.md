# Web-888 Web Interface Architecture

## Overview

The Web-888 browser UI is a KiwiSDR/OpenWebRX-derived single-page application served by the SDR backend itself. The backend HTTP server (`web/web.cpp`, `web/web_server.cpp`) serves HTML, CSS, JavaScript, images, extension assets, and AJAX responses, then upgrades selected connections to WebSockets for low-latency control, audio, waterfall, and extension traffic.

At a high level:

1. `web/openwebrx/index.html` defines the operator-facing page skeleton.
2. `web/web.cpp` injects the standard CSS/JS bundle into `%[GEN_LIST_CSS]` and `%[GEN_LIST_JS]` placeholders and performs `%[...]` HTML substitutions from configuration.
3. `web/kiwi/kiwi.js` bootstraps the page, negotiates authentication, opens WebSockets, and launches the correct top-level UI (`kiwi_main()` for the user UI, `admin_main()` for the admin UI).
4. `web/openwebrx/openwebrx.js` owns most of the receiver UI: tuning, spectrum, waterfall, panels, mouse/keyboard interaction, and the sound/waterfall sockets.
5. `web/openwebrx/audio.js` implements browser audio buffering, resampling, decompression, and playback with Web Audio.
6. `web/extensions/ext.js` provides the extension framework that dynamically loads extension JS/CSS, shows extension panels, and opens a dedicated extension socket.

This architecture keeps the UI largely client-side, while the server pushes real-time binary streams over WebSockets and serves configuration/state through HTML substitution, AJAX endpoints, and control messages.

## File And Asset Layout

The web directory in `RaspSDR/server` is organized into a few major areas:

- `web/openwebrx/`: main receiver HTML/CSS/JS (`index.html`, `openwebrx.js`, `audio.js`, `openwebrx.css`, `ima_adpcm.js`)
- `web/kiwi/`: shared Kiwi/Web-888 utilities, app bootstrap, admin UI, styling, helper libraries (`kiwi.js`, `admin.js`, `kiwi_util.js`, `w3_util.js`, `kiwi.css`)
- `web/extensions/`: extension runtime (`ext.js`) and one directory per extension (`DRM`, `FT8`, `waterfall`, `noise_filter`, etc.)
- `web/pkgs/`: third-party frontend packages such as W3.CSS, Font Awesome, and text-security CSS
- `web/web.cpp`, `web/web_server.cpp`: backend web server and asset injection/caching logic

The actual bundle list is assembled in `reload_index_params()` in `web/web.cpp`, which injects:

- CSS: `pkgs/font-awesome/css/font-awesome.css`, `pkgs/text-security/text-security-disc.css`, `pkgs/w3/w3.css`, `kiwi/w3_ext.css`, `openwebrx/openwebrx.css`, `kiwi/kiwi.css`
- JS: `kiwi/kiwi_util.js`, `kiwi/kiwi.js`, `kiwi/kiwi_ui.js`, `kiwi/kiwi_map.js`, `kiwi/w3_util.js`, `pkgs/w3/w3color.js`, `kiwi/monitor.js`, `openwebrx.js`, `ima_adpcm.js`, `audio.js`, `extensions/ext.js`

## Frontend Architecture

## Boot Sequence

The top-level HTML for normal users is `web/openwebrx/index.html`.

Important details in the page template:

- `config/config.js` is loaded before the main JS bundle, so runtime configuration is available early.
- `%[GEN_LIST_CSS]` and `%[GEN_LIST_JS]` are server-side substitutions performed in `web/web.cpp`.
- `%[HTML_HEAD]` allows admin-configured custom HTML/CSS/analytics snippets to be injected into the page head.
- The body is mostly a static shell; canvases and many controls are inserted or resized dynamically by JavaScript.

On load, `kiwi_bodyonload()` in `web/kiwi/kiwi.js`:

- decides which interface is being loaded from `data-type` (`kiwi` vs `admin`)
- performs browser gating for known unsupported cases (e.g. old LG SmartTV Chrome)
- initializes W3 helper infrastructure
- opens the first WebSocket
- starts the password/authentication flow via `ext_hasCredential()`

For user sessions, the UI opens two primary sockets in sequence:

- `owrx_ws_open_snd()` for sound/control
- `owrx_ws_open_wf()` for waterfall/control

Only after both authenticate successfully does `kiwi_valpwd2_cb()` call `kiwi_main()` and reveal the receiver UI.

## Main Architectural Layers

The browser-side code is layered rather than fully modular:

- `web/kiwi/kiwi.js`: application bootstrap, authentication, config save helpers, global state in `kiwi`, top-level orchestration
- `web/openwebrx/openwebrx.js`: receiver UI controller and rendering engine
- `web/openwebrx/audio.js`: audio transport/playback pipeline
- `web/extensions/ext.js`: extension manager and extension communication API
- `web/kiwi/w3_util.js`: DOM/layout/control utility library used throughout the UI and admin pages
- `web/kiwi/kiwi_util.js`, `web/kiwi/kiwi_ui.js`, `web/kiwi/kiwi_map.js`: shared helpers, UI widgets, map integrations

The codebase is global-state-heavy rather than component-framework-based. Large singleton objects such as `kiwi`, `owrx`, `audio`, `extint`, `admin`, `spec`, and `wf` coordinate the page.

## Backend Communication Model

The backend web server in `web/web_server.cpp` documents the transport model clearly:

- HTTP GET serves files and AJAX responses.
- WebSockets carry:
  - client-to-server control messages (`SET`, `SND`, `W/F`, `EXT`, `ADM`, `MFG`)
  - server-to-client binary streams (audio, waterfall)
  - server-to-client control/status messages (`MSG`, `ADM`, `EXT`, etc.)

The server event loop:

- handles incoming HTTP and WebSocket frames in `ev_handler()`
- stores incoming socket payloads in client-to-server buffers (`c2s`)
- dequeues server-to-client buffers (`s2c`) in `iterate_callback()` and writes them with `mg_websocket_write()`

`web/web.cpp` is also responsible for:

- mapping URLs to embedded or filesystem-backed assets
- server-side HTML substitution for placeholders like `%[GEN_LIST_JS]`
- appending per-file JS version checks to served `.js` files via `kiwi_check_js_version.push(...)`
- deciding cache policy, gzip handling, and content headers
- blocking direct fetches of sensitive `.json`, `.ini`, and `.conf` files
- routing extension fetches to either embedded assets or an external `/root/` extension directory

## Main UI Components And Organization

The operator UI in `web/openwebrx/index.html` is organized into several main regions.

## 1. Message / Splash Container

- `id-kiwi-msg-container`
- used before the receiver UI becomes active
- displays login prompts, compatibility errors, queue/camp notices, and startup messages

## 2. Top Information Bar

Defined by `id-top-container` and styled in `web/openwebrx/openwebrx.css`.

It contains:

- receiver title, description, antenna text
- owner information
- user identity / session information
- receiver photo area with collapsible details
- time display inserted dynamically into `id-topbar-right-container`

The photo/details section can be expanded/collapsed by `toggle_rx_photo()` and triggers layout recalculation of the waterfall region.

## 3. Spectrum / Tuning Region

Contained in `id-non-waterfall-container`.

Subsections:

- `id-ext-data-container`: extension-owned data canvas/area when an extension takes over the upper display region
- `id-spectrum-container`: real-time spectrum display and dB tooltip overlay
- `id-tuning-container`: band scale, DX labels, and tuning scale
  - `id-band-canvas`
  - `id-dx-container` / `id-dx-canvas`
  - `id-scale-canvas`
  - passband drag handles: `id-pb-adj-car`, `id-pb-adj-lo`, `id-pb-adj-hi`, `id-pb-adj-cf`

This region handles click-to-tune, drag-to-adjust-passband, band labels, and DX overlays.

## 4. Waterfall Region

- `id-waterfall-container`
- scrolling columnar waterfall rendered via stacked canvases
- `id-phantom-canvas` and `id-annotation-div` support overlays/annotation

The waterfall is large, scrollable, and dynamically resized with window and layout changes.

## 5. Panel System

The side and bottom panels are regular DOM panels, not framework widgets. In `index.html` they include:

- `id-news`
- `id-control`
- `id-readme`

Each panel uses metadata attributes such as `data-panel-name`, `data-panel-pos`, `data-panel-order`, and `data-panel-size`. `openwebrx.js` uses these to position and toggle panels.

The control panel is the main operator control surface and is filled dynamically with widgets such as:

- frequency entry
- band/extension selectors
- mode controls
- zoom controls
- waterfall and spectrum options
- S-meter and status indicators

## 6. Admin UI

The admin page is `web/kiwi/admin.html` with `data-type="admin"` on the main container.

It reuses the same injected CSS/JS infrastructure and adds:

- `web/kiwi/admin.js`
- `web/kiwi/admin_sdr.js`
- `%[EXT_LIST_JS]` so extension config code can participate in admin settings

`admin.js` builds a configuration-heavy UI with the same W3 utility system used by the main UI. It also includes:

- mobile-aware console layout logic (`admin.console.isMobile`)
- resize handlers (`admin_resize()`, `console_resize()`, `log_resize()`)
- admin WebSocket traffic via `open_websocket(..., admin_msg, admin_recv, ...)`

## Waterfall And Spectrum Display Implementation

The spectrum/waterfall implementation lives mainly in `web/openwebrx/openwebrx.js`.

## Display Model

The receiver UI keeps spectrum and waterfall as separate but coordinated displays:

- the spectrum is the current FFT slice rendered into `id-spectrum-canvas`
- the waterfall is a history of FFT rows rendered into a stack of canvases inside `id-waterfall-container`

Key setup functions and structures include:

- `openwebrx_resize()`
- `resize_scale()`
- `init_wf_container()`
- `resize_wf_canvases()`
- `resize_waterfall_container()`
- `spectrum_update(data)`
- `waterfall_init()`
- `waterfall_add(data_raw, audioFFT)`
- `waterfall_add_queue(...)`
- `waterfall_dequeue()`
- `waterfall_pan_canvases(...)`
- `waterfall_zoom_canvases(...)`
- `waterfall_position(...)`
- `waterfall_tune(...)`

## Canvas Strategy

The UI does not use a single infinite canvas. Instead it uses multiple canvases and a queue-based renderer:

- a spectrum canvas for the current FFT line
- one or more waterfall canvases stacked in the scroll container
- annotation and auxiliary canvases for overlays and interaction

This segmented approach makes it easier to:

- scroll efficiently
- pan and zoom by transforming or copying existing canvas content
- append new rows without repainting the entire waterfall history

## Data Flow

Waterfall data arrives over the `W/F` WebSocket opened by `owrx_ws_open_wf()`.

Pipeline:

1. backend sends binary waterfall frames
2. `waterfall_add_queue()` receives them from the socket callback
3. frames are queued in `waterfall_queue`
4. `waterfall_dequeue()` drains the queue on a timer (`waterfall_timer`)
5. frames are handed to `waterfall_add()`
6. `waterfall_add()` updates the live spectrum and paints a new waterfall line

Important synchronization detail: `waterfall_dequeue()` can delay output to keep waterfall display aligned with audio playback using `audio_ext_sequence` and `waterfall_delay`.

## Spectrum Rendering

`spectrum_update(data)` renders the current FFT-derived power line and updates the visible spectrum presentation. It also supports alternate display modes, including audio FFT rendering when enabled.

The spectrum region also contains:

- dB tooltip overlays (`id-spectrum-dB`)
- adaptive frequency tooltip positioning for mobile vs desktop
- passband overlays aligned to current mode and zoom

## Waterfall Rendering And Color Mapping

Waterfall coloring is computed in JS, not by pre-rendered images. Relevant functions include:

- `waterfall_color_index_max_min(...)`
- `waterfall_mkcolor(db_value)`

Color map selection is integrated with the `colormap` extension and configurable colormap tables in `kiwi.js` (`kiwi.cmap_s`, `kiwi.cmap_e`).

The `waterfall` extension provides additional waterfall-specific controls, while the main page exposes core options like min dB, autoscale, filter selection, and a “More” button that opens the dedicated waterfall extension.

## User Interaction

The waterfall/spectrum region supports:

- click-to-tune on waterfall and spectrum
- drag-to-pan across FFT bins
- zoom in/out centered on cursor or passband
- passband dragging and edge adjustment
- optional snapping and lookup actions
- export of the waterfall as an image via `export_waterfall()`

The resize path is important:

- `window.addEventListener("resize", openwebrx_resize)`
- `window.onorientationchange = orientation_change`
- these call `resize_wf_canvases()`, `resize_waterfall_container(true)`, and `resize_scale(...)`

## Audio Handling In The Browser

Audio transport and playback are implemented in `web/openwebrx/audio.js`.

## Socket And Packet Model

Audio arrives over the `SND` WebSocket opened by `owrx_ws_open_snd()`.

`audio_recv(data, ws, firstChars)` distinguishes packet type:

- if the frame prefix is not `SND`, it treats it as FFT/spectrum data and forwards it to `spectrum_update()`
- otherwise it parses sound metadata and payload

Audio packet metadata includes flags such as:

- `SND_FLAG_MODE_IQ`
- `SND_FLAG_COMPRESSED`
- `SND_FLAG_RESTART`
- `SND_FLAG_NEW_FREQ`
- `SND_FLAG_ADC_OVFL`
- `SND_FLAG_SQUELCH_UI`
- `SND_FLAG_LITTLE_ENDIAN`

This lets the browser adapt playback mode, stereo/IQ interpretation, compression state, and UI events from the stream itself.

## Browser Audio Pipeline

The browser audio chain is Web Audio API-based:

- `AudioContext` / `webkitAudioContext` setup in `audio_init()`
- `createScriptProcessor()` nodes for playback and watchdog paths
- optional `StereoPannerNode`
- optional `GainNode` for LG SmartTV compatibility
- optional convolver/resampler stages

The flow is roughly:

1. `audio_init()` creates the audio context and initializes state
2. `audio_rate(input_rate)` computes resampling ratios and buffer targets
3. `audio_recv()` parses and decodes incoming packets
4. `audio_prepare()` resamples and packages output buffers
5. once enough buffers are queued, `audio_start()` calls `audio_connect()`
6. `audio_onprocess()` drains prepared buffers into the output device

## Compression, Decoding, And Resampling

The code supports:

- uncompressed 16-bit PCM-like audio
- IMA ADPCM compression via `decode_ima_adpcm_e8_i16(...)` in conjunction with `web/openwebrx/ima_adpcm.js`
- mono and IQ/stereo modes
- old and new resampler paths, with mobile often forced onto the simpler path

Compression state changes or IQ/non-IQ transitions trigger a reconnect/rebuild of the audio chain so that channel count, buffering, and decoder state stay coherent.

## Buffering And Robustness

The audio subsystem is explicitly defensive.

It manages:

- prepared output queues (`audio_prepared_buffers`, `audio_prepared_buffers2`)
- adaptive min/max buffered audio thresholds
- underrun and overrun detection
- trimming of overgrown queues in `audio_periodic()`
- reconnection when Firefox goes silent
- restart handling when the server asks for audio reinit

The watchdog logic includes:

- Firefox silence detection in `audio_watchdog_process()`
- Firefox stalled-callback detection in `audio_periodic()`
- `snd_send("SET reinit")` to restart server-side audio state if needed

## UI Coupling

Audio is not isolated from UI state. During playback it also drives:

- S-meter updates (`owrx.sMeter_dBm...`)
- squelch UI synchronization
- ADC overflow indication
- extension audio hooks via `extint_audio_data(...)`
- optional audio FFT generation for the display path

This is why audio, spectrum, and extension code are tightly linked.

## Extension UI Integration

Extension support is centered on `web/extensions/ext.js` plus one directory per extension under `web/extensions/`.

## Extension Discovery And Menu Integration

Extension names are provided by the backend and parsed into `extint_names` by `extint_list_json()`.

The extension menu is built by:

- `extint_names_enum()`
- `extint_select_build_menu()`

These routines:

- enumerate extension IDs supplied by the backend
- hide selected developer/internal extensions unless debugging is enabled
- apply per-extension enable flags from configuration
- expose local-only behavior for some extensions

## Extension Loading

Extensions are loaded dynamically, not bundled up front.

When the user selects an extension:

1. `extint_select()` chooses the extension and ensures the extension socket exists
2. `ext_send('SET ext_is_locked_status')` or initial setup requests current state
3. on `ext_client_init`, `extint_focus()` runs
4. `extint_focus()` calls `kiwi_load_js_dir('extensions/'+ ext_name +'/'+ ext_name, ['.js', '.css'], ...)`
5. after load, it calls `<ext_name>_main()`

Dynamic loading is orchestrated by `kiwi_load_js()` in `web/kiwi/kiwi.js`, which:

- appends scripts and stylesheets to `document.head`
- avoids loading duplicates with `kiwi.loaded_files`
- uses `kiwi/kiwi_js_load.js` as a final callback trampoline once all requested JS files have run

## Extension Transport

Extensions get their own WebSocket via `extint_connect_server()`:

- `open_websocket('EXT', extint_open_ws_cb, null, extint_msg_cb)`

Client-side helpers include:

- `ext_send(msg)` for normal extension commands
- `ext_send_cfg(...)` for large fragmented config saves over WebSocket
- `ext_switch_to_client(...)` to switch the backend extension focus to the current client

`ext_send_cfg()` explicitly handles WebSocket fragmentation for large messages, because some extension config payloads are too large to send as a single encoded command reliably.

## Extension UI Hosting

Extensions can render into two places:

- the normal extension controls panel (`id-ext-controls`)
- the main data area (`id-ext-data-container`) when they need a larger display canvas

`ext_panel_show()` / `extint_panel_show()`:

- create or reuse the extension controls panel
- optionally hide the normal top/spectrum region
- mount extension HTML into the proper container
- install extension close/help behavior
- restore base layout on close

Some extensions can also take over the RF tab (`extint.use_rf_tab`), which is a specialized integration path rather than the normal floating panel.

## Extension Families

The extension tree includes both decoders and UI helpers, for example:

- decoders/analyzers: `DRM`, `FT8`, `FAX`, `SSTV`, `CW_decoder`, `CW_skimmer`, `HFDL`, `NAVTEX`, `Loran_C`, `IQ_display`, `FFT`, `S_meter`, `timecode`, `s4285`, `wspr`
- platform/features: `noise_blank`, `noise_filter`, `ant_switch`, `prefs`, `colormap`, `waterfall`, `iframe`
- examples/dev: `example`, `devl`

The architecture expects each extension to supply the usual focus/blur/main/help callbacks consumed by `ext.js`.

## Mobile And Responsive Design Features

The UI is not based on modern CSS flexbox/grid components, but it still includes substantial mobile-aware behavior.

## HTML/CSS Responsiveness

Both main pages declare:

- `<meta name="viewport" content="width=device-width, initial-scale=1">`

Layout is then adapted mainly through JavaScript plus CSS absolute positioning.

Examples:

- `openwebrx_resize()` recomputes display layout whenever the window changes
- `orientation_change()` updates waterfall/control layout on mobile rotation
- `resize_waterfall_container()` resizes the waterfall scroll area to fit the remaining viewport height
- many animations shorten to effectively immediate transitions on mobile (`kiwi_isMobile()? 1:1000`)

## Mobile Detection And Heuristics

`ext_mobile_info(last)` in `web/extensions/ext.js` captures the shared mobile layout heuristic:

- uses `window.innerWidth` and `window.innerHeight`
- treats popup keyboard cases specially to avoid false orientation changes
- derives `isPortrait`, `iPad`, `small`, and `narrow`

These flags are then used across the UI for:

- compact panel behavior
- different drag thresholds
- tooltip offsets
- hiding the readme panel by default on mobile
- forcing simpler resampling/audio paths

## Mobile-Specific UI Behavior

Notable examples in `openwebrx.js` and related code:

- readme/help panels are suppressed or simplified on mobile
- control panel is forced visible after orientation changes
- smaller screens use different click/drag thresholds and tooltip placement
- the startup play overlay says “Tap to start OpenWebRX” on mobile versus “Click” on desktop
- audio buffering/resampling paths are simplified on mobile to reduce CPU cost

The admin UI also adapts:

- `admin.console.isMobile = kiwi_isMobile()`
- console/log sizing logic changes in `console_resize()` and `log_resize()`

## Browser Compatibility Considerations

The Web-888 UI contains a lot of explicit browser-specific handling.

## Supported Browser Assumptions

The built-in help text in `openwebrx.js` states:

- Windows: Firefox, Chrome, Edge work; IE does not
- Mac/Linux: Safari, Firefox, Chrome, Opera should work

This matches the implementation style: modern browser APIs are assumed, but numerous compatibility shims and workarounds remain.

## Audio Compatibility

The audio stack explicitly relies on Web Audio:

- `window.AudioContext = window.AudioContext || window.webkitAudioContext`

If Web Audio is unavailable, the UI shows a hard error.

Special cases include:

- Safari/iOS and newer Safari/Chrome desktop requiring a user gesture before audio starts; the UI shows a play overlay and creates a small `AudioContext` to unlock playback
- LG SmartTV browsers requiring a gain node in the graph before output works
- fallback messaging for unsupported or too-old browsers

`audio.js` also includes a compatibility fallback for missing `AudioBuffer.prototype.copyToChannel` in very old browsers.

## Firefox Workarounds

Firefox gets special handling in multiple places:

- font/size adjustments for some canvas text rendering in `openwebrx.js`
- silence watchdog and forced reconnect logic in `audio.js`
- detection of stalled audio callback flow and full reinit
- admin console key handling to suppress Firefox quick-find behavior

## Safari Workarounds

Safari-specific branches appear for:

- audio unlock behavior before playback can begin
- text and layout adjustments in the display code
- cache behavior motivation for image resources (e.g. avoiding flashing)

## SmartTV / Legacy Browser Checks

`kiwi_bodyonload()` rejects old LG SmartTV Chrome builds (`kiwi_isChrome() < 87`).

The shortcut/help logic also disables or limits some advanced UI features when running on:

- mobile devices
- older Firefox/Chrome/Opera versions

## Backend/UI Communication Summary

The Web-888 web interface talks to the backend through four primary mechanisms.

## 1. Static Asset Serving

Handled by `web/web.cpp` and `web/web_server.cpp`:

- HTML/CSS/JS/image files served from embedded data or filesystem
- JS files version-tagged at serve time
- gzip and cache policy applied selectively

## 2. Server-Side HTML Parameter Injection

`%[...]` substitutions in HTML are resolved server-side before the browser sees the page.

Examples include:

- `%[GEN_LIST_CSS]`
- `%[GEN_LIST_JS]`
- `%[EXT_LIST_JS]`
- `%[HTML_HEAD]`

This lets runtime config alter the page template without a build step.

## 3. AJAX Endpoints

When a request is not matched to a static asset, `web_request()` can forward it to `rx_server_ajax(...)` for text-based responses.

AJAX is used sparingly relative to WebSockets and is deliberately not cached like normal files.

## 4. WebSockets

WebSockets are the primary real-time control/data path.

Sockets in the browser:

- `SND`: sound stream and some control/status
- `W/F`: waterfall stream and some control/status
- `EXT`: extension control/data
- `ADM`/admin-equivalent: admin interface messaging

Over these sockets, the browser sends `SET ...` commands and receives:

- binary sound/waterfall payloads
- textual control messages
- extension/admin-specific events

This split keeps the latency-sensitive SDR interactions off AJAX and lets audio/waterfall stay synchronized with receiver state.

## Key Architectural Characteristics

The Web-888 frontend has several defining traits:

- it is a classic handcrafted single-page app built from global JS modules rather than a framework
- rendering is canvas-heavy for spectrum, waterfall, and overlays
- dynamic script/CSS loading is central to extension support
- the server is deeply involved in page assembly through HTML substitution and asset versioning
- WebSockets are the primary runtime protocol for receiver interaction
- mobile support is implemented mostly with runtime heuristics and imperative resize logic rather than purely responsive CSS
- browser compatibility is maintained with explicit per-browser workarounds, especially for audio

## Practical Takeaway

For anyone modifying the Web-888 web interface, the most important files are:

- `web/openwebrx/index.html`: page structure
- `web/openwebrx/openwebrx.js`: receiver UI, waterfall, spectrum, controls
- `web/openwebrx/audio.js`: browser audio pipeline
- `web/extensions/ext.js`: extension framework
- `web/kiwi/kiwi.js`: bootstrap, auth, dynamic loading, global config/state
- `web/kiwi/admin.js`: admin interface controller
- `web/openwebrx/openwebrx.css` and `web/kiwi/kiwi.css`: layout and shared styling
- `web/web.cpp`, `web/web_server.cpp`: backend web delivery and WebSocket/file plumbing

Together these files form a tightly integrated SDR web client where UI, transport, and signal-display logic are all coupled around the receiver’s real-time constraints.
