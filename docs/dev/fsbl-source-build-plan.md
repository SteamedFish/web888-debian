# Web-888 FSBL Source Build Plan (de-blob the boot chain)

> **Status:** IMPLEMENTED 2026-08-15 — Tasks 1-4 + 6 done (Task 5 skipped:
> no Vivado/HSI approval; the extraction path shipped instead).
> `FSBL=source` is the default in `scripts/build-bootbin.sh`;
> hardware-verified 2026-08-15 (full battery: MAC/EEPROM, MIO49/MIO10
> levels, live WebSDR, memtester 350M clean, dmesg clean).
> Compiled 2026-08-14 from three
> research passes: local repo/binary analysis, embeddedsw toolchain research,
> ps7_init acquisition-path research. Implements TODO **F1** (checked off).

**Goal:** Build the Web-888 FSBL from source — Xilinx embeddedsw `zynq_fsbl` @
`xilinx_v2023.1` + RaspSDR Red Pitaya hooks — replacing the extracted stock blob
`work/stock/fsbl.bin` in `boot.bin`, with hardware-proven ps7_init data.

**Architecture:** Vendor the embeddedsw FSBL build subset (MIT license,
layout-preserving) into `resources/reference/embeddedsw-zynq-fsbl/`, add a
`web888` board dir (`ps7_init.c/h`, `xparameters.h`, `bspconfig.h`,
`drivers.txt`), and drive the official "Building FSBL from git" flow
(`cd lib/sw_apps/zynq_fsbl/src && make BOARD=web888 CC=arm-none-eabi-gcc`) —
**no Vitis/xsct needed**. The only missing artifact, `ps7_init.c/h`, is
acquired by **binary extraction from the stock FSBL** (primary path: zero
approvals, values are hardware-proven ground truth), with a one-time
**Vivado 2023.1 pre-synthesis XSA export** as an optional provenance-hardening
pass whose output must match the extraction. Build host toolchain:
`arm-none-eabi-gcc` 16.1.0 (already installed).

**Tech Stack:** embeddedsw @ `xilinx_v2023.1` (`86f54b77`), standalone BSP +
drivers via `misc/copy_bsp.sh`, `arm-none-eabi-gcc`, Python extraction script,
bootgen repack (existing `scripts/build-bootbin.sh`).

## Research basis (all verified 2026-08-14)

- **Build flow without Vitis** (official, Xilinx/embeddedsw README):
  `src/Makefile` globs `*.c` (so dropping `red_pitaya_fsbl_hooks.c` into `src/`
  compiles it automatically) and pulls `ps7_init.c` from `misc/$(BOARD)/`.
  `misc/copy_bsp.sh <board> <compiler>` + `misc/makefile` build `libxil.a` from
  standalone BSP + drivers listed in `misc/<board>/drivers.txt`. App CFLAGS
  `-Wall -O0 -g3`, **no `-Werror`**.
- **Vendoring set** (relative layout must be preserved):
  `lib/sw_apps/zynq_fsbl/{src,misc,data}` + `lib/bsp/standalone/src` +
  `XilinxProcessorIPLib/drivers/{cpu_cortexa9,devcfg,dmaps,emacps,gpiops,iicps,qspips,scugic,scutimer,scuwdt,sdps,ttcps,uartps,usbps,xadcps}/src`
  + `lib/sw_services/{xilffs,xilrsa}/src` + `license.txt`. All **MIT** (SPDX),
  incl. generated `ps7_init.c/h` → compatible with project GPL-2.0-or-later;
  `PROVENANCE.md` per repo convention. Full repo is ~1 GB → vendor trimmed
  subset (tens of MB).
- **Hooks integration**: apply the 2-hunk `fsbl.patch` to `src/fsbl_hooks.c`
  (adds `u32 SetMacAddress();` prototype + `Status = SetMacAddress();` inside
  `FsblHookBeforeHandoff`) and drop `red_pitaya_fsbl_hooks.c` (528 lines: I2C0
  EEPROM 0x50 + Si5351 0x60 driver, MAC @ EEPROM 0x10, `refclock=` override,
  MIO49/MIO10) into `src/`. Hooks need BSP drivers **xiicps + xemacps +
  xgpiops** — zc702's `drivers.txt` has emacps+gpiops but **not iicps** →
  web888 `drivers.txt` = zc702 list + `iicps`.
- **ps7_init format** (fully documented): 15 arrays
  `ps7_{mio,pll,clock,ddr,peripherals}_init_data_{1_0,2_0,3_0}`;
  (opcode|addr, mask, value) triplets, opcode in low 2 bits of the address word
  (MASKWRITE=0, MASKPOLL=1, MASKDELAY=2, WRITE=3, EXIT=0). Every array starts
  with unlock `EMIT_WRITE(0xF8000008,0xDF0D)` → LE words `0xF800000B
  0x0000DF0D`, ends with `0x00000000`. The C **function bodies are
  board-independent** (skeleton from vendored `misc/zed/ps7_init.c`); only the
  data arrays are board-specific.
- **Stock binary is datable and is ground truth**: `work/stock/fsbl.bin`
  (114,696 B) predates the hooks' GPIO commits (no `GPIO LookupConfig Failed`
  strings) → stock FSBL never drives MIO49/MIO10 and never consumes
  `refclock=`. Source-built FSBL **will** — a deliberate, verified behavior
  delta (MIO49 HIGH = internal TCXO per `hardware-facts.md`) to be documented
  in CHANGELOG/KNOWN-ISSUES.
- **Preset cross-check: ALL MATCH.** `cfg/red_pitaya.xml` (UART0 MIO14-15,
  UART1 MIO8-9, I2C0 MIO50-51, ENET0 MIO16-27+MDIO52-53, SD0 MIO40-45 WP47,
  USB0 reset MIO48, DDR MT41J256M16 16-bit) matches every software-verifiable
  stock-DTB/hardware fact. DDR controller regs `0xF8006000-60B8` are
  byte-identical across same-class boards (zybo-z7/topic-miami); only PHY
  training ratios `0xF800612C-6188` are board-specific → keep stock values.
  Open item: Stemlab's current preset says MT41**K**256M16 (DDR3L) vs RaspSDR's
  MT41**J**256M16 (DDR3 1.5V) — the extraction settles which one actually runs
  on the hardware.
- **QEMU does not model the Zynq DDR controller** → ps7_init correctness can
  only be proven by values identical to stock + hardware boot. Existing QEMU
  gate (`scripts/test-qemu.sh uboot`) stays as-is.
- **Repack contract**: `scripts/build-bootbin.sh:30/83` BIF line
  `[bootloader] $STOCK/fsbl.bin`; header patch (words 0x34/0x40/0x48) is
  size-agnostic; OCM budget 256 KB (stock uses 112 KiB).

## Global Constraints

- Project license GPL-2.0-or-later; vendored MIT tree keeps its license +
  `PROVENANCE.md`.
- Never touch host NVMe; flash targets are removable USB SD readers only;
  stock TF card stays untouched as rollback.
- Blind testing only (no serial); QEMU boot gate before any hardware flash.
- Build artifacts in `work/`/`output/` (gitignored); scratch in `.tmp/`.
- GPG-signed atomic commits on `master`; **no push without asking**; untracked
  personal files stay untracked.
- System-level installs (Vivado) require explicit operator approval (ties into
  `redpitaya-upstream-delta.md` U3).
- Every task commit syncs `docs/dev/CHANGELOG.md` (+ TODO/KNOWN-ISSUES where
  applicable).

---

## Task 1: Vendor embeddedsw zynq_fsbl subset + toolchain smoke test

**Files:**
- Create: `resources/reference/embeddedsw-zynq-fsbl/` (subset tree below)
- Create: `resources/reference/embeddedsw-zynq-fsbl/PROVENANCE.md`

**Interfaces:**
- Produces: vendored tree with `lib/sw_apps/zynq_fsbl/src/Makefile` honoring
  `BOARD=<name>` and `CC`; used by Tasks 3–4.

- [x] **Step 1: Fetch trimmed subset into scratch**
```bash
mkdir -p .tmp/embeddedsw && cd .tmp/embeddedsw
git clone --filter=blob:none --no-checkout https://github.com/Xilinx/embeddedsw.git
cd embeddedsw && git sparse-checkout set \
  lib/sw_apps/zynq_fsbl lib/bsp/standalone/src lib/sw_services/xilffs/src lib/sw_services/xilrsa/src \
  XilinxProcessorIPLib/drivers/cpu_cortexa9/src XilinxProcessorIPLib/drivers/devcfg/src \
  XilinxProcessorIPLib/drivers/dmaps/src XilinxProcessorIPLib/drivers/emacps/src \
  XilinxProcessorIPLib/drivers/gpiops/src XilinxProcessorIPLib/drivers/iicps/src \
  XilinxProcessorIPLib/drivers/qspips/src XilinxProcessorIPLib/drivers/scugic/src \
  XilinxProcessorIPLib/drivers/scutimer/src XilinxProcessorIPLib/drivers/scuwdt/src \
  XilinxProcessorIPLib/drivers/sdps/src XilinxProcessorIPLib/drivers/ttcps/src \
  XilinxProcessorIPLib/drivers/uartps/src XilinxProcessorIPLib/drivers/usbps/src \
  XilinxProcessorIPLib/drivers/xadcps/src license.txt
git checkout xilinx_v2023.1   # 86f54b77641f325042a1101fead96b2714e6d3ef
```
- [x] **Step 2: Copy into `resources/reference/embeddedsw-zynq-fsbl/`
  preserving relative layout**; write `PROVENANCE.md` (upstream URL,
  tag/commit, retrieval date, MIT license, trimmed-path list, rationale).
- [x] **Step 3: Smoke test with known-good board:** `cd
  resources/reference/embeddedsw-zynq-fsbl/lib/sw_apps/zynq_fsbl/src && make
  BOARD=zc702 CC=arm-none-eabi-gcc` → expect `fsbl.elf`. Record any gcc-16.1.0
  errors verbatim; if warnings-as-errors appear, demote via
  `CC_FLAGS="-Wno-error=<x>"` (same pattern as the bootgen workaround). `make
  clean` afterwards.
- [x] **Step 4: Verify** — `arm-none-eabi-size` on the zc702 `fsbl.elf`
  (sanity: total < 200 KB) before clean; tree diff vs upstream sparse checkout
  is empty.
- [x] **Step 5: Commit** (`resources: vendor embeddedsw zynq_fsbl
  xilinx_v2023.1 subset`) + CHANGELOG entry.

## Task 2: Extract ps7_init data arrays from the stock FSBL binary

**Files:**
- Create: `scripts/extract-ps7-init.py`
- Create: `docs/research/ps7-init-stock-analysis.md` (decoded report)
- Output (gitignored): `.tmp/ps7-init/{arrays.bin,decode.txt,ps7_init_data.c}`

**Interfaces:**
- Consumes: `work/stock/fsbl.bin` (114,696 B, partition #1 of stock boot.bin).
- Produces: `ps7_init_data.c` (the 15 data arrays in embeddedsw emit-macro
  format) consumed by Task 3; decode report used to verify Task 5.

- [x] **Step 1: Write `scripts/extract-ps7-init.py`.** Logic: scan for LE
  signature `0xF800000B` immediately followed by `0x0000DF0D`; from each hit,
  walk (addr_word, mask, value) triplets until terminator `0x00000000`;
  validate `addr_word & 3` ∈ {0,1,2,3} and address ranges (SLCR
  `0xF8000000-0x02FF`, MIO `0xF8000700-0x0AFF`, DDRC/DDRP
  `0xF8006000-0x6FFF`, peripheral bases); classify each array into
  mio/pll/clock/ddr/peripherals by dominant address range. Expect exactly 15
  arrays (3 silicon variants × 5); abort with diagnostics otherwise. *(As
  built: 21 arrays incl. post_config/debug — see
  ps7-init-stock-analysis.md §1.)*
- [x] **Step 2: Decode + cross-check.** Decode each triplet against a TRM
  register-name map (SLCR/DDRC/DDRP ranges, ~80 registers) into `decode.txt`.
  Assert: MIO mux writes match `work/redpitaya-src/cfg/red_pitaya.xml` pin
  list; DDR controller regs `0xF8006000-60B8` equal U-Boot
  `board/xilinx/zynq/zynq-zybo-z7/ps7_init_gpl.c` values (fetch into `.tmp/`
  for the diff); record J-vs-K DDR voltage evidence; keep PHY training values
  (`0xF800612C-6188`) as-is.
- [x] **Step 3: Emit `ps7_init_data.c`** in embeddedsw emit-macro format
  (`EMIT_MASKWRITE(0xF8000008, 0x0000FFFFU, 0xDF0DU)` style), one array per
  found blob, names `ps7_<group>_init_data_<ver>`.
- [x] **Step 4: Round-trip unit check (host gcc):** tiny harness compiling the
  emitted arrays and byte-comparing against the extracted blob → MUST be
  byte-identical.
- [x] **Step 5: Write `docs/research/ps7-init-stock-analysis.md`** (silicon
  variants found, array sizes, key decoded values: DDR clock, MIO table
  summary, PLL config) — this is reverse-engineering knowledge per repo
  convention.
- [x] **Step 6: Commit** (`scripts: extract ps7_init tables from stock FSBL
  binary`) + CHANGELOG.

## Task 3: `web888` board dir + first source-built FSBL

**Files:**
- Create:
  `resources/reference/embeddedsw-zynq-fsbl/lib/sw_apps/zynq_fsbl/misc/web888/{xparameters.h,bspconfig.h,drivers.txt,inbyte.c,outbyte.c,ps7_init.c,ps7_init.h}`
- Create:
  `resources/reference/redpitaya-fsbl-hooks/{red_pitaya_fsbl_hooks.c,fsbl.patch,PROVENANCE.md}`
  (verbatim copies from `work/redpitaya-src/patches/` @ pinned commit)
- Create: `scripts/build-fsbl.sh`
- Output: `output/fsbl/fsbl.elf`, `output/fsbl/fsbl.bin`

**Interfaces:**
- Consumes: Task 1 tree, Task 2 `ps7_init_data.c`.
- Produces: `scripts/build-fsbl.sh` (no args; idempotent; used by Task 4);
  `output/fsbl/fsbl.bin` consumed by Task 4's BIF.

- [x] **Step 1: Create board dir.** `drivers.txt`: `cpu_cortexa9 devcfg dmaps
  emacps gpiops iicps qspips scugic scutimer scuwdt sdps ttcps uartps usbps
  xadcps`. `inbyte.c/outbyte.c`: copy from `misc/zc702/`. `bspconfig.h`: copy
  zc702, keep stdin/stdout on `XPAR_PS7_UART_0_BASEADDR`. `xparameters.h`:
  start from `misc/zc702/xparameters.h`, keep only instances in our config
  (CPU 667 MHz, UARTPS0/1, IICPS0, EMACPS0, GPIOPS, SDPS0, DEVCFG,
  SCUGIC/SCUTIMER/SCUWDT, USBPS0, XADCPS), set clock constants from Task 2
  decoded SLCR values; compile catches any missing `XPAR_*` referenced by
  FSBL/hooks sources — iterate until clean (each fix is a concrete
  missing-macro error, not guesswork).
- [x] **Step 2: Assemble `ps7_init.c/h`.** Function bodies + headers from
  `misc/zed/ps7_init.{c,h}` (board-independent skeleton); data arrays from
  Task 2's `ps7_init_data.c`.
- [x] **Step 3: Vendor hooks** into `resources/reference/redpitaya-fsbl-hooks/`
  with `PROVENANCE.md` (RaspSDR/red-pitaya-notes, pinned commit, license).
- [x] **Step 4: Write `scripts/build-fsbl.sh`:** `rsync -a --delete` the
  vendored zynq_fsbl tree to `work/fsbl/`; `cp
  resources/reference/redpitaya-fsbl-hooks/red_pitaya_fsbl_hooks.c
  work/fsbl/src/`; `git apply` the 2-hunk `fsbl.patch` onto
  `work/fsbl/src/fsbl_hooks.c` *(as built: `patch -p0` — the patch has no
  `a/`/`b/` prefixes; see `scripts/build-fsbl.sh:70`)*; `make -C work/fsbl/src BOARD=web888
  CC=arm-none-eabi-gcc`; `arm-none-eabi-objcopy -O binary
  work/fsbl/src/fsbl.elf output/fsbl/fsbl.bin`; copy `fsbl.elf` alongside.
  Fail loudly if `fsbl.bin` > 192 KiB (OCM budget).
- [x] **Step 5: Build + verify:** (a) build exits 0; (b) `arm-none-eabi-nm
  fsbl.elf` shows all 15 `ps7_*_init_data_*` symbols; (c) extract `.rodata`
  array bytes via symbol addresses and byte-compare vs Task 2 blob → MUST be
  identical; (d) `strings fsbl.elf` contains hook strings incl. `GPIO
  LookupConfig Failed` (the deliberate delta vs stock) and lacks the `Xilinx
  First Stage Boot Loader` banner (no `FSBL_DEBUG_INFO`, matching stock's
  silent boot); (e) size ≤ OCM budget.
- [x] **Step 6: Commit** (`fsbl: web888 board dir + source build script`) +
  CHANGELOG.

## Task 4: boot.bin integration (opt-in) + hardware verification

**Files:**
- Modify: `scripts/build-bootbin.sh:30,83` (BIF `[bootloader]` line)
- Modify: `scripts/env-setup.sh` (add `arm-none-eabi-gcc` check)

**Interfaces:**
- Consumes: `output/fsbl/fsbl.bin` from Task 3.
- Produces: `FSBL=stock|source` env var (default `stock` until Step 4 passes);
  boot.bin with source FSBL.

- [x] **Step 1: BIF switch.** `FSBL="${FSBL:-stock}"`; when `source`, BIF uses
  `output/fsbl/fsbl.bin`. Header patch logic untouched (already size-agnostic).
- [x] **Step 2: QEMU gate:** `FSBL=source scripts/build-bootbin.sh &&
  scripts/test-qemu.sh uboot` → must pass as before. If QEMU hangs inside the
  real FSBL (DDR controller unmodeled), document that the QEMU gate covers
  U-Boot only and hardware flash is the gate — check `scripts/test-qemu.sh`
  semantics first.
- [x] **Step 3: env-setup.sh:** add `arm-none-eabi-gcc` to the toolchain check
  (host already has 16.1.0).
- [x] **Step 4: Blind hardware flash (operator-assisted):** flash scratch card
  with `FSBL=source` image; verify: boots to Debian (ssh `web888.local`); MAC
  address equals EEPROM value (`ip link` vs EEPROM offset 0x10); SDR stack
  streams (websdr/redpitaya smoke per `docs/user/usage.md` — proves Si5351
  CLK0 122.88 MHz); MIO49/MIO10 levels via `gpiod`; `memtester 350M 1` clean;
  stock card still boots (rollback intact).
- [x] **Step 5: Flip default** `FSBL=source` only after Step 4 passes; document
  the deliberate deltas (MIO49/MIO10 now driven, `refclock=` now consumed) in
  CHANGELOG + `KNOWN-ISSUES.md` + `hardware-facts.md`.
- [x] **Step 6: Commit(s)** (integration, then default-flip separately) +
  CHANGELOG.

## Task 5 (optional, operator-approved): Vivado XSA provenance pass

**Files:**
- Create:
  `resources/reference/ps7-init-xsa/{ps7_init.c,ps7_init.h,ps7_init_gpl.c,ps7_init_gpl.h,ps7_init.tcl,ps7_init.html,PROVENANCE.md}`

- [ ] **Step 1 (operator):** install Vivado 2023.1 ML (30–60 GB, Zynq-7000
  device only) — shares the `redpitaya-upstream-delta.md` U3 install approval.
- [ ] **Step 2:** `cd work/redpitaya-src && make tmp/led_blinker.xsa`
  (project.tcl → `write_hw_platform -fixed -force`; pre-synthesis, ~5–10 min;
  `PS7_CONFIG_PRESET` from `cfg/red_pitaya.xml` is the only PS7 input — cores
  are irrelevant).
- [ ] **Step 3:** `unzip` the XSA; run Task 2's script in compare mode against
  XSA `ps7_init.c` arrays. **If identical:** replace board-dir arrays with
  XSA-derived files (same bytes, better provenance), update PROVENANCE.
  **If different:** STOP — investigate (prime suspect: MT41J vs MT41K preset);
  do not switch until resolved; keep extraction-derived tables meanwhile (they
  are hardware-proven).
- [ ] **Step 4: Commit** + CHANGELOG.

## Task 6: Documentation sync (final)

- [x] `docs/research/bootbin-repack-spec.md`: update FSBL provenance lines
  (13/24/32/63/79/105-107 — incl. the now-obsolete "EEPROM env not consumed"
  note).
- [x] `docs/research/hardware-facts.md`: source-built FSBL note + GPIO/refclock
  delta.
- [x] `docs/dev/KNOWN-ISSUES.md`: QEMU-cannot-test-FSBL-handoff entry (if
  absent).
- [x] `docs/dev/TODO.md`: check off F1 sub-items; link this plan.
- [x] `docs/user/usage.md` + `README.md`/`README.zh-CN.md`: only if
  user-visible behavior changes (`refclock=` override honored).
- [x] Final commit + CHANGELOG.

## Risks & open questions

1. **gcc 16.1.0 vs 2020-era BSP C** — mitigated: no `-Werror`; demote flags
   budgeted; zc702 smoke test (Task 1 Step 3) surfaces this before any
   web888-specific work.
2. **Extraction misclassification** — mitigated by strong signatures, triplet
   validation, round-trip byte check (Task 2 Step 4), and built-ELF data
   equivalence (Task 3 Step 5c). Residual failure mode = wrong DDR values →
   card doesn't boot → swap to stock card (established blind-test workflow).
3. **QEMU may not execute the real FSBL** — Task 4 Step 2 checks; worst case
   the gate is unchanged and hardware flash decides.
4. **DDR J-vs-K discrepancy** — Task 2 decode records evidence; Task 5 compare
   mode is the final arbiter; stock values win until then.
5. **`xparameters.h` clock constants** — only affect baud/dividers; a wrong
   UART baud still boots (and we have no console anyway); compile + hardware
   test cover it.

## Execution note

Tasks 1–3 are fully local (no approvals, no hardware). Task 4 Step 4 (flash)
and Task 5 Step 1 (Vivado install) are operator-gated. Each task ends in its
own GPG-signed atomic commit; nothing is pushed without explicit approval.
