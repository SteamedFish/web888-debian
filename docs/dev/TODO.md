# TODO — web888-debian

Open work items. For defects/limitations see
[`KNOWN-ISSUES.md`](KNOWN-ISSUES.md); for what already works see the
feature list below and the repo-root README. All changes must be recorded
in [`CHANGELOG.md`](CHANGELOG.md) (see AGENTS.md).

## Hardware gates (pending board access)

- [ ] **Kernel/U-Boot chain (step 6)**
  - [x] hw-test smoke (`scripts/hw-test/` `zynqsdr-smoke hw` →
        `ZYNQSDR_SMOKE_OK`) and websdr E2E with bitstream on the 6.12
        kernel (`scripts/hw-test/ws-e2e.py` → audio + waterfall frames)
  - [ ] USB-WiFi probe on the 6.12 kernel (needs a USB dongle plugged in)
  - [x] Blind HW gate for full U-Boot as SSBL (P2.5 — QEMU-verified from
        U-Boot onward; FSBL handoff is not emulatable). Done 2026-08-11:
        flashed `web888-debian-uboot.img` boots on hardware (twice, incl.
        controlled reboot), factory MAC stable across reboot (same DHCP
        lease), websdr serves HTTP 200 on :8073, zero journal errors.
  - [ ] Kernel-update SOP final docs sync (P3)
- [~] **web888-boot deb (bootloader lifecycle)**: FSBL + U-Boot + boot.scr +
      uEnv.txt + web888.dtb shipped as `web888-boot_2026.07-2_armhf.deb`
      (payload /usr/lib/web888-boot/). build-all installs the deb into the
      rootfs chroot (postinst skips — no /boot/boot.bin), build-image copies
      the payload to FAT; on-device upgrades go through apt (postinst does
      temp-file+sync+rename onto the vfat /boot, keeps one .bak, never
      touches uEnv.txt, refuses non-Zynq payloads and non-`d00dfeed` dtbs). Verified: postinst
      dry-run matrix (install/upgrade/refusal), QEMU boot of the exact deb
      boot.bin, on-device postinst execution. Still owed: freshly-flashed
      image hardware boot, apt-repo publication + docs close-out
      (`docs/research/github-ci-apt-repo-research.md` §2.8)
- [ ] **Red Pitaya coexistence (step 4)**
  - [x] Round-trip switching ×10 (60 s :8073 poll — websdr needs ~33 s
        after RF-active RP apps), reboot-default check, 1 h soak (P4.5 —
        `scripts/hw-test/hw-roundtrip.sh` → `ROUNDTRIP_OK`; surfaced and
        cleared a stale-deb deployment gap, see CHANGELOG 2026-08-07)
  - [ ] Docs close-out (P5)
- [~] **WebSDR deeper HW gate (step 2/3)**: reboot-loop ×3 + 2 h soak
      passed on the dev install (`scripts/hw-test/hw-reboot-loop.sh` →
      `REBOOTLOOP_OK`: 3/3 boots self-heal as the web888 user at ~65 s,
      24/24 soak checks with zero error-level journal lines, final
      `ws-e2e.py` audio + waterfall OK). Still owed: the same loop on a
      **freshly flashed** image (needs the card in the host reader)

## KiwiSDR upstream alignment (step 5)

- [x] B.4: port `rx_snr` — done as 0149 (framework imported wholesale and
      adapted: MAX_ZOOM, minute/custom intervals, custom band, ham/BCB,
      VDSL filter, full admin.js SNR options UI + kiwi.js snr_stats MSG
      handling); ant_switch SNR coupling followed as 0150 (re-measure on
      antenna change, server-side hook). Upstream's SNR-gated default
      antenna selection (ant_switch.antNdefault, ground_when_no_users)
      evaluated and rejected — needs upstream's whole ant_switch backend
      framework for a public-multi-antenna-site feature.
- [x] FAX recording rework — cherry-picked as 0147 (upstream f98b3779,
      post-v1.902): fixed-filename server-side recording (info leak)
      replaced by a browser-side Save button (canvas JPEG download)
- [x] **Fix /admin websocket frame corruption** — done as
      `0151-kiwi-send-msg-via-s2c-nbuf-queue.patch` (built 2026.730-7,
      deployed, verified: `scripts/test-websocket-frames.py` 4×60 s clean
      + dual-tab browser soak with zero console errors; see KNOWN-ISSUES
      §6 and `mongoose-websocket-frame-corruption-investigation.md`)
- [ ] Optional, if their value case materialises: ipset blacklist,
      kiwi_output_chars console rework
- Cherry-pick surface otherwise exhausted as of KiwiSDR v1.902 — see
  `web888-kiwisdr-cherry-pick-plan.md` and `config/websdr/cherry-picks/`

## Red Pitaya follow-ups

- [ ] U2: upstream userspace cherry-picks survey (pavel-demin 2024-12 →
      now, via `config/redpitaya/patches/`)
- [ ] U3: Vivado 2023.1 bitstream rebuild evaluation (needs operator
      approval for the system-level Vivado install)
- [ ] U4: FT8/WSPR digi apps (separate deb if demand)
- [ ] U5: watch `RaspSDR/red-pitaya-notes` for vendor updates

## Source-built FSBL (de-blob the boot chain)

- [x] **F1: build the FSBL from source instead of reusing the stock binary.**
      **DONE 2026-08-15** via the extraction path in
      `docs/dev/fsbl-source-build-plan.md` (Tasks 1-4+6; Task 5 provenance
      pass skipped — no Vivado). `scripts/build-fsbl.sh` builds the FSBL from
      the vendored embeddedsw @ `xilinx_v2023.1` subset + RaspSDR hooks;
      `FSBL=source` is the default in `scripts/build-bootbin.sh`
      (`FSBL=stock` = escape hatch). Hardware-verified 2026-08-15 (MAC ==
      EEPROM, MIO49/MIO10 driven per hooks, WebSDR streaming, memtester
      350M clean, dmesg clean). Original feasibility notes below:
      Feasibility confirmed 2026-08-08 against the pinned RaspSDR fork
      (`work/redpitaya-src`): the stock FSBL is fully reconstructible from
      open sources —
      - FSBL app + standalone BSP: Xilinx `zynq_fsbl` template generated by
        HSI (`scripts/fsbl.tcl` in the fork; `hsi generate_app -app zynq_fsbl`)
      - Web-888 PS7 config == Red Pitaya board preset `cfg/red_pitaya.xml`
        (68 lines; DDR = MT41J256M16 16-bit = 512 MB; ENET0 MIO 16-27 + MDIO
        52-53, I2C0 MIO 50-51, UART0 MIO 14-15, UART1 MIO 8-9, USB0, SD0
        MIO 40-45). Same preset drives both vendor boot chains — consistent
        with the identical FSBL binary in stock Web-888 and RaspSDR firmware.
      - RaspSDR hooks: `patches/red_pitaya_fsbl_hooks.c` (Si5351 122.88 MHz
        init, EEPROM MAC read, `refclock=` override) + `patches/fsbl.patch`
      - Packaging: existing bootgen flow (`scripts/build-bootbin.sh`) — only
        the `[bootloader]` input file changes.

      **Plan (2026-08-14): `docs/dev/fsbl-source-build-plan.md`** — refines the
      sub-items below based on completed research: vendor the embeddedsw
      `xilinx_v2023.1` subset and build "from git" with host
      `arm-none-eabi-gcc` (no Vitis/xsct needed at all); ps7_init via
      stock-binary extraction as the primary path (zero approvals, values are
      hardware-proven), with the HSI/XSA route demoted to an optional
      provenance pass (Task 5, still tied to the U3 install approval).

  - [ ] One-time: generate `ps7_init.c/h` + BSP tree with Vivado 2023.1 HSI
        (`scripts/project.tcl` → `scripts/hwdef.tcl` — XSA export only, **no
        bitstream synthesis** — then `xsct scripts/fsbl.tcl`); shares the
        system-level Vivado install with U3 (needs operator approval).
        **Optional provenance pass only** (plan Task 5) — the extraction
        path already shipped and is hardware-verified.
  - [ ] Vendor the generated `ps7_init` + BSP sources; rebuild the FSBL
        per-release with `arm-none-eabi-gcc` (env-setup addition — system
        package, ask operator). No Xilinx tools needed after the one-time
        generation. **Superseded** — ps7_init came from stock-binary
        extraction; the from-git build needs no Xilinx tools at all.
  - [ ] Verification: byte-diff against `work/stock/fsbl.bin` (same Vivado
        2023.1 toolchain → near-identical expected, timestamps/toolchain
        build IDs aside); QEMU gate covers U-Boot onward only (FSBL handoff
        not emulatable — KNOWN-ISSUES); blind HW flash with the stock card
        as rollback. Benefit: removes the last closed binary in the boot
        chain and gives boot-time control of Si5351/MAC handling.
        **Done differently 2026-08-15** — verified by 21/21 ps7_init array
        byte-compare + the full hardware battery (not a whole-binary diff).

## Distribution

- [x] Push the project repository to GitHub (done:
      <https://github.com/SteamedFish/web888-debian>)
- [x] GitHub Actions: build/publish flashable images via Releases
- [x] GitHub Actions: build Debian packages, maintain an APT repository
      for updates without reflashing — **implemented** on `ci/apt-repo`
      (workflows + third-party packaging + gh-pages flat repo); goes
      live after the one-time GitHub setup in
      `docs/dev/github-ci-apt-repo.md`. Remaining: activate on GitHub,
      verify first green runs, Part 2 (image build consuming the repo,
      QEMU gate before web888-boot publish, web888-repo keyring deb)

## ext4 /boot refactor (drop the FAT zImage copy)

- [ ] Move kernel loading off FAT p1 onto the ext4 rootfs, Armbian-style:
      U-Boot `ext4load`s `/boot/zImage` as a symlink to the installed
      `vmlinuz-<krel>`; FAT keeps only boot.bin/boot.scr/dtb/uEnv
      (RPi-style, mounted at /boot/firmware). The kernel deb payload then
      *is* the boot file, which retires the zz-web888-zimage copy hook and
      the install-debs-apt.sh zImage export seam, and enables versioned
      kernels with a real fallback menu. Touches `config/u-boot/boot.cmd`,
      fstab, image layout, QEMU/CI flows, user docs, uEnv semantics;
      requires QEMU + hardware validation. Decided against Debian
      flash-kernel (framework mismatch: uImage/boot.scr-generation
      conventions do not fit our boot.cmd). Current FAT + copy-hook design
      (raspi-firmware pattern) stays as the baseline until this lands.

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
- **mDNS discovery** — avahi-daemon + libnss-mdns on the image; the device
  advertises and resolves as `web888.local` (IPv4 + IPv6). Verified on
  hardware including across a reboot; MAC-prefix scanning remains the
  fallback.
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
  QEMU gates passed. `build-all.sh` defaults to this chain
  (`CHAIN=uboot`); `CHAIN=stub KERNEL=6.6` keeps the stub-SSBL +
  linux-xlnx 6.6 chain buildable as rollback.
  U-Boot plants the factory MAC from the board EEPROM into `ethaddr`
  before ethernet probes (register-level read — the r1p10 cdns driver's
  multi-message read is broken by the HOLD-bit erratum; see CHANGELOG
  2026-08-10).
