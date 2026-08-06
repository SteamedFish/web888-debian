# Stock firmware artifacts (read-only, do not edit)

Extracted from the official Web-888 firmware during the 2026-07-29 stock-analysis
session (held in `.tmp/web888-*`, now vendored here).

- `websdr_hf.bit` — FPGA bitstream, HF mode. Xilinx BIT, 7z010clg400, Vivado 2023.1,
  built 2025/04/13 14:07:09. sha256 `cacb19681e1c4337176f3060956989ba7cf85d4e3a599eddb2c8e57fabc0b3d6`
- `websdr_vhf.bit` — FPGA bitstream, VHF/Airband mode. built 2025/04/13 14:21:08.
  sha256 `298415f07d2cd096344e6f733be7206ec41da324d8bd6d5e8b6e17e1c2e7513e`
- `websdr.bin` — stock userspace (musl/Alpine gcc 13.2.1 PIE, stripped). Regression
  reference only — step 2 builds websdr from RaspSDR/server source instead.
  sha256 `d586ce037d10866be0fe48457f962c42a0c04ecc8508923d7497c7b6de760176`

Not published in any RaspSDR repo (checked 2026-07-30); these are the authoritative copies.
