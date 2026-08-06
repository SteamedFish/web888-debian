# TODO — web888-debian

Open work items. For defects/limitations see
[`KNOWN-ISSUES.md`](KNOWN-ISSUES.md); for what already works see the
feature list below and the repo-root README. All changes must be recorded
in [`CHANGELOG.md`](CHANGELOG.md) (see AGENTS.md).

## Hardware gates (pending board access)

- [ ] **Kernel/U-Boot chain (step 6)**
  - [ ] hw-test smoke (`scripts/hw-test/`), USB-WiFi probe, websdr E2E
        with bitstream on the 6.12 kernel (P1.6 remainder — board came
        online with EEPROM MAC, 0 failed units, drivers/fclk ABI OK)
  - [ ] Blind HW gate for full U-Boot as SSBL (P2.5 — QEMU-verified from
        U-Boot onward; FSBL handoff is not emulatable)
  - [ ] Kernel-update SOP final docs sync (P3)
- [ ] **Red Pitaya coexistence (step 4)**
  - [ ] Round-trip switching ×10 (60 s :8073 poll — websdr needs ~33 s
        after RF-active RP apps), reboot-default check, 1 h soak (P4.5)
  - [ ] Docs close-out (P5)
- [ ] **WebSDR deeper HW gate (step 2/3)**: reboot-loop ×3 + multi-hour
      soak on a fresh image (audio + waterfall as web888 user via systemd;
      XDG paths; no-update verified)

## GPS recovery

- [x] Chip-config actions in [`KNOWN-ISSUES.md`](KNOWN-ISSUES.md) §1
      executed (NMEA re-enabled, UBX NAV output disabled, cold start) via
      new tool `scripts/hw-test/atgm336h-fix.py`.
- [x] Root cause fixed: gpsd `-b` (read-only) in `configure-rootfs.sh`
      `GPSD_OPTIONS` so gpsd 3.25 stops rewriting the ATGM336H to UBX-only.
- [ ] Operator end-to-end verification: satellite fix → gpsd SKY/TPV →
      chrony GPS+PPS refclocks → WebSDR-admin GPS page (needs antenna sky
      view; dev unit's location had only 3–4 marginal SVs at test time).

## KiwiSDR upstream alignment (step 5)

- [ ] B.4: port `rx_snr` (next feature epic after the completed B.1
      mongoose 7.14 and B.2 admin re-sync)
- [ ] Optional, if their value case materialises: ipset blacklist, FAX
      recording rework, kiwi_output_chars console rework
- Cherry-pick surface otherwise exhausted as of KiwiSDR v1.902 — see
  `web888-kiwisdr-cherry-pick-plan.md` and `config/websdr/cherry-picks/`

## Red Pitaya follow-ups

- [ ] U2: upstream userspace cherry-picks survey (pavel-demin 2024-12 →
      now, via `config/redpitaya/patches/`)
- [ ] U3: Vivado 2023.1 bitstream rebuild evaluation (needs operator
      approval for the system-level Vivado install)
- [ ] U4: FT8/WSPR digi apps (separate deb if demand)
- [ ] U5: watch `RaspSDR/red-pitaya-notes` for vendor updates

## Networking / discovery

- [ ] avahi/mDNS support on the Debian image — discover the device as
      `web888.local` instead of MAC-prefix scanning (currently DHCP-only
      via ifupdown, no avahi)

## Distribution

- [x] Push the project repository to GitHub (done:
      <https://github.com/SteamedFish/web888-debian>)
- [ ] GitHub Actions: build/publish flashable images via Releases
- [ ] GitHub Actions: build Debian packages, maintain an APT repository
      for updates without reflashing

---

## Completed feature set

Everything below is implemented and verified (QEMU gate minimum; most
items also verified on hardware). Historical process detail lives on the
pre-cleanup archive branch.

- **Debian boot (step 1)** — standard Debian trixie armhf from the TF
  card: debootstrap rootfs on ext4, stock FSBL + repacked boot.bin
  (bootgen), linux-xlnx 6.6 kernel with Web-888 DTB, busybox initramfs
  switch_root, ifupdown DHCP, openssh, first-boot growfs
  (growpart + `x-systemd.growfs`), QEMU gate before every flash.
- **Memory/flash optimisations (step 1.5)** — zram swap (lzo-rle, 100 %
  RAM) via zram-tools, log2ram + journald cap, IO scheduler `none` for
  the TF card, ondemand cpufreq with tunables + user-switchable governor
  (`/etc/default/web888-cpufreq`).
- **SDR drivers (step 2)** — `xilinx_devcfg` forward-ported from
  Xilinx v2016.4 (`/dev/xdevcfg` FPGA loading) and new `zynqsdr` driver
  (full 15-ioctl ABI, bus-master DMA data plane, zero-PL-MMIO probe)
  in `config/kernel/`; live ADC data verified on hardware.
- **WebSDR on Debian (step 3/3.5)** — `web888-websdr` deb (bit-
  reproducible): systemd hardening, XDG paths, no version check,
  bitstream-only update path, gpsd+chrony GPS plumbing, interfaces.d
  network writer via sudo root helpers, sudo poweroff, openssh-server,
  nft/iptables support; audio + waterfall verified end-to-end on
  hardware; Leaflet bundled locally (no CDN).
- **KiwiSDR upstream alignment (step 5)** — 46 cherry-picks
  (`config/websdr/cherry-picks/`, incl. security fixes), mongoose
  5.6→7.14 wholesale upgrade (B.1), admin stack re-sync to KiwiSDR
  v1.902 (B.2); each batch built + deployed + hardware-verified.
- **Red Pitaya coexistence (step 4)** — `web888-redpitaya` deb:
  4 vendored bitstreams + source-built apps (sdr_receiver,
  sdr_receiver_hpsdr, sdr_transceiver_wide, si5351-init), `web888-mode`
  runtime switching (websdr ↔ RP apps), hpsdr discovery/streaming/ATT
  verified, Si5351 reset handling verified; crash-loop guards in the
  systemd template.
- **Debian-source kernel + full U-Boot (step 6)** — host-built pinned
  kernel deb `6.12.100-web888` (Debian linux-source-6.12 + armmp config
  + Web-888 drivers + ULPI patch), full U-Boot v2026.07 as SSBL behind
  the stock FSBL, kernel/dtb loaded from FAT via boot.scr/uEnv.txt;
  QEMU gates passed (linux-xlnx 6.6 chain kept buildable as rollback).
