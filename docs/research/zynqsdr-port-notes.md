# zynqsdr port notes

Research synthesis for writing the new `zynqsdr` driver — the **canonical
driver document** for this project (the actual source is
`config/kernel/zynqsdr.c`, the authoritative ABI header is
`resources/reference/raspsdr-server/ioctl.h`). Sources:

- `resources/reference/raspsdr-server/` — vendored RaspSDR/server `zynq/ioctl.h`,
  `zynq/peri.h`, `zynq/peri.cpp` (SHAs in PROVENANCE.md)
- `resources/reference/xilinx/xilinx_devcfg.c` — pristine Xilinx devcfg (xilinx-v2016.4)
- iliasam/OpenZynqSDRApp — analyzed via librarian (repo is a single-snapshot commit,
  no kernel-compat history)
- Static (radare2) + live (SSH) reverse-engineering of the stock kernel and
  websdr.bin — the primary evidence is folded into **Appendix A** of this doc

## 1. ABI authority — confirmed, no guesswork left

RaspSDR/server `zynq/ioctl.h` matches the reverse-engineered spec exactly:
magic `'Z'` (0x5a), commands 0–12 + 20/21, `WF_READ_CONTINUES = 0x00010000`,
packed structs with fields named `address`/`length`/`readed`.

The vendored `zynq/peri.cpp` is the **exact userspace** our driver must satisfy
(the stock websdr.bin is built from this source). Key behaviors:

- **No mmap anywhere** — pure ioctl + `copy_to_user` data path. Driver needs no
  mmap fops. (Kills the earlier worry that the stock driver might need mmap.)
- **Init order** (`peri_init`):
  1. Si5351 over `/dev/i2c-0` @0x60 (userspace! kernel must NOT bind a si5351 driver)
  2. `cat /media/mmcblk0p1/websdr_{hf,vhf}.bit > /dev/xdevcfg` (`vhf` when airband
     or ADC clock < 100 MHz, else `hf`)
  3. `open("/dev/zynqsdr", O_RDWR | O_SYNC)` — must succeed or `sys_panic`
  4. `CLK_SET` (0=ext, 1=int), `MODE_SET` (airband), `AD8370_SET(0)`
  5. `GET_SIGNATURE` → `wf_channels = (sig >> 8) & 0xf`
- **Partial-read retry**: `RX_READ` loops with `TaskSleepMsec(10)`, `WF_READ` with
  `TaskSleepMsec(1)`, advancing `address += readed` until the full request is
  filled. Driver may return any `0 <= readed <= length`; rc must be 0 on success.
- **PPS_READ**: `-EBUSY` = "no PPS data yet", handled as normal (returns 0).
- **GPIO bits** (`peri.h`): ANTENNA0–5 = bits 0–5 (`GPIO_ANNENNA_MASK = 0x7f`),
  DITHER = bit 6, PGA = bit 7, LED = bit 8. Driver passes the 9-bit mask through
  to the FPGA GPIO register (config space).
- **RX_START arg** = `rx_decim / 256`. `RF attn` arg = `-dB * 2` (0–63, PE4312
  6-bit code; the ioctl name `AD8370_SET` is a historical misnomer).
- `fpga_reset_wf(chan, cont)`: builds `data = chan | WF_READ_CONTINUES` but then
  passes **`wf_chan` without the flag** to `WF_START` — the flag actually flows
  through `WF_READ`'s channel field per the spec (verify on hardware; keep both
  tolerant: mask `chan & 0xff`, treat bit 16 as continuous wherever it appears).

## 2. Reference driver — iliasam/OpenZynqSDRApp `sdrdma`

GPL v2. `kernel_dma_driver/files/sdrdma_main.c` (~650 lines) + `sfifo.{c,h}`.

- Platform driver + `alloc_chrdev_region` + `class_create` + `device_create`,
  device `/dev/sdrdma`, mode forced 0666 via devnode callback.
- ioctl numbering identical to RaspSDR (iliasam's header comment cites
  RaspSDR/server zynq/ioctl.h) but struct fields renamed: `address`→`destination`,
  `readed`→`result` where `result` is a **status enum** (10=bad size, 11=no data,
  20=OK). **ABI-incompatible semantics — do not copy.**
- 3 IRQs (sound, wf0, wf1) via platform resources; handler does
  `ioread32` status + `memcpy_fromio` from PL BRAM, then `schedule_work`;
  workqueue pushes into a 3-deep sfifo; ioctl drains via `copy_to_user`.
- DMA buffers at DDR `0x1F400000/0x1F410000/0x1F420000` (that project's memory
  map; Web-888 uses PL register pages 0x42xxxxxx–0x47xxxxxx per our spec).
- In iliasam's own userspace, almost all ioctls are commented out — only
  RX_READ/WF_READ are exercised; FPGA control goes over spidev instead.
  **Not true for Web-888**: RaspSDR's peri.cpp exercises all 15 ioctls, so our
  driver must implement the full set.
- WF block size in sdrdma: 8192 × 32-bit = 32768 B (working assumption for our
  FIFO sizing; confirm empirically on hardware via `readed` values).

### 6.6 API checklist for the new module

| API | 6.6 status |
|---|---|
| `unlocked_ioctl` signature | correct modern form |
| `class_create(THIS_MODULE, name)` 2-arg | deprecated but compiles on 6.6 (removed in 6.9+; use 1-arg `class_create(name)` in new code) |
| `ioremap` / `ioread32` / `memcpy_fromio` | fine (devm_ioremap preferred) |
| `request_irq`, `schedule_work`, mutex, kfifo/sfifo | fine |
| `copy_to_user`/`copy_from_user` with packed structs | mind 4/8-byte alignment of u64 in packed structs on ARM |

## 3. devcfg port notes (M1)

- Pristine source: `resources/reference/xilinx/xilinx_devcfg.c` (xilinx-v2016.4,
  2240 lines, Xilinx GPL v2). Removed from Xilinx's 6.6 tree (they push
  fpga-manager `zynq-fpga` instead — but websdr needs the legacy `/dev/xdevcfg`
  char interface, so we port the old driver back).
- The 2016.4 driver calls **extern** `zynq_slcr_init_preload_fpga()` /
  `zynq_slcr_init_postload_fpga()` — in old xlnx trees these lived in
  `arch/arm/mach-zynq/slcr.c`. **Check their existence/exports in our 6.6.80
  tree first**; if gone, replicate their SLCR writes inside the driver (this is
  expected to be the main port delta besides `class_create`).
- A compile-verified 6.6 port exists (vendor-authored) and was used as a
  **read-only diff reference** to isolate the 6.6 API fixes below. The pristine
  Xilinx v2016.4 source we actually build from is vendored at
  `resources/reference/xilinx/xilinx_devcfg.c`. Do not copy the vendor port
  blindly; diff it against the pristine 2016.4 file and take only understood
  changes.
- `cma.c` (CONFIG_DEVCMA, `/dev/cma` contiguous-memory char device): check
  whether anything in the stock stack actually opens `/dev/cma` (the devcfg
  driver itself uses `dma_alloc_coherent`, not cma.c). If unused by websdr,
  consider `CONFIG_DEVCMA=n` and skip the port. Outcome: not ported — nothing
  we ship opens `/dev/cma` (`sdr_transceiver_wide` would; it is deferred —
  see `docs/dev/redpitaya-upstream-delta.md`).
- The vendor's Kconfig/Makefile plumbing (their patch 0001) also carries
  unrelated hunks (USB ULPI PHY, pps-gpio capture-clear) — skip those; take
  only the `XILINX_DEVCFG`/`DEVCMA` symbol wiring.
- devcfg needs its DT node enabled: `&devcfg { status = "okay"; };` (the node
  exists in zynq-7000.dtsi, disabled or absent in our current dts — verify).

## 4. Open questions to resolve on hardware

1. ~~**4th IRQ (SPI 32)**~~ — RESOLVED (M4, §10): the stock
   driver never requests any of the 4 DT IRQs; they are
   `platform_get_irq`-validated in probe only. No handler exists at all.
2. **WF block size** — assume 32768 B until `readed` values say otherwise;
   ring size is 0x7fc00 per stream (§10), fifo counters in 128-byte units.
3. ~~**GET_DNA**~~ — RESOLVED (M3, from stock binary): u64 at
   **status+0x0c** (FPGA status region 0x41000000), two u32 reads; NOT
   devcfg DNA registers, NOT SLCR, NOT the 0x1c offset the iliasam-derived
   spec struct claims. The stock open() license check XORs the same two
   words (status+0xc/+0x10) with 0x1219d351/0x87abfd3d. Remaining for
   hardware: confirm the value is stable across boots and matches what
   stock GET_DNA returns.
4. **WF_READ_CONTINUES delivery path** — see §1 last bullet. M3 finding
   from the binary: stock's WF_START tests the flag from a stack slot it
   never stored the argument into. M4 refined the direction (§10): the
   stale slot is 0, so stock **always sets** the bit in the
   continuous mask @config+0x9e. Our driver honours the flag from the
   WF_START argument (documented ABI intent); verify real behaviour at
   the HW gate.

## 5. M3 — register map corrected from the stock binary

Disassembling the stock ioctl/open paths (.tmp/ioctl-disasm.txt,
dis-zynqsdr_open.txt) corrected several offsets that earlier docs had
copied from iliasam's write-c2-files.c (a different bitstream):

| Item | iliasam/spec value | Web-888 stock binary (authoritative) |
|---|---|---|
| config ioremap size | 1 page | **0xa0** bytes |
| status ioremap size | 1 page | **0x18** bytes |
| reset register | u32 @ config+0x00 | **u16** @ config+0x00 |
| RX decimate | — | **u16 @ config+0x02** (RX_START validates arg ∈ [5,40]) |
| rx_freq slots | u32 × 16 @ +0x04 | **u64** slots @ config+0x04+ch×8 |
| GPIO mask | u8 @ +0x64 | **u32 @ config+0x84** |
| WF per-channel cfg | 8 B @ +0x44 | **12-byte stride @ config+0x6c+ch×0xc** (u64 freq @+0, u16 decimate @+8 — decimate offset to confirm in M4) |
| WF continuous mask | — | **u16 @ config+0x9e** (bit per channel) |
| signature | u32 @ status+0x00 | same @ status+0x00 |
| RX fifo fill | u32 @ +0x04 | **u16 @ status+0x04**, units of **128 bytes** (RX_READ: `lsl #7`) |
| PPS fifo count | u32 @ +0x18 | **u16 @ status+0x0a** (0 → PPS_READ -EBUSY) |
| device DNA | u64 @ +0x1c | **u64 @ status+0x0c** |
| PPS sample | pps region 0x47000000 | read from **offset 0 of the 0x42000000 mapping** |

Other recovered behaviours implemented in `config/kernel/zynqsdr.c`:

- **Open**: single opener (3×1 s retries then -EBUSY); per-open priv (0xdc0
  bytes); ioremaps happen at **open**, not probe; open clears the reset
  register, caches channel counts as **full bytes** (rx = sig&0xff,
  wf = (sig>>8)&0xff — not the &0xf nibble decode userspace uses), prints
  `zynqsdr: device is openning (<pid>)` (sic), and runs a DNA-derived
  XOR/rotate **license check** against the FPGA (anti-clone; sets a
  licensed byte that gates the RX/WF copy loop). We do NOT replicate the
  license check.
- **ioctl wrapper**: busy counter + mutex around dispatch; a per-file
  "stop" flag (set by release) short-circuits any ioctl with **-EINTR** —
  that is how stock breaks userspace's partial-read retry loops.
- **Errors**: unknown cmd → **-ENOTTY** (-25); bad channel/decimate →
  -EINVAL; AD8370_SET arg validated **≤ 255** (8-bit shift, MSB first,
  no delays; meaningful PE4312 range 0–63).
- **RX_START data plane (M4 input)**: allocates a **0x7fc00-byte coherent
  DMA buffer**, writes its bus address to **config+0x8c**, start bytes
  -9/15 @ config+0x90/0x91, then sets reset bit 0 (bit set = engine
  running). M3 deliberately does not arm the engine without the buffer.
- ~~**IRQs**: requested lazily while streaming (matches the live finding
  that SPI 29–32 have no handler while idle) — M4.~~ **CORRECTED in §10.**

## 10. M4 — data plane recovered; the "IRQ" theory disproven

A complete disassembly inventory of every function in the stock driver
(probe 0xc0487228, remove 0xc04871e8, open 0xc07a7828, release
0xc0487074, ioctl 0xc048738c–0xc0488020, license-challenge 0xc0488088,
init 0xc0a1fa14) settled the data-plane architecture:

- **There is NO IRQ handler, NO workqueue, NO kfifo anywhere in the stock
  driver.** probe() validates the 4 DT interrupts via
  `platform_get_irq(pdev, 0..3)` and nothing else ever touches them — the
  "no handler on SPI 29–32" live observation is permanent, not an idle
  state. The §9/spec inference ("requested lazily while streaming") was
  wrong. Data flow: the FPGA **bus-masters samples into PS DDR** coherent
  rings; the PS side is a pure fifo-counter poll in ioctl context.
- **RX_START** (0xc0487a30): arg-5 > 35 → -EINVAL ([5,40] confirmed);
  clear reset bit 0; decimate u16 @config+2; **if buffer not yet
  allocated**: dma_alloc_coherent(0x7fc00, gfp 0xcc0) → handle @priv+0x10,
  cpu @priv+0x14, read offset @priv+0x18 = 0; bus addr u32 @config+0x8c;
  start bytes **0xf7 (-9) @config+0x90, 0x0f (15) @config+0x91**; then set
  reset bit 0, decimate written again. Buffer **persists across re-arms**
  (start bytes/bus addr only on first arm).
- **WF_START** (0xc0487964): chan = arg & 0xff ≥ cached wf_channels →
  -EINVAL; clear reset bit (chan+1); per-channel 0x7fc00 coherent ring
  (handle/cpu/offset at priv+0x30+chan×0x28 +0/+4/+8); bus addr u32
  **@config+0x92+chan×6**; start bytes -9/15 **@config+0x96/+0x97+chan×6**;
  continuous mask u16 @config+0x9e; set reset bit (chan+1). The
  WF_READ_CONTINUES test reads a **never-stored stack slot** ([sp+0x28],
  always 0) → `tst; orreq` → stock **always SETS the mask bit** (not
  "always clear" as §4 guessed). Our driver honours the arg bit — HW
  gate must tell us which behaviour the bitstream expects.
- **Read loops** (RX 0xc0487bb0, WF 0xc0487434): copy_from_user →
  access_ok vs 0xbf000000 → engine-bit check (**read back from the reset
  register**, -EIO + printk when clear) → poll loop: stop flag → exit;
  `fifo_bytes = ioread16(status+4 | status+6+ch*2) << 7`; == read offset
  → exit (partial); chunk = min(remaining, avail or ring-end − offset on
  wrap, ring = 0x7fc00); **dma_sync_single_for_cpu(DMA_FROM_DEVICE)**;
  copy_to_user (fault → printk + -EFAULT, readed not written); offset
  saved back per stream; readed → argp+8 (RX) / argp+0xa (WF); never
  armed → rc=0 with **no readed writeback**. No sleeping anywhere — the
  userspace TaskSleepMsec retry loop is the only pacer. The loop also
  checks a license byte and a ktime deadline (set at probe to ~10 min;
  refreshed by nothing) — both only gate the *unlicensed* path; we do
  not replicate the license check, so the deadline is dead code.
- **release** (0xc0487074): stop flag @priv+0x70; msleep(10) until busy
  counter drains; clear start bytes **0x90/0x91 (RX), 0x96/0x97 (WF0),
  0x9c/0x9d (WF1)**; msleep(100); reset register bytes zeroed;
  msleep(100); dma_free RX + **two** WF rings.
- **Two WF DMA channels, not four.** release() frees exactly 2 WF rings
  and clears exactly 2×2 WF start bytes; the config space only has room
  for 2 channels at the 6-byte stride (0x92–0x9d) before the continuous
  mask at 0x9e; the status fifo array (RX @+4, WF0 @+6, WF1 @+8) puts
  PPS @+0xa where WF2 would sit. The stock bitstream's signature wf
  count is therefore expected to be 2 — confirm at the HW gate.
  (The 0x43–0x46xxxxxx WF register pages are ioremapped by neither
  stock open() nor used in its data path; open() maps only status
  0x18 B, config 0xa0 B and rx 0x1000 B.)
- **open()** maps the RX data region as **one page** (0x1000), not the
  spec's two. It is used only for the PPS sample (PPS_READ reads u32
  @rx+0 after checking the fifo count @status+0xa).
- **probe()** also caches the 5 GPIO descriptors, misc-registers, and
  stores `ktime_get() + ~600 s` as the (never-refreshed) deadline.
- Engine-state gating deviation (ours): stock reads the run bit back
  from the PL reset register; with a dead PL that reads 0 and stock
  would return -EIO after a successful arm. We gate on the cached
  per-file armed state instead — identical on live hardware, and it is
  what makes the QEMU contract (RX_START ok → RX_READ rc=0/readed=0)
  behave like stock-with-dead-FPGA.

## 11. M4→HW — blank-PL AXI hang: probe must never touch PL registers

**Observed on hardware**: `modprobe zynqsdr` with prog_done=0 (PL unprogrammed)
hard-hangs the kernel instantly — no oops, no log output. Root cause:
probe's dev_info() read the signature register (0x41000000 window); an AXI
GP-master transaction to unprogrammed PL never completes and the CPU stalls in
the load instruction. QEMU masks this (its Zynq model returns 0 for unmapped
GP reads) — hardware does not.

**Design rule (load-bearing)**: NO PL register window (0x40000000–0x47ffffff)
may be read or written until a bitstream has been loaded through /dev/xdevcfg
(prog_done=1). Probe performs zero PL MMIO. All ioctl paths that touch PL
registers are safe only after the stock runtime order: bitstream → open.
This also means open()/release() (which write the config reset register) will
hang the same way if called before the bitstream — userspace ordering is the
gate, same as stock (websdr.bin loads websdr_%s.bit before opening /dev/zynqsdr).

Related: with FPGA_MGR_ZYNQ_FPGA=n nothing programs the PL at boot
(`platform fpga-region: deferred probe pending` in dmesg; prog_done=0) until
userspace loads a bitstream, matching stock behaviour. xdevcfg's PL reset
lives in open() (zynq_slcr_init_preload_fpga +
xdevcfg_reset_pl), not probe — modprobe is PL-safe.

## 12. The `ad8370` ghost driver + attenuator identity (PE4312, not AD8370)

Two resolved questions (radare2 static RE + live SSH; primary evidence in
Appendix A).

**(a) "ad8370 loaded" = the zynqsdr driver's own probe print.** The stock
kernel's `modules.builtin` lists `kernel/drivers/char/ad8370_driver.ko`, and
`dmesg` shows exactly one related line (`ad8370 loaded`). But there are **zero**
`ad8370`/`pe4312` symbols in `/proc/kallsyms`, no `"rx888,ad8370"` DT
compatible string, no ad8370 node/device anywhere. Disassembly proves the
`ad8370 loaded` string (`0xc0915350`) is printed **by `zynqsdr_probe`** itself
(`movw/movt` @ `0xc04872fc`–`0xc0487300` → `bl _printk`). **There is no
separate ad8370 driver** — the zynqsdr driver was simply compiled from a source
file named `drivers/char/ad8370_driver.c`, keeping the misleading
file/printk/`AD8370_SET`-ioctl names. (The author began a standalone AD8370
driver, then folded attenuator control into the zynqsdr driver's ioctl 0.)

**(b) The attenuator is a PE4312, not an AD8370.** Kernel/ioctl/older docs all
say "AD8370", but the *shipping* userspace evidence points to a **PE4312**
6-bit digital step attenuator:

| Evidence for AD8370 | Evidence for PE4312 |
|---|---|
| Kernel built-in named `ad8370_driver.ko`; source path `drivers/char/ad8370_driver.c` | `zynq/peri.cpp:109` prints `Set PE4312 with %d/0x%x` immediately before the `AD8370_SET` ioctl |
| Older project docs claimed AD8370 ×2 | Ioctl arg semantics: `(int)(-attn_dB * 2)`, range **0–63** = 0–31.5 dB in **0.5 dB steps** — exactly the PE4312 datasheet; the AD8370 is a *gain* device (−11…+34 dB) |
| — | `web888.c` (same author's Red Pitaya OS driver, `RaspSDR/red-pitaya-notes` branch `WEB888_release_1024`) bit-bangs a **PE4312** on the same GPIO pins, 6-bit MSB-first |
| — | The USB sibling RX-888 MkII uses a PE4312-family DSA |

Both chips use a 3-wire serial interface, so the same GPIO bit-bang wiring
(IO_11 = DATA, IO_12 = LTCH/LE, IO_13 = CLCK) works for either — which is how
the naming confusion persisted. The 6-bit/31.5 dB attenuation semantics in the
shipping userspace match the PE4312 only. **Assessment (INFERRED, high
confidence):** on-board attenuator is a PE4312 (or pin-compatible DSA);
"AD8370" survived from an earlier design revision. (The userspace var holding
the zynqsdr fd is itself misnamed `ad8370_fd` — the confusion runs through the
whole stack.) Definitive confirmation needs board inspection or measuring the
disassembly shift-loop length (6 vs 8 bits).

Note: `app/test_vga.c` is a math-only AD8370 gain-table pre-calculator,
**not compiled into websdr.bin**; the real attenuation path is `rf_attn_set()`
in `rx/rx_sound_cmd.cpp` (`SET rf_attn=%f`) and `hpsdr/hpsdr.cpp`.

**This corrects earlier claims** in `hardware-reference.md`
("AD8370 (HF/VHF) on I2C 0xCA/0xCB" — wrong: it's a 3-wire device, not I2C;
those aren't valid 7-bit I2C addresses) and `red-pitaya-firmware.md`.

## 13. Stock-binary provenance + Web-888 vs Red Pitaya access model

**Stock-binary internals (radare2; primary evidence in Appendix A):** kernel image mapped
`vaddr = file_offset + 0xC0008000`. `zynqsdr_driver` struct @ `0xc0b258f4`
(`.name="zynqsdr"` @ `0xc0a2d2ac`, `.probe=0xc0487228`, `.remove=0xc04871e8`);
ioctl jump table @ `0xc0487684` (21 slots, `idx = cmd − 0x40045a00`); ioctl
magic `'Z'` (`0x5a`) in bits 8–15 of every command; `zynqsdr_driver_init` @
`0xc0a1fa14` (init section, freed after boot → zero ad8370 runtime symbols);
`zynqsdr_open` @ `0xc07a7828`. Userspace `websdr.bin` (Thumb-2 PIE, GCC Alpine
13.2.1): issues `AD8370_SET/MODE_SET/CLK_SET/GET_SIGNATURE` from `peri.cpp` @
file offset `0x6f1e8`; loads the bitstream via `system("cat
/media/mmcblk0p1/websdr_%s.bit > /dev/xdevcfg")` (string @ `0x69024`); embedded
build paths `/root/ZynqSDR/zynq/peri.cpp`, `/root/ZynqSDR/app/rx/iq_fft.cpp`
(private source tree named `ZynqSDR`). xdevcfg sysfs attrs (`prog_done`,
`is_partial_bitstream`, …) live on
`/sys/devices/soc0/axi/f8007000.devcfg/`, not the zynqsdr device.

**Live userspace footprint:** `websdr.bin` (supervised by OpenRC
`supervise-daemon sdrd`) holds exactly two device FDs — fd 3 = `/dev/i2c-0`
(Si5351), fd 4 = `/dev/zynqsdr` (no `/dev/mem` or `/dev/xdevcfg` held open —
bitstream fd closed after one-shot load). Four `websdr.drm-00…03` DRM-decoder
children each hold the same two FDs.

**Web-888 vs Red Pitaya access model** (why the two stacks can coexist on one
kernel; see `red-pitaya-firmware.md` / `redpitaya-port-guide.md`):

| Aspect | Web-888 (`/dev/zynqsdr`) | Red Pitaya (`/dev/mem`) |
|---|---|---|
| Interface | ioctl char device | direct `mmap()` of `/dev/mem` |
| Data transfer | kernel copies FPGA DMA buffers to userspace | userspace polls FIFO counters, reads directly |
| Interrupts | DT IRQs declared, validated in probe only (no handler — poll in ioctl context; §10) | polling loop |
| Driver code | custom kernel module (now in `config/kernel/zynqsdr.c`) | no kernel code needed |
| Buffer mgmt | kernel-side coherent rings | userspace-managed |

The two stacks touch the same physical register pages but via different
mechanisms, and only one app owns the FPGA at a time at runtime — so a unified
kernel carrying both zynqsdr + xdevcfg has no conflict.

## 14. BUG 3 fix — WF engine decim latch; WF_PARAM completed disasm

The WF_PARAM disasm was completed (`.tmp/stock/web888-kernel-image.bin`, r2):
stock caches BOTH decim (per-channel struct +0x20) and freq (+0x28·(chan+1))
and rewrites both registers when EITHER changes; the decim-equal path
(0xc0487edc) compares cached freq and re-enters the write path on a
freq-only change; both-equal is the only no-op. **Stock issues NO reset
pulse.** PPS_START's delay constant resolved: 0x346dc = 214748 ns ≈ 215 µs
via `arm_delay_ops` (matches our `udelay(215)`).

BUG 3 (waterfall comb+stripes) root cause, verified live: the Web-888
bitstream's WF engine **latches decimate at (re)start and ignores later
register writes** (regime A), and websdr's per-frame WF_START re-arms
restarted the producer at ring head every 43 ms so 5/16 frames read the
never-refreshed ring tail (regime B, 16-frame stripe beat). Fixes:

1. Driver WF_PARAM: per-channel decim+freq caches; no-op when both
   unchanged; on a DECIM change with the channel armed, pulses the channel
   reset bit (clear, udelay 215, set) to force re-latch, and resyncs the
   consumer ring offset to 0. Deliberate deviation from stock, forced by
   the measured engine latch. Verified by direct ioctl test: producer rate
   tracks 122.88M/decim × 4 B to <0.2 % across 32/64/128 changes.
2. websdr `peri.cpp` `fpga_reset_wf()` CONT-flag bug (§1, §4): now passes
   `data` (with WF_READ_CONTINUES) to WF_START. Fix lives in
   `config/websdr/patches/0012-wf-engine-decim-rearm.patch`.
3. websdr `rx_waterfall.cpp` non-shared non-overlapped path: param+rearm
   only on decim change (new `wf_inst_t.fpga_decim_sent`), armed with
   cont=true — continuous free-run instead of per-frame re-arm.

Post-fix E2E: no 16-frame periodicity in captured z7 frames, no comb in
the column spectrum; z7 waterfall character now matches the always-clean
z6.

## Appendix A — primary RE evidence (folded from the retired raw reports)

This appendix preserves the verifiable primary-source data behind §5/§10/§12/§13
(originally two raw investigation reports, retired; their verifiable data
is preserved here).

### A.1 Stock device tree — verbatim nodes

From the decompiled stock `boot.bin` DTB:

```dts
pps {
    compatible = "pps-gpio";
    gpios = <0x0b 0x36 0x00>;          /* &gpio0, pin 54 (EMIO[0]), ACTIVE_HIGH */
    capture-clear;
};

zynqsdr {
    compatible = "rx888,zynqsdr";
    interrupt-parent = <0x04>;
    interrupts = <0x00 0x1d 0x01 0x00 0x1e 0x01 0x00 0x1f 0x01 0x00 0x20 0x01>;
    gpios = <0x0b 0x0a 0x01 0x0b 0x0d 0x01 0x0b 0x0c 0x01 0x0b 0x0b 0x01 0x0b 0x31 0x01>;
};
```

Decoded: interrupts = GIC SPI 29/30/31/32, rising edge (Linux IRQ 61–64; no
handler is ever registered — §10). gpios = &gpio0 pins **10, 13, 12, 11, 49**,
all ACTIVE_LOW, roles per §1: HF/VHF switch, attenuator CLCK/LTCH/DATA,
external-clock select. Live sysfs check: gpiochip512 (`zynq_gpio`, base 512,
ngpio 118) maps these to sysfs GPIOs 522/525/524/523/561 (matches the RaspSDR
peri.c pin numbers). There is **no** ad8370 DT node anywhere (binary string
scan: `rx888,ad8370` = 0 hits).

### A.2 Kernel-image symbol & struct inventory

Kernel image: flat vmlinux (zImage decompressed, 11,740,160 B), mapped
`vaddr = file_offset + 0xC0008000` (validated: `zynqsdr_probe` file `0x47f228`
↔ vaddr `0xc0487228`). Symbol table stripped; `CONFIG_IKCONFIG` **disabled**
(kernel .config unrecoverable from the image; no IKCFG/CPIO config blob).
`CONFIG_KALLSYMS_ALL=y` — the five static `zynqsdr_*` text symbols:

| symbol | vaddr | file offset | size |
|---|---|---|---|
| `zynqsdr_remove` | `0xc04871e8` | `0x47f1e8` | ~80 B |
| `zynqsdr_probe` | `0xc0487228` | `0x47f228` | ~720 B |
| `zynqsdr_ioctl` | `0xc048738c` | `0x47f38c` | ~3 KB |
| `zynqsdr_open` | `0xc07a7828` | `0x793828` | ~1.1 KB (3.2 MB from probe — `-ffunction-sections` cold placement) |
| `zynqsdr_driver_init` | `0xc0a1fa14` | `0x991a14` | 4-insn trampoline → `__platform_driver_register` (`0xc0494898`) |

Static data: `struct miscdevice zynqsdr_misc` @ `0xc0b258e0`,
`struct platform_driver zynqsdr_driver` @ `0xc0b258f4` (`.probe=0xc0487228`,
`.remove=0xc04871e8`, `prevent_deferred_probe=true`; `of_match_table` region
with the single `rx888,zynqsdr` string @ `0xc082620c`). `/dev/zynqsdr` = misc
**10:126**. The xdevcfg sysfs attribute group (`prog_done`,
`is_partial_bitstream`, `dbg_lock`, `enable_*`, …; 16-B structs, mode 0644)
sits @ `0xc0b25800` and surfaces under `/sys/class/misc/zynqsdr/` (these are
Xilinx devcfg attributes, unrelated to attenuator control).

### A.3 "ad8370 loaded" provenance proof (§12a)

The string `\x01\x36ad8370 loaded\n` (KERN_SOH + KERN_INFO) lives @ vaddr
`0xc0915350` (file `0x90d350`), in one contiguous `.rodata` block
(`0x90d2xx–0x90d6xx`) with all other zynqsdr printk bodies
(`zynqsdr: device is openning (%d)`, `Genuine Web-888 Detected`,
`FPGA Signature: 0x%x`, …). No literal-pool reference exists; the address is
materialised by a `movw/movt` pair **inside `zynqsdr_probe`**:

```
0xc04872fc:  movw r0, #0x5350
0xc0487300:  movt r0, #0xc091          ; r0 = 0xc0915350
0xc0487310:  bl   0xc07a07b8            ; _printk
```

Boot dmesg confirms it fires at driver init, before any userspace open.

### A.4 ioctl dispatch inventory (supplements §10)

`zynqsdr_ioctl` (`0xc048738c`): chained compare cascade for large-nr commands
(`cmp r7, #0x400c5a05` → `bls` small-nr dispatch; `0x80045a15` RX-read →
`0xc0487b60`; `0xc00c5a06` RW → `0xc0487bb0`; …) plus a 21-slot jump table @
`0xc0487684` (`idx = cmd − 0x40045a00`; default `0xc04876d8` = `mvn r7,#0x18`
→ **-ENOTTY**). Handler targets recovered: nr0 `0xc0487900`, nr1 `0xc0487938`,
nr2 `0xc0487914`, nr4 `0xc0487a30` (RX_START), nr7 `0xc0487958`,
nr0xa `0xc0487964` (WF_START), nr0x14 `0xc04878bc`. websdr.bin's control
function (file offset `0x6f1e8`, Thumb-2) issues ioctls `0x40045a00/01/02` +
read `0x80045a09` (GET_GPIO_MASK, copies 4 B from `ctx+8`). Per-open context
layout: `+0x70` stop/lock byte, `+0x74` ldrex/strex refcount.

### A.5 Toolchain & image provenance

| artifact | fact |
|---|---|
| websdr.bin | ELF32, ARM Thumb-2 EABI5, PIE, 7,124,020 B; `GCC: (Alpine 13.2.1_git20240309) 13.2.1` |
| stock kernel | `arm-linux-gnueabihf-gcc (Debian 12.2.0-14) 12.2.0`; version string `6.6.110-xilinx` |
| embedded build paths | `/root/ZynqSDR/zynq/peri.cpp`, `/root/ZynqSDR/zynq/timer.cpp` (private tree named `ZynqSDR`) |
| live modules | lsmod shows only nf_tables/libcrc32c/nfnetlink/sha256/cfg80211/8021q/pps_gpio — all SDR-critical drivers built-in |
| userspace fds | websdr.bin holds only `/dev/i2c-0` + `/dev/zynqsdr`; four `websdr.drm-00…03` children hold the same two fds (§13) |
