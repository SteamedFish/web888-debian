# Red Pitaya Upstream Delta — RaspSDR fork vs pavel-demin/red-pitaya-notes

> **Step 4 §7 U1 deliverable.** Exact Web-888-only changes in our pinned fork
> `RaspSDR/red-pitaya-notes @ da1a7e3a` (2025-04-30) versus upstream
> `pavel-demin/red-pitaya-notes @ da1a7e3a`'s same commit (the fork point).
> Read alongside [`redpitaya-websdr-coexistence.md`](redpitaya-websdr-coexistence.md)
> (the research verdict that chose this fork) and the Step 4 plan §7.

## Fork topology

```
pavel-demin/red-pitaya-notes  (PRs to #1118+, HEAD cc13b6aa 2026-07-07)
        │
        │   merge-base = 3c0e3d98 (2024-11-05 "fix QRegExp argument in vna.py")
        │   (RaspSDR vendor forked here)
        │
        ├── 36 commits ahead on RaspSDR master   ← Web-888 hardware port (Howard Su + JerryTech)
        │   da1a7e3a (2025-04-30) ←── HEAD (our pin)
        │
        └── 88 commits ahead on pavel-demin side  ← bitstream/HLD/toolchain churn
            cc13b6aa (2026-07-07)
```

**Diverged state confirmed via GitHub compare
`pavel-demin:da1a7e3a…pavel-demin:cc13b6aa`:** 88 ahead, 36 behind, status
`diverged`. Our pin sits at the **fork point on the RaspSDR side** but is
~19 months stale on the pavel-demin side.

**Pavel-demin 2024-12 → 2026-07-07 (since fork point):** 9 non-HDL commits
total (1 bugfix in `patches/cma.c`; 1 host-Python fix; 7 build-tooling/Alpine/kernel
bump). See [`redpitaya-websdr-coexistence.md`](redpitaya-websdr-coexistence.md)
§3 and §4 for the corresponding "no candidates for v1 cherry-pick" verdict —
this doc records **what changed on our side**.

## Web-888-only changes (Howard Su's master line, 2024-11 → 2025-04)

Listed in chronological order; all SHAs verified against `work/redpitaya-src`.
These commits live on RaspSDR's master and constitute the **Web-888 base port**
that the vendor ships bitstreams for. None of these touch HDL IP — they are all
HDL-port glue (FSBL hooks, peri.c, server-naming, eth handling) that works
**with** the prebuilt bitstreams without a Vivado rebuild.

### The 5 commits the Step 4 plan §7 U1 explicitly calls out

| sha | date | message | Why it matters for Web-888 |
|---|---|---|---|
| **`bdfc22fb`** | 2024-11 | Add new si5351 driver in fsbl | FSBL programs Si5351 → 122.88 MHz at every cold-boot. This is the upstream source of the Si5351 init sequence that our `load-bitstream` switch hook optionally replays (open question, since resolved — see redpitaya-websdr-coexistence.md §6 Q1). Without it the RP bitstreams have no stable reference clock. |
| **`bf18b177`** | 2024-12 | Add att function to hpsdr application | `sdr_receiver_hpsdr/server/peri.c` (97 lines) bit-bangs the PE4312 DSA via legacy `/sys/class/gpio` writes to MIO pins 523/525/524 (base 512 + 11/13/12). **Web-888-specific** — the upstream HLv2 server has no DSA support because it targets STEMlab 122-14 which uses a different front-end. ⚠ Open question during the port (legacy sysfs GPIO is deprecated in mainline 6.12) — resolved during the P4.3 hardware gate. |
| **`713678f2`** | 2024-12 | support HLv2 protocol for HPSDR | The Hermes-Lite v2 protocol (HPSDR-Protocol-2) used by Thetis / cuSDR / SparkSDR / PowerSDR / SDR# clients. The upstream `sdr_receiver_hpsdr` server only speaks Hermes-Lite v1; Web-888 fork swaps in v2 frames (`process_ep2` 22-byte reply, `headers[5][8]` rotating preamble, `NUM_CHANNELS=6` wider than upstream's 4). |
| **`61bdddd9`** | 2024-11 | remove 122_88 applications | Web-888 hardware has a single 122.88 MHz ADC clock (Si5351-programmable, default = 122.88 MHz per FSBL) and no `122_88`/`125_14` model split. All upstream apps that existed in two variants (sdr_receiver, sdr_receiver_hpsdr, sdr_receiver_wide, sdr_transceiver*, led_blinker, …) collapse to a single Web-888 variant. The `cfg/red_pitaya.xml` board preset and the `clk_wiz` `PRIM_IN_FREQ 122.88` in every `block_design.tcl` reflect this. |
| **`eaebba25`** | 2024-11 | Use logic of web-888 to give the server name | The HPSDR discovery reply (22 bytes, the `reply[]` array in `sdr-receiver-hpsdr.c:63`) sets the server name field from a Web-888-derived string ("Web-888 #..." with MAC-derived serial) instead of pavel-demin's generic "Hermes-Lite" or "Red Pitaya SDR" string. Used by client apps to display the right hardware model. |

### The remaining 11 commits (also Web-888 base, also in master)

| sha | date | message | Note |
|---|---|---|---|
| `da1a7e3a` | 2025-04-30 | Add playground project | **⚠ Debug backdoor — NOT SHIPPED in v1 deb** (see §"playground" below). |
| `605d93c6` | 2025-04-30 | cleanup code | Cosmetic pass on the `Convert sdr_receiver_hpsdr` block (whitespace, dead includes). |
| `bd1cdd8d` | 2024-12-27 | fix multi channels | Multi-receiver HLv2 frame packing fix — without it, when a client requests >1 RX channel the protocol interleaving breaks. Touches `sdr-receiver-hpsdr.c` handler_ep6. |
| `bcb1cb14` | 2024-11-18 | merge dither and dith pin into gpio | GPIO consolidation in `block_design.tcl`. HDL glue; no Vivado rebuild needed because the bitstream is prebuilt and these bits were already in the shipped web888 boot. |
| `eea0534c` | 2024-11-17 | Convert common_tools project | Block-design rewrite for the shared `common_tools` Vivado project (LED / GPIO / I2C / measure-corr / measure-level / temp0 apps). |
| `fae85009` | 2024-11 | Cleanup the html file | Drops unused HTML cruft from `apps/<app>/index.html`. |
| `0d269026` | 2024-11 | Add sparksdr link | Adds the SparkSDR client URL to the HPSDR discovery reply. |
| `e288c16a` | 2024-11 | Fix script | One-line shell-script fix in `scripts/alpine.sh`. Irrelevant for us (we don't run Alpine). |
| `7ce04c2c` | 2024-11 | Fix VHF GPIO | GPIO direction / pin-numbering for VHF band switching (PE4312 second DSA path). |
| `b52707c0` | 2024-11 | Read refclk | Logs Si5351 reference-clock reading on startup. |
| `c95a1412` | 2024-11 | Fix ethernet addr | eth0 MAC handling for HPSDR discovery (`SIOCGIFHWADDR` reply bytes were being put in the wrong slot of the `reply[]` frame — causes client apps to show a bogus MAC until the fix). |
| `8f36a30a` | 2024-11 | Convert sdr_receiver_hpsdr project | The block-design conversion for the hpsdr app — pre-cursor to HLv2/multi-channel/att work. |

(The full RaspSDR-fork side git log is 36 commits since the merge base; the
ones above are the 16 substantive ones. The remainder are JerryTech parallel-
line work that was either folded into Howard Su's master or sit on unmerged
branches — see §"JerryTech parallel branches" below.)

## The `playground` commit (2025-04-30) — explicit do-not-ship

`projects/playground/server/playground.c` (93 lines) is a TCP-1001 listener that
exposes:

| code | what it does |
|---|---|
| 0 | `memcpy(hub + addr, buffer, size)` then `send()` — **arbitrary read** of `size` bytes from PL address space (0x40000000 + offset) |
| 1 | `recv()` then `memcpy(hub + addr, buffer, size)` — **arbitrary write** of `size` bytes to PL address space |
| 2 | `recv()` then `open("/dev/xdevcfg")` + `write(fd, buffer, size)` — **reprogram FPGA** with arbitrary bitstream |

This is a debugging aid for HDL bring-up; **on a public-facing device it is
equivalent to root** (write any value to PL registers; reprogram the FPGA to a
malicious bitstream; read the entire DDR ring buffer).

The Step 4 plan §4 D2 explicitly lists v1 apps as
`{sdr_receiver_hpsdr, sdr_receiver, led_blinker}` (+ wide best-effort). The
plan does not mention `playground` as a ship candidate, but it also does not
forbid it. **Implementation rule (deferred to a future plan revision):**
if/when a future deb revision decides to ship it, it must bind to
`127.0.0.1` only AND require an explicit opt-in via
`/etc/web888-redpitaya/switch.conf` (`PLAYGROUND_ENABLED=1`). Until that
exists, `web888-redpitaya` deb packaging must exclude `projects/playground/`.

## JerryTech parallel branches (NOT merged into master)

`RaspSDR/red-pitaya-notes` carries a parallel development line from
**JerryTech (ZhuXiangyu92, 1194781887@qq.com)** that forked off an earlier
Web-888 state (pre-`merge dither and dith pin into gpio`, pre-HLv2, pre-att).
These commits live on `fix_bugs_0728`, `web888_bootloader_si5351_driver`,
and the four `web888_sdr_receiver_*_0723/0724` branches — **none of them is
merged into master**.

| branch | HEAD | substantive commits (post 2024-07-23) | why NOT a merge target |
|---|---|---|---|
| `fix_bugs_0728` | `7b6b0620` | "Set adc from 14bit to 16bit. Fix projects/common_tools/block_design.tcl port to web888 bugs." (2024-07-27) | Parent chain stops at `7f29edaa` (2024-07-23 "Update README and remove all 7020 projects"); misses all of master-line's HLv2 / att / multi-channel / playground / cleanup work. Merging it would *lose* 9 months of Web-888 hardening. The 16-bit ADC + block_design port fixes it adds are **already present in master** (see `block_design.tcl:35 ADC_DATA_WIDTH 16`, port assignments across the Web-888 `block_design.tcl`s). |
| `web888_bootloader_si5351_driver` | `69481b7d` | "Add Si5351 driver in uboot which can set adc clock and ext clock. Default setting is adc clock 125Mhz, ext clock 10Mhz." (2024-07-27) | JerryTech's U-Boot Si5351 driver. Subsumed by Howard Su's `bdfc22fb` (FSBL Si5351 init at 122.88 MHz). Our boot chain (step 6 mainline U-Boot) doesn't use the vendor U-Boot, so this is doubly moot. |
| `web888_sdr_receiver_0723` | `c59de588` | "Port redpitaya sdr_receiver to web888" | Initial app port — superseded by master. |
| `web888_sdr_receiver_ft8_0724` | `0d13d499` | "Port sdr_transceiver_ft8 to web888 and remove transmit part" | TX-cut FT8 port. Lives on master as `projects/sdr_transceiver_ft8/` (server disabled in v1 — needs gfortran + ft8d). The "remove transmit" hunk is already merged. |
| `web888_sdr_receiver_wide_0724` | `56637c9a` | "Port sdr_receiver_hpsdr to web888" | The hpsdr tree was re-ported later by Howard Su with HLv2; JerryTech's version is pre-HLv2. |
| `web888_sdr_receiver_wspr_0724` | `41fb62ea` | "Port sdr_transceiver_wspr to web888, and cut off transmit function" | TX-cut WSPR port. Lives on master as `projects/sdr_transceiver_wspr/`. |
| `restore_web888` | `140f17d9` | "Use axis_red_pitaya_adc" | Howard Su's earlier ADC IP swap, folded into master via `bdfc22fb`. |
| `web888` | `0d269026` | "Add sparksdr link" | Howard Su's first sparksdr-link work; superseded by master. |
| `web888_hpsdr_0811`, `web888_kernel_driver`, `web888_gnuradio_dma`, `save_old`, `fix_kernel_patch` | various | Various old branches. | Either subsumed by master, or dead experiment branches. No merge action. |

**Verdict:** JerryTech's parallel work is historical/inert. None of it needs
to be re-synced; everything useful was already absorbed into master by Howard
Su. The fork is **effectively single-maintainer (Howard Su) since 2024-11**.

## Web-888 hardware-specific customizations (visible in master)

Beyond the per-commit list, the following **architectural** Web-888 differences
are worth recording for future maintainers:

| area | Web-888 specifics |
|---|---|
| **ADC** | LTC2208, 16-bit, 130 MSPS, 1 channel. Vendor `axis_red_pitaya_adc` IP with `ADC_DATA_WIDTH 16` (JerryTech's 14→16 fix; already in master). WebSDR's `websdr_{hf,vhf}.bit` is a **separate, larger bitstream** with its own DDC chain — the RP app bitstreams do not contain the WebSDR pipeline. |
| **Clocking** | Si5351 at 122.88 MHz default (FSBL `bdfc22fb` init). User-space re-tunes per ADC-clock config (websdr only; RP apps assume the FSBL clock — Q1 open question (since resolved, see redpitaya-websdr-coexistence.md §6): do we need to re-init Si5351 on websdr→RP switch?). |
| **Front-end** | HF + VHF inputs, **PE4312 DSA** (driver = `peri.c` sysfs GPIO 523/525/524). RP bitstreams expect this attenuator to be present and writable; without `set_att_value()` HPSDR discovery works but att slider is no-op. |
| **DAC / TX** | **None.** The board has no power amplifier and no DAC. All RP apps that include a TX path (sdr_transceiver_ft8 TX upload, sdr_transceiver_wspr TX, sdr_transceiver_hpsdr TX) have had the TX path stripped or disabled in this fork. Treat any TX feature as experimental. |
| **Network ports** | Web-888 has only eth0 (RTL8211E PHY @ PHY addr 7, gem0). No wifi on the board itself. RP apps don't depend on the kernel-driver side; they mmap `cfg@0x40000000`, `sts@0x41000000`, `fifo@0x42000000` (same physical addresses WebSDR's zynqsdr uses). |
| **FSBL** | Identical to vendor RP firmware's FSBL (same `red_pitaya_fsbl_hooks.c` source — see `patches/red_pitaya_fsbl_hooks.c` in our pin). Si5351 init + DDR training + 52-byte SSBL stub handoff to U-Boot or to a packed boot.bin. Our step-6 full-U-Boot chain reuses this FSBL. |
| **Vivado toolchain** | Vendor bitstreams built with **Vivado 2023.1** (`xilinx_v2023.1` DTB). Matches our pin's `Makefile:24 DTREE_TAG = xilinx_v2023.1`. Pavel-demin has since moved to Vitis 2025.2 (2025-11-27, `74c1cdb3`) — see §"Vivado/Vitis upgrade" below. |
| **Web-888 server-name logic** | The HPSDR discovery `reply[]` array carries a Web-888-derived server name (commit `eaebba25`). The exact name template is in `sdr-receiver-hpsdr.c` and reads eth0 MAC at startup. |

## What pavel-demin has done since our fork point

Per `git log --since=2024-12` and the GitHub compare of our pin vs their HEAD:

**88 commits ahead of us** since the 2024-11-05 merge-base. Activity since
2024-12 (the slice our plan §7 U2 should care about) is summarised:

| category | commits | relevant to our v1 deb? |
|---|---|---|
| **HDL IP changes** (`cores/`, `cfg/`, `block_design.tcl`): DDS IP replacement (`dds_compiler → dds`, 2024-12), FIR coefficient reduction (2024-12), `axis_gate_controller` enbl signal (2025-11), `xlconstant → constant` (2026-02), user-IP → RTL module swap (2026-02) | ~14 commits | **No** — all require Vivado/Vitis rebuild. Vendor prebuilt bitstreams are pinned to Vivado 2023.1. Plan §7 U3 only. |
| **Toolchain bumps** (Vitis 2025.2 switch 2025-11; Linux 6.18 in scripts 2026-07; Alpine 3.24 in scripts 2026-07; apk-tools-static version bump 2026-07) | ~5 commits | **No** — our build uses Debian 6.12 (kernel side) and mainline U-Boot, not Alpine/Vitis/Linux-from-curl. Irrelevant to userspace C servers. |
| **Bugfix in `patches/cma.c`** (2026-04-09, `778d4563`): `copy_from_user`/`copy_to_user` return-value handling (was returning the un-copied byte count instead of `-EFAULT`/0). | 1 commit | **Moot** — `patches/cma.c` is the vendor-RP kernel's `drivers/char/cma.c` patch. We do not use the vendor kernel; our 6.12 kernel has no cma.c. `sdr_transceiver_wide` v1 build would mmap `/dev/cma` and fail at runtime if shipped without porting cma.c to 6.12. Step-4 decision: **wide was built clean but the kernel-side cma driver is not provided** — runtime fallback for wide is to defer the app to v2 (planned §7 U4 "web888-redpitaya-digi"). |
| **`mcpha.py` PyQt6 fix** (2026-06-12) | 1 commit | **No** — host-side Python GUI tool. |
| **`vna.py` / `vna_122_88` data-copy fix** (2024-12-13, `fbbd7eec`) | 1 commit | **No** — `vna` is the upstream vector-network-analyser app; we don't ship it. |

**Bottom line:** pavel-demin's 2024-12 → 2026-07 work is 95%+ HDL/toolchain
churn. There is essentially **no C-userspace cherry-pick surface** for v1.
The single relevant commit (`cma.c` bugfix) is in code we don't compile.
Future cherry-pick work would need to (a) add the upstream `pavel-demin`
remote and (b) diff the four `projects/<app>/server/*.c` files for any
non-HLD fixes — but the diff will be small and the value of any single
fix will be modest.

## Vivado/Vitis upgrade (U3) — deferred, with rationale

pavel-demin moved from Vivado 2023.1 to **Vitis 2025.2** in commit
`74c1cdb3` (2025-11-27). A Vitis upgrade touches:
- All HDL IP versions (DDS, FIR compiler, AXI infrastructure, etc.)
- `block_design.tcl` syntax (IP-XACT schema, automation-rule names)
- The bitstream build flow (`scripts/*.tcl`)
- The FSBL build (Xilinx SDK → Vitis platform packaging)

This means **rebuilding all 6 vendor bitstreams from source** — a multi-hour
Vivado/Vitis job on a host machine with the toolchain installed. We don't
have Vitis 2025.2 installed; per project AGENTS.md §1.4, system-level
installations need user authorization.

**Decision (recorded):** U3 is **NOT executed for v1**. Vendor prebuilt
bitstreams (Vivado 2023.1, 2024/12/01–09) are pinned and verified to work
with our kernel side (xdevcfg load + DevTree nvmem MAC + the systemd switch
model). All post-2024-12 pavel-demin HDL work is upstream-only; its absence
in our bitstreams is invisible to the apps we ship.

U3 becomes relevant only if (a) a future v2 needs Vivado-side fixes for a
defect that can't be patched in C, or (b) Vitis 2023.1 reaches EOL and the
host needs a toolchain bump to rebuild.

## Implications for the v1 deb (Step 4 D2 + D3)

What this delta means for `web888-redpitaya` packaging:

1. **C-server build set:** `{sdr-receiver, sdr-receiver-hpsdr, sdr-transceiver-wide}`
   all build cleanly from source with `gcc -O3 -march=armv7-a -mtune=cortex-a9
   -mfpu=neon -mfloat-abi=hard` + libc/libm (wide, hpsdr also need
   `-lpthread`). No Alpine/musl-isms in flags. Confirmed in plan P0; rebuilt
   in P1 (see `docs/dev/CHANGELOG.md`).
2. **Bitstream set:** `{led_blinker, sdr_receiver, sdr_receiver_hpsdr,
   sdr_transceiver_wide}` — 4 vendor-prebuilt `.bit` files, all
   `xilinx_v2023.1` Vivado, `7z010clg400`, dates 2024/12/01–09. SHAs in
   `resources/redpitaya-bits/PROVENANCE.md`. (sdr_transceiver_ft8/wspr are
   deferred to v2 per plan §7 U4 — needs `gfortran` + `ft8d`/`wsprd`.)
3. **Build-from-source vs musl-binary trade-off:** The plan §D3 explicitly
   chose **build from source** (not run the vendor's musl-linked binaries on
   Debian). Step-2's musl-on-Debian smoke was a shortcut, not a shipping
   strategy. This delta doc affirms that choice — our fork's userspace
   consists entirely of plain C with POSIX/glibc-friendly headers, no
   Alpine/musl dependencies.
4. **peri.c is a known port-debt item** (see redpitaya-websdr-coexistence.md §6 Q2). It works on
   the vendor kernel + Alpine userspace, and may need a small patch or a
   switch to libgpiod before it works under our 6.12 + Debian userspace.
   Resolved during HW gate P4.3.

## Implications for future M+1 work (Step 4 §7 U2–U5)

- **U2 (cherry-picks):** Diff the 4 C-server files against pavel-demin
  master. Expected yield: 0–3 small patches (mostly cosmetic / non-bugfix).
  Set up `config/redpitaya/patches/` quilt series when yield ≥1.
- **U3 (Vivado rebuild):** **Skipped for v1** (rationale above).
- **U4 (ft8/wspr):** Independent `web888-redpitaya-digi` deb when demand
  materialises; requires `gfortran` armhf cross-toolchain + `ft8d`/`wsprd`
  sources (WSJT-X lineage).
- **U5 (watch fork):** `git ls-remote https://github.com/RaspSDR/red-pitaya-notes.git
  refs/heads/master` should return `da1a7e3a…` for the foreseeable future
  — the fork has been effectively dormant since 2025-04-30. If the SHA
  advances, re-evaluate against this delta doc; if not, this doc is
  permanent.

## References

- Internal:
  - `docs/dev/redpitaya-websdr-coexistence.md` — research verdict that chose
    this fork; same author/time window as this doc.
  - `docs/research/red-pitaya-firmware.md` — vendor RP firmware analysis (binary
    CONFIRMED facts); explains why the bitstreams are mutually exclusive.
  - `docs/dev/redpitaya-port-guide.md` — earlier coexistence design (pre-CoA);
    the validated vendor findings are in this doc, the unimplemented service
    sketch was removed.
  - `docs/research/hardware-facts.md` — verified-on-hardware facts (Si5351 init,
    devcfg load, MAC, etc.).
  - `config/redpitaya/upstream.pin` — pin record (`da1a7e3a`).
  - `resources/redpitaya-bits/PROVENANCE.md` — vendor prebuilt bitstream
    provenance (Vivado 2023.1, 2024/12/01–09, SHAs).
  - `work/redpitaya-src/` — locally cloned RaspSDR fork @ `da1a7e3a`.
  - redpitaya-websdr-coexistence.md §7 — the U1–U5
    follow-up TODOs this doc delivers U1 of.

- External (verified via `git ls-remote` + GitHub API):
  - `RaspSDR/red-pitaya-notes` master = `da1a7e3a` (2025-04-30, last
    substantive commit; one further `playground` add same day).
  - `pavel-demin/red-pitaya-notes` master = `cc13b6aa` (2026-07-07
    "switch to Alpine 3.24"). PRs open to #1118+.
  - Merge-base fork point: `3c0e3d98` (2024-11-05 "fix QRegExp argument in
    vna.py", Howard Su).
  - GitHub compare
    `pavel-demin:da1a7e3a…pavel-demin:cc13b6aa` → diverged, 88 ahead,
    36 behind.
  - Branch inventory on `RaspSDR/red-pitaya-notes`: `master`,
    `fix_bugs_0728`, `fix_kernel_patch`, `restore_web888`, `save_old`,
    `web888`, `web888_bootloader_si5351_driver`, `web888_gnuradio_dma`,
    `web888_hpsdr_0811`, `web888_kernel_driver`, `web888_sdr_receiver_0723`,
    `web888_sdr_receiver_ft8_0724`, `web888_sdr_receiver_wide_0724`,
    `web888_sdr_receiver_wspr_0724`. None of the non-master branches has
    commits newer than 2024-07-28.

---

*Written alongside Step 4 P1 (server source build green, plan
CHANGELOG). All SHAs verified against the local clone `work/redpitaya-src/`
and the GitHub compare APIs at the time of writing.*