# Stock FSBL ps7_init analysis — Web-888

Extraction and decode of the `ps7_init_*` register-initialization tables
embedded in the stock FSBL (`work/stock/fsbl.bin`, 114,696 bytes). These
tables are the board-specific DDR/MIO/clock configuration that a
source-built FSBL (see the fsbl-source-build plan) must reproduce to boot
the Web-888 hardware.

Authoritative outputs produced by `scripts/extract-ps7-init.py`
(re-run any time; everything lands in the gitignored `.tmp/ps7-init/`):

| artifact | content |
| --- | --- |
| `.tmp/ps7-init/ps7_init_data.c` | the 21 arrays re-emitted in embeddedsw `ps7_init.c` format, names `ps7_<group>_init_data_<ver>` |
| `.tmp/ps7-init/arrays.bin` | raw concatenated opwords (fsbl.bin `.rodata` range `0x12580..0x14E00`) |
| `.tmp/ps7-init/decode.txt` | full per-op decode with UG585 register/field names + cross-check reports |
| `.tmp/ps7-init/manifest.h` | name/offset/length table for the round-trip harness |
| `.tmp/ps7-init/roundtrip` | host-gcc harness that byte-compares the emitted arrays against fsbl.bin |

Status of verification: **round-trip byte-identical, 21/21 arrays** (see §6).

## 1. Encoding found in the stock binary

The arrays are stored as little-endian 32-bit opwords using the exact
encoding defined by the vendored embeddedsw skeleton
(`resources/reference/embeddedsw-zynq-fsbl/lib/sw_apps/zynq_fsbl/misc/zed/ps7_init.h:35-49`):

```
first word = (opcode << 4) | argcount
opcode 0 EXIT        (0 args)
opcode 1 CLEAR       (1 arg:  addr)
opcode 2 WRITE       (2 args: addr, val)
opcode 3 MASKWRITE   (3 args: addr, mask, val)
opcode 4 MASKPOLL    (2 args: addr, mask)
opcode 5 MASKDELAY   (2 args: addr, mask)
```

Groups other than `ddr` open with `EMIT_WRITE(0xF8000008, 0x0000DF0D)`
(SLCR_UNLOCK) and close with `EMIT_WRITE(0xF8000004, 0x0000767B)`
(SLCR_LOCK) then `EMIT_EXIT()`; `ddr` groups start directly with
`EMIT_MASKWRITE(0xF8006000, …)` (the DDRC clock is already running and the
register bank is not SLCR-protected) and end with
`MASKPOLL(0xF8000B74, 0x2000)` (DCI calibration done) →
`MASKWRITE(0xF8006000, …, soft_rstb=1)` → `MASKPOLL(0xF8006054, 0x7)`
(DRAM operating mode) → `EMIT_EXIT()`.

**Deviation from the task brief:** the brief assumed a raw
`(addr, mask, val)` triplet format with an SLCR_LOCK-then-SLCR_UNLOCK
scan signature. The real format is the opcode-word format above (the
signature `LE(0xF800000B), LE(0xDF0D)` does not occur anywhere in
fsbl.bin). The extractor was adapted to walk the real encoding; the
"exactly 15" invariant is kept (15 SLCR-anchored groups = 5 groups ×
3 silicon versions) and additionally 3 `ddr` + 3 `debug` groups are
required, 21 arrays total.

## 2. Array inventory (21 arrays, contiguous `.rodata` block)

Silicon version of each group is assigned by offset order
(3_0 → 2_0 → 1_0), matching the vendored zed reference layout.

| group (3_0) | offset | ops | bytes | note |
| --- | --- | --- | --- | --- |
| ps7_post_config_3_0 | 0x12580 | 4 | 60 | identical across versions |
| ps7_debug_3_0 | 0x12634 | 4 | 40 | CTI LAR unlocks ×3 |
| ps7_pll_init_data_3_0 | 0x126AC | 25 | 384 | |
| ps7_clock_init_data_3_0 | 0x1282C | 11 | 172 | |
| ps7_ddr_init_data_3_0 | 0x128D8 | 81 | 1292 | |
| ps7_peripherals_init_data_3_0 | 0x12DE4 | 22 | 344 | |
| ps7_mio_init_data_3_0 | 0x12F3C | 72 | 1148 | |

2_0 blocks start at 0x133B8, 1_0 blocks at 0x140E4; same group order.
`ddr` differs across versions (81/83/82 ops — teardown/poll differences),
`peripherals` and `mio` also differ across versions; `pll` and `clock`
are byte-identical across all three versions. `post_config` performs
only `LVL_SHFTR_EN=0xF`, `FPGA_RST_CTRL=0`; `debug` only writes
`0xC5ACCE55` to the three CTI LAR registers.

189 unique register addresses are written in total. Notably the stock
tables never touch DDRIOB 0xB04–0xB3C — same as the vendored
embeddedsw v2023.1 zed tables.

## 3. Clock configuration (PS_CLK = 33.333 MHz assumed)

| PLL | FDIV | VCO | result |
| --- | --- | --- | --- |
| ARM | 0x28 (40) | 1333.3 MHz | ARM_CLK_CTRL DIVISOR=2 → **CPU 666.7 MHz**, ratio 6:2:1 |
| DDR | 0x20 (32) | 1066.7 MHz | DDR_CLK_CTRL 3X÷2, 2X÷3 → **DDR3 533.3 MHz** (1066 Mb/s), 355.6 MHz 2X |
| IO  | 0x1E (30) | 1000.0 MHz | per-peripheral divisors |

`APER_CLK_CTRL = 0x017C044D` gates on: UART0/1, GPIO, SDIO0, ENET0,
I2C0, SPI0 — consistent with the MIO mapping below. GEM0 clocked from
IO PLL ÷8 (125 MHz) with RCLK ÷1 (125 MHz RX) — gigabit ethernet.
`DCI_CLK_CTRL = 0x00700F01`.

## 4. MIO mapping vs `work/redpitaya-src/cfg/red_pitaya.xml`

All functional pin assignments in the stock tables match the Red Pitaya
upstream preset (asserted by the extractor; full listing in
`.tmp/ps7-init/decode.txt`):

| peripheral | stock MIO | xml preset | result |
| --- | --- | --- | --- |
| ENET0 + MDIO | 16..27, 52/53 | same | OK |
| USB0 | 28..39 | same | OK |
| SDIO0 | 40..45 (+47 WP) | same | OK |
| UART1 / UART0 | 8/9, 14/15 | same | OK |
| I2C0 | 50/51 | same | OK |
| MIO1 GPIO | 0..7, 46..49 | same | OK |
| bank1 IO_Type | LVCMOS25 | 2.5 V | OK |
| `MIO_MST_TRI0` | 0x0038002F (pins 0-3,5,19-21 tristated) | — | recorded |

Observed deltas (recorded, not resolved): USB0 pins 28–39 have pullups
**enabled** in the stock tables while the xml preset sets pullup=disable
for MIO 16–39; the xml also leaves SD0 CD unassigned (stock MIO 46 is
GPIO, used as CD by software).

## 5. DDRC/DDRP/DDRIOB vs u-boot zynq-zybo-z7 ps7_init_gpl.c

The extractor folds the MASKWRITE sequence under read-modify-write
semantics and diffs the final per-register values (stock 3_0 tables vs
the zybo-z7 `_3_0` tables, local copy
`work/u-boot/board/xilinx/zynq/zynq-zybo-z7/ps7_init_gpl.c`).
Summary: **56 registers identical, 34 differ, 1 stock-only, 2 ref-only**
(full table in `decode.txt`). Substantive differences:

| register | stock | zybo-z7 | interpretation |
| --- | --- | --- | --- |
| `ddrc_ctrl` (0x6000) | 0x85 | 0x81 | **stock = 16-bit bus** (bit2), zybo = 32-bit (two chips) |
| `DRAM_addr_map_{bank,col,row}` | 0x666 / 0xFFFF0000 / 0x0F555555 | 0x777 / 0xFFF00000 / 0x0F666666 | one-bit shift consistent with 16-bit vs 32-bit bus, same 4 Gb geometry (15 rows/10 cols/8 banks) |
| `DRAM_EMR_MR_reg` (0x6030) | MR0=0x0B30 MR1=0x0004 | MR0=0x0930 MR1=0x0004 | CL=7 both; tWR differs (stock 10 cyc, zybo 8 cyc) — speed-bin (-125 vs -107) |
| `DRAM_param_reg0..4`, `Two_rank_cfg` | t_rc/t_rfc etc. | differs | timing re-derive for 533 MHz vs 525 MHz + speed bin |
| `DRAM_ODT_reg` (0x6048) | 0x0003C248 | same field values after folding | ODT scheme identical |
| `DDRIOB_DATA1/DIFF1` (0xB4C/0xB54) | **0x00000800** (PULLUP_EN only) | 0x672 / 0x674 | stock leaves upper-byte slice IOB config cleared except pullup; see §6 |
| `DDRIOB_DRIVE_SLEW_*` (0xB5C–0xB68) | 0x0018C61C / 0x00F9861C ×3 | 0x0018C068 / 0x00F98068 ×3 | drive/termination codes differ — consistent with a different IO voltage class and/or board calibration |
| `DDRIOB_DDR_REFCTRL0` (0xB6C) | 0x220 (VREF_SEL=2) | 0x260 (VREF_SEL=6) | see §6 — VREF_INT_EN=0 in both |
| `refresh_timer` (0x60A0) | 0x8000 | absent | Vivado generator-version delta |
| `DFI_dram_clk_timing`/`DFI_ck_timing` (0x6078/0x607C) | absent | present | Vivado generator-version delta |
| PHY ratios (0x612C–0x6188) | 0x29000 / 0x80 / 0xF9 / 0xC0 base | 0x27000/0x26C00… | frequency/speed-bin derived; kept as-is per brief |

`DATA0` (0x672) and `DIFF0` (0x674) are **identical** stock vs zybo.
DCI: `DDRIOB_DCI_CTRL` final = 0x823 (calibration codes), DCI DONE
polled via 0xB74 bit13 before DDRC soft reset release.

## 6. MT41J (DDR3, 1.5 V) vs MT41K (DDR3L, 1.35 V) evidence

`red_pitaya.xml` declares `PARTNO = MT41J256M16 RE-125` (DDR3, 1.5 V
class), but the physical part on Web-888 units has been questioned
(J vs K). Evidence decoded from the stock tables — **recorded, not
decided**:

1. **Bus/geometry**: 16-bit single-chip 4 Gb (15R×10C×8B) — fits both
   MT41J256M16 and MT41K256M16. Not discriminating.
2. **MR0/MR1**: MR1 = 0x0004 in stock, zed (DDR3) and zybo (DDR3L) —
   identical output-drive/RTT_Nom programming across voltage classes.
   Not discriminating.
3. **INP_TYPE** (DDRIOB slice config): stock DATA0=1 / DIFF0=2 —
   *identical* to the zybo-z7 DDR3L preset. The SSTL input-buffer type
   code does not encode 1.35 V vs 1.5 V; the IO standard voltage comes
   from the DDRIOB bank Vcco (hardware). Not discriminating by itself.
4. **VREF_SEL**: stock=2, zybo DDR3L=6. *However* `VREF_INT_EN=0` in
   both — the internal Vref generator is disabled, so VREF_SEL is
   likely inert and the difference may be a generator artifact rather
   than a board property. Weak evidence; if taken at face value the
   lower code would point to a *lower* Vref (i.e. 1.35 V class).
5. **DRIVE_SLEW codes**: stock programs different DRIVE_P/N values than
   the DDR3L reference (0x61C vs 0x068 low fields). Different drive
   strength/termination programming is *consistent* with a different IO
   voltage class, but could equally be Red Pitaya board calibration.
   Weak evidence.
6. **DATA1/DIFF1 = 0x800 quirk**: stock disables IBUF/termination/
   output-enable on the upper-byte slice and leaves only PULLUP_EN.
   Despite this the stock FSBL boots and the DDR works on real hardware
   (later stage-1 or the DDRC hardware init presumably covers it).
   Unusual; recorded as-is.
7. **Speed bin**: xml `-125` (1.25 ns, DDR3-800 capable) while the
   stock tables run the DRAM at 533 MHz with CL=7/tWR=10 — inside both
   J-125 and K-125/-107 bins. Not discriminating.

`docs/research/hardware-facts.md` currently records only "512 MB DDR3"
from `/proc/meminfo` — no part marking. **No conclusion is drawn here**;
the tables are extracted verbatim, so the source-built FSBL inherits
whatever the stock configuration does regardless of the J/K question.

## 7. Round-trip verification

`.tmp/ps7-init/roundtrip.c` recompiles the emitted
`ps7_init_data.c` with host gcc (with `long` redefined to `int` so the
arrays are 32-bit words on a 64-bit host, exactly what
`ps7_init.c:32-33` anticipates) and byte-compares every array against
fsbl.bin using the offsets in `manifest.h`:

```
ROUND-TRIP OK: 21/21 arrays byte-identical
```

This proves (a) the scan found the complete arrays including EXIT
words, (b) the emitter reproduces the exact binary encoding, and
(c) the emitted `ps7_init_data.c` is a drop-in board table for Task 3.

## 8. Usage by Task 3

Task 3 should arrange for the source-built FSBL to use
`ps7_init_data.c` generated by this script (e.g. copied/overlaid onto
the board-specific `misc/<board>/` directory of the vendored embeddedsw
tree at build time, or compiled as an additional translation unit — the
symbol names already match what `ps7_init.c` expects). Do **not**
hand-edit the emitted file; regenerate with `scripts/extract-ps7-init.py`.

## 9. Limitations

- Silicon-version assignment per group is by offset order (validated
  against the zed reference layout); the tables carry no explicit
  version tags.
- Register-name coverage is ~100 registers (all addresses the stock
  tables actually touch); names marked `*` in decode.txt are
  field-derived rather than UG585 register names.
- The MIO/DDRC cross-checks assert against third-party presets
  (red_pitaya.xml, zybo-z7); they catch regressions but are not
  hardware truth.
- The DATA1/DIFF1=0x800 and USB0-pullup observations are faithful
  reproductions of the stock tables, not necessarily intentions.
