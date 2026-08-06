# Red Pitaya app bitstreams + app landing pages (read-only, do not edit)

Vendored from the vendor's Red Pitaya firmware ZIP
`red-pitaya-alpine-3.20-armv7-20241228.zip`
(sha256 `e8052136cfa8dd68b06c6e6ca961dee9aff00b4c01c66d2dfe3992c0be04a0a8`,
100,627,237 bytes — see `docs/research/red-pitaya-firmware.md`; pristine copy kept in
`.tmp/redpitaya/`), extracted at `apps/<app>/`.

These are the bitstreams that ship on production Web-888 hardware, built by the
vendor with Vivado 2023.1 for the 7z010clg400. v1 of `web888-redpitaya` uses
them as-is (plan D3); rebuilding from FPGA source is follow-up §7 U3 only.

| File | Xilinx BIT header (part / build date) | sha256 |
|---|---|---|
| `led_blinker.bit` | 7z010clg400, 2024/12/09 17:57:12 | `2b307ab70b4d7064bdd2e8338fead4c66b23ac60d71ca7c55083da0573f86160` |
| `sdr_receiver.bit` | 7z010clg400, 2024/12/01 00:48:07 | `61bb870aeb02bf171c22a733dd1fd90c0a93f96308be8f6258fb94a64579a03d` |
| `sdr_receiver_hpsdr.bit` | 7z010clg400, 2024/12/01 00:45:18 | `93c54b1229ab65b588b01b027ce2e02472c6d7932bc1f01c157ca57060f49649` |
| `sdr_transceiver_wide.bit` | 7z010clg400, 2024/12/01 00:37:42 | `1b0512eeea5cc3ea72b8891f56eef0b5df1066cf2de26969b51b768e9d0d0664` |

`<app>.index.html` — the vendor's per-app landing page, shipped as
informational static data at `/usr/share/web888-redpitaya/apps/<app>/index.html`
(plan D4). Not a functional web UI in v1.

The matching userspace servers are NOT vendored — they are built from source
(RaspSDR/red-pitaya-notes @ `da1a7e3a`, see `config/redpitaya/upstream.pin`).
The C sources in `projects/<app>/server/` of that pin are byte-identical to
the sources shipped inside the vendor ZIP (verified 2026-08-05).

License: MIT (RaspSDR/red-pitaya-notes `LICENSE`, copyright Pavel Demin
2014-present) — compatible with the project's GPL-2.0-or-later; this directory
retains the upstream MIT license.
