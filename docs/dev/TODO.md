# TODO — web888-debian

Open work items. For defects/limitations see
[`KNOWN-ISSUES.md`](KNOWN-ISSUES.md); for what already works see the
feature list below and the repo-root README. All changes must be recorded
in [`CHANGELOG.md`](CHANGELOG.md) (see AGENTS.md).

## Hardware gates (pending board access)

- [ ] **Fresh-image hardware validation** — one reflash of the current CI
      image covers all pending hardware gates at once: `systemctl --failed`
      must come back empty (KNOWN-ISSUES §7: first-boot preset fix +
      `80-web888.preset` rename pending reflash verification), the ext4
      /boot layout must boot on hardware (CI QEMU gates pass; the FSBL
      handoff is QEMU-unreachable, KNOWN-ISSUES §5), and the reboot-loop +
      websdr E2E gates (`scripts/hw-test/hw-reboot-loop.sh`,
      `ws-e2e.py`) should then be re-run on the fresh image. While on the
      device, also check the 0153 fix (KNOWN-ISSUES §4: no 1 Hz
      `ADMIN: unknown command` spam with an admin status tab open) and the
      KNOWN-ISSUES §8 powered-hub USB-WiFi rerun.

## KiwiSDR upstream alignment (step 5)

- [ ] Optional, if their value case materialises: ipset blacklist,
      kiwi_output_chars console rework
- Cherry-pick surface otherwise exhausted as of KiwiSDR v1.902 (incl.
  post-v1.902 fixes through 0153) — see
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
      DONE 2026-08-15 via the extraction path in
      `docs/dev/fsbl-source-build-plan.md` (Tasks 1-4+6): vendored
      embeddedsw @ `xilinx_v2023.1` + RaspSDR hooks, ps7_init extracted
      from the stock binary (21/21 arrays byte-verified);
      `FSBL=source` is the default in `scripts/build-bootbin.sh`
      (`FSBL=stock` = escape hatch). Hardware-verified 2026-08-15
      (MAC == EEPROM, MIO49/MIO10 driven per hooks, WebSDR streaming,
      memtester 350M clean, dmesg clean).
- [ ] Optional provenance pass only (plan Task 5): generate `ps7_init.c/h`
      + BSP tree with Vivado 2023.1 HSI and byte-compare against the
      extraction; shares the system-level Vivado install with U3 (needs
      operator approval). The extraction path shipped and is
      hardware-verified — this is nice-to-have provenance, not a gate.

## Distribution

- [x] Push the project repository to GitHub (done:
      <https://github.com/SteamedFish/web888-debian>)
- [x] GitHub Actions: build/publish flashable images via Releases
      (`build-image.yml`, live 2026-08-17; auto-refreshed by every deb
      publish, permalink `/releases/latest/download/web888-debian-uboot.img.xz`)
- [x] GitHub Actions: build Debian packages, maintain an APT repository
      for updates without reflashing — live 2026-08-16 (workflow set +
      third-party packaging + gh-pages flat repo at
      `web888.steamedfish.org/apt`; image build consuming the repo and the
      pre-publish QEMU smoke gates for kernel/boot debs landed 2026-08-17).
      Setup/architecture: `docs/dev/github-ci-apt-repo.md`
- [ ] `web888-repo` keyring/sources deb (ships the APT-repo pubkey +
      sources.list as a package instead of baking them into the image)

---

## Completed feature set

Everything below is implemented and verified (QEMU gate minimum; most
items also verified on hardware). Historical process detail lives on the
pre-cleanup archive branch.

- **Debian boot (step 1)** — standard Debian trixie armhf from the TF
  card: debootstrap rootfs on ext4, repacked boot.bin (source-built FSBL
  + bootgen), ifupdown DHCP, openssh, first-boot growfs
  (growpart + `x-systemd.growfs`), QEMU gate before every flash. (The
  busybox initramfs switch_root stage belongs to the stub rollback chain;
  the U-Boot chain boots the ext4 rootfs directly.)
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
- **KiwiSDR upstream alignment (step 5)** — cherry-picks through 0153
  (`config/websdr/cherry-picks/`, incl. security fixes), mongoose
  5.6→7.14 wholesale upgrade (B.1), admin stack re-sync to KiwiSDR
  v1.902 (B.2); each batch built + deployed + hardware-verified.
- **Red Pitaya coexistence (step 4)** — `web888-redpitaya` deb:
  4 vendored bitstreams + source-built apps (sdr_receiver,
  sdr_receiver_hpsdr, sdr_transceiver_wide, si5351-init), `web888-mode`
  runtime switching (websdr ↔ RP apps), hpsdr discovery/streaming/ATT
  verified, Si5351 reset handling verified; crash-loop guards in the
  systemd template. Round-trip gate ×10 + 1 h soak passed on hardware
  (2026-08-07).
- **Debian-source kernel + full U-Boot (step 6)** — host-built pinned
  kernel deb `6.12.100-web888` (Debian linux-source-6.12 + armmp config
  + Web-888 drivers + ULPI patch, lean config default), full U-Boot
  v2026.07 as SSBL behind the source-built FSBL; boot.scr/uEnv.txt/dtb
  on the FAT firmware partition (`/boot/firmware`), kernel ext4-loaded
  from the rootfs `/boot/zImage` symlink; QEMU gates passed, hardware
  smoke/E2E/round-trip/reboot-loop passed on the dev unit.
  `build-all.sh` defaults to this chain
  (`CHAIN=uboot`); `CHAIN=stub KERNEL=6.6` keeps the stub-SSBL +
  linux-xlnx 6.6 chain buildable as rollback.
  U-Boot plants the factory MAC from the board EEPROM into `ethaddr`
  before ethernet probes (register-level read — the r1p10 cdns driver's
  multi-message read is broken by the HOLD-bit erratum; see CHANGELOG
  2026-08-10).
- **Bootloader as a deb (`web888-boot`)** — FSBL + U-Boot + boot.scr +
  uEnv.txt + web888.dtb payload (`/usr/lib/web888-boot/`), pre-publish
  QEMU smoke gate in CI, published on the APT repo; on-device upgrades
  via apt (postinst does temp-file+sync+rename onto the vfat
  /boot/firmware, keeps one `.bak`, never touches uEnv.txt, refuses
  non-Zynq payloads and non-`d00dfeed` dtbs). Verified: postinst
  dry-run matrix, QEMU boot of the exact deb boot.bin, on-device
  postinst execution, fresh-flash hardware boot (2026-08-18).
- **CI distribution** — GitHub Actions builds every deb (kernel, websdr,
  redpitaya, boot, third-party), publishes the signed flat APT repo on
  gh-pages + auto-refreshed flashable-image Releases, with daily
  upstream/dependency watches; see `docs/dev/github-ci-apt-repo.md`.
