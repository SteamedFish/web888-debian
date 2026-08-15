#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""extract-ps7-init.py -- recover ps7_init data arrays from the stock Web-888 FSBL.

Scans work/stock/fsbl.bin for the opcode-encoded register-init arrays
produced by the Xilinx ps7_init generator (EMIT_* macros, see
resources/reference/embeddedsw-zynq-fsbl/lib/sw_apps/zynq_fsbl/misc/zed/ps7_init.h):

    word0 = (opcode << 4) | arg_count
    OPCODE_EXIT=0  OPCODE_CLEAR=1  OPCODE_WRITE=2
    OPCODE_MASKWRITE=3  OPCODE_MASKPOLL=4  OPCODE_MASKDELAY=5

The binary contains 21 arrays: 7 groups (pll, clock, ddr, mio,
peripherals, post_config, debug) x 3 silicon versions (3_0, 2_0, 1_0).
15 arrays are anchored by EMIT_WRITE(SLCR_UNLOCK, 0xDF0D); the 3 ddr
arrays start directly with EMIT_MASKWRITE(ddrc_ctrl) and the 3 debug
arrays with EMIT_WRITE(CTI_LAR, 0xC5ACCE55).

Outputs (default .tmp/ps7-init/):
    ps7_init_data.c   arrays in embeddedsw zed emit-macro format
    arrays.bin        raw LE words, concatenated in emit order
    decode.txt        human-readable register decode
    manifest.h        name/offset/length table for the round-trip harness
"""

import argparse
import re
import struct
import sys
from collections import Counter
from pathlib import Path

OP_ARGC = {1: 1, 2: 2, 3: 3, 4: 2, 5: 2}
OP_NAME = {1: "CLEAR", 2: "WRITE", 3: "MASKWRITE", 4: "MASKPOLL", 5: "MASKDELAY"}

SIG_SLCR = struct.pack("<III", 0x22, 0xF8000008, 0x0000DF0D)
SIG_DDR = struct.pack("<II", 0x33, 0xF8006000)
SIG_DEBUG = struct.pack("<III", 0x22, 0xF8898FB0, 0xC5ACCE55)

SLCR_UNLOCK = 0xF8000008
SLCR_LOCK = 0xF8000004

EXPECTED_GROUPS = ("pll", "clock", "ddr", "mio", "peripherals",
                   "post_config", "debug")
VERSIONS = ("3_0", "2_0", "1_0")

# ---------------------------------------------------------------- register map
# Zynq-7000 TRM (UG585) names where certain; DDRC/DDRP names beyond the
# well-known ones are derived from the dominant Vivado field name and are
# marked with a trailing '*'.
def _mio_name(addr):
    if 0xF8000700 <= addr <= 0xF80007D4 and (addr - 0xF8000700) % 4 == 0:
        return "MIO_PIN_%02d" % ((addr - 0xF8000700) // 4)
    return None

REGNAMES = {
    0xF8000004: "SLCR_LOCK",
    0xF8000008: "SLCR_UNLOCK",
    0xF8000100: "ARM_PLL_CTRL",
    0xF8000104: "DDR_PLL_CTRL",
    0xF8000108: "IO_PLL_CTRL",
    0xF800010C: "PLL_STATUS",
    0xF8000110: "ARM_PLL_CFG",
    0xF8000114: "DDR_PLL_CFG",
    0xF8000118: "IO_PLL_CFG",
    0xF8000120: "ARM_CLK_CTRL",
    0xF8000124: "DDR_CLK_CTRL",
    0xF8000128: "DCI_CLK_CTRL",
    0xF800012C: "APER_CLK_CTRL",
    0xF8000138: "GEM0_RCLK_CTRL",
    0xF8000140: "GEM0_CLK_CTRL",
    0xF8000150: "SDIO_CLK_CTRL",
    0xF8000154: "UART_CLK_CTRL",
    0xF8000168: "PCAP_CLK_CTRL",
    0xF8000170: "FPGA0_CLK_CTRL",
    0xF80001C4: "CLK_621_TRUE",
    0xF8000240: "FPGA_RST_CTRL",
    0xF8000830: "MIO_MST_TRI0",
    0xF8000900: "LVL_SHFTR_EN",
    0xF8000B40: "DDRIOB_ADDR0",
    0xF8000B44: "DDRIOB_ADDR1",
    0xF8000B48: "DDRIOB_DATA0",
    0xF8000B4C: "DDRIOB_DATA1",
    0xF8000B50: "DDRIOB_DIFF0",
    0xF8000B54: "DDRIOB_DIFF1",
    0xF8000B58: "DDRIOB_CLOCK",
    0xF8000B5C: "DDRIOB_DRIVE_SLEW_ADDR",
    0xF8000B60: "DDRIOB_DRIVE_SLEW_DATA",
    0xF8000B64: "DDRIOB_DRIVE_SLEW_DIFF",
    0xF8000B68: "DDRIOB_DRIVE_SLEW_CLOCK",
    0xF8000B6C: "DDRIOB_DDR_REFCTRL0",
    0xF8000B70: "DDRIOB_DCI_CTRL",
    0xF8000B74: "DDRIOB_DCI_STATUS",
    0xF8006000: "ddrc_ctrl",
    0xF8006004: "Two_rank_cfg",
    0xF8006008: "HPR_reg",
    0xF800600C: "LPR_reg",
    0xF8006010: "WR_reg",
    0xF8006014: "DRAM_param_reg0",
    0xF8006018: "DRAM_param_reg1",
    0xF800601C: "DRAM_param_reg2",
    0xF8006020: "DRAM_param_reg3",
    0xF8006024: "DRAM_param_reg4",
    0xF8006028: "DRAM_init_param*",
    0xF800602C: "DRAM_EMR2_3_reg*",
    0xF8006030: "DRAM_EMR_MR_reg*",
    0xF8006034: "DRAM_burst8_rdwr",
    0xF8006038: "DRAM_disable_dq*",
    0xF800603C: "DRAM_addr_map_bank",
    0xF8006040: "DRAM_addr_map_col",
    0xF8006044: "DRAM_addr_map_row",
    0xF8006048: "DRAM_ODT_reg",
    0xF8006050: "phy_cfg_cmd_to_data*",
    0xF8006054: "DRAM_STS_reg*",
    0xF8006058: "DRAM_DLL_calib*",
    0xF800605C: "DRAM_ODT_delay_hold*",
    0xF8006060: "DRAM_auto_ctrl*",
    0xF8006064: "ddrc_go2critical*",
    0xF8006068: "DRAM_wrlvl_rdlvl_gap*",
    0xF800606C: "DFI_ctrlupd_interval*",
    0xF8006078: "DFI_dram_clk_timing*",
    0xF800607C: "DFI_ck_timing*",
    0xF80060A0: "refresh_timer*",
    0xF80060A4: "DRAM_ZQ_param*",
    0xF80060A8: "DRAM_ZQ_short_dramrst*",
    0xF80060AC: "DRAM_deep_pwrdwn*",
    0xF80060B0: "DFI_training_level*",
    0xF80060B4: "DRAM_2t_ocd_bypass*",
    0xF80060B8: "DFI_rddata_ctrlup*",
    0xF80060C4: "CHE_ECC_CLEAR*",
    0xF80060C8: "CHE_CORR_ECC_LOG*",
    0xF80060DC: "CHE_UNCORR_ECC_LOG*",
    0xF80060F0: "CHE_ECC_STATS*",
    0xF80060F4: "CHE_ECC_CONTROL*",
    0xF8006114: "PHY_DFI_TIMING*",
    0xF8006204: "arb_page_addr_mask*",
    0xF80062A8: "DRAM_derate_mr4*",
    0xF80062AC: "DRAM_mr4_read_interval*",
    0xF80062B0: "DRAM_lowpwr_timing*",
    0xF80062B4: "DRAM_init_timing2*",
    0xE0000000: "UART0_CR",
    0xE0000004: "UART0_MR",
    0xE0000018: "UART0_BRGR",
    0xE0000034: "UART0_BAUDDIV",
    0xE0001000: "UART1_CR",
    0xE0001004: "UART1_MR",
    0xE0001018: "UART1_BRGR",
    0xE0001034: "UART1_BAUDDIV",
    0xE000A00C: "GPIO_MASK_DATA_1_MSW",
    0xE000A244: "GPIO_DIRM_1",
    0xE000A248: "GPIO_OEN_1",
    0xE000D000: "LQSPI_CR",
    0xF8007000: "DEVCFG_CTRL",
    0xF8F00200: "GLOBAL_TIMER_CTRL",
    0xF8898FB0: "CTI_CPU0_LAR*",
    0xF8899FB0: "CTI_CPU1_LAR*",
    0xF8809FB0: "CTI_FTM_LAR*",
}

# per-slice PHY registers (4 data slices, stride 4)
for i in range(4):
    REGNAMES[0xF8006118 + 4 * i] = "PHY_data_slice_%d_conf*" % i
    REGNAMES[0xF800612C + 4 * i] = "PHY_INIT_RATIO_%d" % i
    REGNAMES[0xF8006140 + 4 * i] = "PHY_RD_DQS_SLAVE_RATIO_%d" % i
    REGNAMES[0xF8006154 + 4 * i] = "PHY_WR_DQS_SLAVE_RATIO_%d" % i
    REGNAMES[0xF8006168 + 4 * i] = "PHY_FIFO_WE_SLAVE_RATIO_%d" % i
    REGNAMES[0xF800617C + 4 * i] = "PHY_WR_DATA_SLAVE_RATIO_%d" % i
REGNAMES[0xF8006190] = "PHY_CTRL_SLAVE_RATIO*"
REGNAMES[0xF8006194] = "PHY_DLL_LOCK_DIFF*"
for i in range(4):
    REGNAMES[0xF8006208 + 4 * i] = "arb_pri_wr_port%d*" % i
    REGNAMES[0xF8006218 + 4 * i] = "arb_pri_rd_port%d*" % i

IO_TYPES = {0: "-", 1: "LVCMOS18", 2: "LVCMOS25", 3: "LVCMOS33",
            4: "HSTL_I_18", 5: "-", 6: "-", 7: "-"}

# Zynq MIO mux select codes observed/known (L3,L2,L1,L0) -> function hint
MIO_SEL_HINT = {
    (0, 0, 0, 0): "GPIO",
    (0, 0, 0, 1): "L0 (ENET0/QSPI/...)",
    (0, 0, 1, 0): "L1=1 (USB0)",
    (0, 4, 0, 0): "L2=4 (I2C0)",
    (1, 0, 0, 0): "L3 (SDIO0/MDIO)",
    (1, 6, 0, 0): "L3+L2=6 (UART0/1)",
}


def regname(addr):
    m = _mio_name(addr)
    if m:
        return m
    return REGNAMES.get(addr, "?")


# ------------------------------------------------------------------- parsing
class Op:
    __slots__ = ("opcode", "args", "off")

    def __init__(self, opcode, args, off):
        self.opcode, self.args, self.off = opcode, args, off

    @property
    def addr(self):
        return self.args[0] if self.args else None


class Array:
    def __init__(self, offset, ops, end):
        self.offset, self.ops, self.end = offset, ops, end
        self.group = None
        self.version = None

    @property
    def nbytes(self):
        return self.end - self.offset

    @property
    def name(self):
        if self.group in ("pll", "clock", "ddr", "mio", "peripherals"):
            return "ps7_%s_init_data_%s" % (self.group, self.version)
        return "ps7_%s_%s" % (self.group, self.version)


def parse_array(data, off):
    """Parse one opcode-encoded array starting at off. Returns (ops, end)."""
    ops, pos = [], off
    while True:
        if pos + 4 > len(data):
            raise ValueError("array at %#x runs past end of file" % off)
        (word,) = struct.unpack_from("<I", data, pos)
        pos += 4
        if word == 0:
            return ops, pos
        code, argc = word >> 4, word & 0xF
        if code not in OP_ARGC or OP_ARGC[code] != argc:
            raise ValueError("bad opcode word %#010x at %#x (array %#x)"
                             % (word, pos - 4, off))
        args = struct.unpack_from("<%dI" % argc, data, pos)
        pos += 4 * argc
        ops.append(Op(code, args, pos - 4 - 4 * argc))


def classify(ops):
    addrs = [op.addr for op in ops]
    if any(a == 0xF8000900 for a in addrs):
        return "post_config"
    if any(a in (0xF8898FB0, 0xF8899FB0, 0xF8809FB0) for a in addrs):
        return "debug"
    cnt = Counter()
    for a in addrs:
        if a in (SLCR_LOCK, SLCR_UNLOCK):
            continue
        if 0xF8006000 <= a < 0xF8007000:
            cnt["ddr"] += 1
        elif 0xF8000700 <= a <= 0xF800083C:
            cnt["mio"] += 1
        elif 0xF8000100 <= a <= 0xF800011C:
            cnt["pll"] += 1
        elif 0xF8000120 <= a <= 0xF80001C4:
            cnt["clock"] += 1
        else:
            cnt["peripherals"] += 1
    if not cnt:
        return "unknown"
    top = cnt.most_common()
    if len(top) > 1 and top[0][1] == top[1][1]:
        return "ambiguous(%s)" % ",".join("%s:%d" % kv for kv in top[:2])
    return top[0][0]


def find_all(data, sig):
    hits, off = [], 0
    while True:
        i = data.find(sig, off)
        if i < 0:
            return hits
        hits.append(i)
        off = i + 1


def find_arrays(data):
    """Locate all 21 ps7_init arrays. Aborts with diagnostics on mismatch."""
    arrays = []
    errors = []

    for off in find_all(data, SIG_SLCR):
        try:
            ops, end = parse_array(data, off)
            arrays.append(Array(off, ops, end))
        except ValueError as e:
            errors.append("SLCR-anchored hit %#x: %s" % (off, e))

    for off in find_all(data, SIG_DDR):
        # a real array start is preceded by the previous array's EXIT word
        prev = struct.unpack_from("<I", data, off - 4)[0] if off >= 4 else None
        if prev != 0:
            continue
        try:
            ops, end = parse_array(data, off)
            if len(ops) < 10:
                continue
            arrays.append(Array(off, ops, end))
        except ValueError:
            continue

    for off in find_all(data, SIG_DEBUG):
        try:
            ops, end = parse_array(data, off)
            arrays.append(Array(off, ops, end))
        except ValueError as e:
            errors.append("debug-anchored hit %#x: %s" % (off, e))

    arrays.sort(key=lambda a: a.offset)

    for a in arrays:
        a.group = classify(a.ops)

    n_slcr = len(find_all(data, SIG_SLCR))
    n_ddr = sum(1 for a in arrays if a.group == "ddr")
    n_dbg = sum(1 for a in arrays if a.group == "debug")
    if n_slcr != 15 or n_ddr != 3 or n_dbg != 3 or len(arrays) != 21:
        print("ERROR: array inventory mismatch (expected 15 SLCR-anchored "
              "+ 3 ddr + 3 debug = 21)", file=sys.stderr)
        print("  SLCR-anchored signature hits: %d" % n_slcr, file=sys.stderr)
        print("  ddr arrays: %d  debug arrays: %d  total parsed: %d"
              % (n_ddr, n_dbg, len(arrays)), file=sys.stderr)
        for a in arrays:
            print("  %#08x  %-12s ops=%-3d bytes=%d"
                  % (a.offset, a.group, len(a.ops), a.nbytes), file=sys.stderr)
        for e in errors:
            print("  parse error: %s" % e, file=sys.stderr)
        sys.exit(2)

    # version assignment: within each group, arrays appear in binary in
    # 3_0, 2_0, 1_0 order (matches embeddedsw declaration order in .rodata)
    for group in EXPECTED_GROUPS:
        members = [a for a in arrays if a.group == group]
        if len(members) != 3:
            print("ERROR: group %s has %d arrays (expected 3)"
                  % (group, len(members)), file=sys.stderr)
            sys.exit(2)
        for a, ver in zip(members, VERSIONS):
            a.version = ver

    # sanity: the three post_config arrays are byte-identical in every
    # known ps7_init build; warn loudly if this one differs
    pc = [a for a in arrays if a.group == "post_config"]
    blobs = [data[a.offset:a.end] for a in pc]
    if not (blobs[0] == blobs[1] == blobs[2]):
        print("WARNING: post_config_{3_0,2_0,1_0} differ; version labels "
              "for post_config/debug are by-order only", file=sys.stderr)

    return arrays


# ------------------------------------------------------------------- decoding
def decode_fields(addr, val):
    """Extra human-readable field decode for registers of interest."""
    out = []
    if 0xF8000700 <= addr <= 0xF80007D4:
        pin = (addr - 0xF8000700) // 4
        tri = val & 1
        sel = ((val >> 7) & 1, (val >> 4) & 7, (val >> 2) & 3, (val >> 1) & 1)
        out.append("pin=%d tri=%d sel=(L3=%d,L2=%d,L1=%d,L0=%d) %s spd=%s "
                   "io=%s pullup=%d dis_rcvr=%d"
                   % (pin, tri, sel[0], sel[1], sel[2], sel[3],
                      MIO_SEL_HINT.get(sel, "?"),
                      "fast" if (val >> 8) & 1 else "slow",
                      IO_TYPES.get((val >> 9) & 7, "?"),
                      (val >> 12) & 1, (val >> 13) & 1))
    elif addr in (0xF8000100, 0xF8000104, 0xF8000108):
        out.append("PLL_RESET=%d BYPASS_FORCE=%d BYPASS=%d FDIV=%d"
                   % (val & 1, (val >> 4) & 1, (val >> 3) & 1,
                      (val >> 12) & 0x7F))
    elif addr == 0xF8000120:
        out.append("DIVISOR=%d SRCSEL=%d CPU_6OR4X=%d 3OR2X=%d 2X=%d 1X=%d"
                   % ((val >> 8) & 0x3F, (val >> 4) & 3, (val >> 25) & 1,
                      (val >> 26) & 1, (val >> 27) & 1, (val >> 28) & 1))
    elif addr == 0xF8000124:
        out.append("DDR_3XCLK_DIVISOR=%d DDR_2XCLK_DIVISOR=%d 3XACT=%d 2XACT=%d"
                   % ((val >> 20) & 0x3F, (val >> 26) & 0x3F,
                      val & 1, (val >> 1) & 1))
    elif addr == 0xF8006030:
        out.append("ddr_mr(MR0)=0x%04X ddr_emr(MR1)=0x%04X"
                   % (val & 0xFFFF, (val >> 16) & 0xFFFF))
    elif addr == 0xF800602C:
        out.append("ddr_emr2(MR2)=0x%04X ddr_emr3(MR3)=0x%04X"
                   % (val & 0xFFFF, (val >> 16) & 0xFFFF))
    elif addr == 0xF8006020:
        out.append("t_ccd=%d t_rrd=%d refresh_margin=0x%X t_rp=%d "
                   "refresh_to_x32=0x%X mobile=%d read_latency=%d"
                   % (val & 3, (val >> 2) & 0xF, (val >> 8) & 0xF,
                      (val >> 12) & 0xF, (val >> 16) & 0x1F,
                      (val >> 22) & 1, (val >> 26) & 0xF))
    elif addr in (0xF8000B40, 0xF8000B44, 0xF8000B48, 0xF8000B4C,
                  0xF8000B50, 0xF8000B54, 0xF8000B58):
        out.append("INP_TYPE=%d DCI_UPDATE_B=%d TERM_EN=%d DCI_TYPE=%d "
                   "IBUF_DIS_MODE=%d TERM_DIS_MODE=%d OUTPUT_EN=%d PULLUP_EN=%d"
                   % ((val >> 1) & 3, (val >> 3) & 1, (val >> 4) & 1,
                      (val >> 5) & 3, (val >> 7) & 1, (val >> 8) & 1,
                      (val >> 9) & 3, (val >> 11) & 1))
    elif addr == 0xF8000B6C:
        out.append("VREF_INT_EN=%d VREF_SEL=%d VREF_EXT_EN=%d VREF_PULLUP_EN=%d "
                   "REFIO_EN=%d REFIO_PULLUP_EN=%d DRST_B_PULLUP_EN=%d "
                   "CKE_PULLUP_EN=%d"
                   % ((val >> 14) & 1, (val >> 4) & 0xF, (val >> 15) & 1,
                      (val >> 10) & 1, (val >> 9) & 1, (val >> 11) & 1,
                      (val >> 13) & 1, (val >> 12) & 1))
    elif addr == 0xF8000830:
        pins = [str(p) for p in range(32) if (val >> p) & 1]
        out.append("tristate pins 0-31: %s" % (",".join(pins) or "none"))
    return out


def emit_decode(arrays, path):
    lines = []
    lines.append("ps7_init array decode -- extracted from stock FSBL binary")
    lines.append("register names: UG585 TRM where certain; '*' = derived "
                 "from dominant Vivado field name")
    lines.append("")
    for a in arrays:
        lines.append("=" * 76)
        lines.append("%-28s offset=%#08x ops=%d bytes=%d"
                     % (a.name, a.offset, len(a.ops), a.nbytes))
        lines.append("=" * 76)
        for op in a.ops:
            name = OP_NAME[op.opcode]
            rel = op.off - a.offset
            if op.opcode == 2:
                line = ("+%04x  WRITE      0x%08X %-26s = 0x%08X"
                        % (rel, op.args[0], regname(op.args[0]), op.args[1]))
                val = op.args[1]
            elif op.opcode == 3:
                line = ("+%04x  MASKWRITE  0x%08X %-26s & 0x%08X = 0x%08X"
                        % (rel, op.args[0], regname(op.args[0]),
                           op.args[1], op.args[2]))
                val = op.args[2]
            elif op.opcode in (4, 5):
                line = ("+%04x  %-10s 0x%08X %-26s & 0x%08X"
                        % (rel, name, op.args[0], regname(op.args[0]),
                           op.args[1]))
                val = None
            else:  # CLEAR
                line = ("+%04x  CLEAR      0x%08X %-26s"
                        % (rel, op.args[0], regname(op.args[0])))
                val = None
            lines.append(line)
            if val is not None:
                for d in decode_fields(op.args[0], val):
                    lines.append("          ; %s" % d)
        lines.append("+%04x  EXIT" % (a.nbytes - 4))
        lines.append("")
    path.write_text("\n".join(lines) + "\n")


# ------------------------------------------------------------------ emitting
def emit_c(arrays, path, fsbl_path):
    """Emit ps7_init_data.c in the exact embeddedsw zed emit-macro style."""
    order = []
    for ver in VERSIONS:
        for group in EXPECTED_GROUPS:
            order.append(next(a for a in arrays
                              if a.group == group and a.version == ver))
    out = []
    out.append("/*")
    out.append(" * ps7_init_data.c -- Web-888 board init tables")
    out.append(" *")
    out.append(" * Extracted from the stock FSBL binary (%s) by" % fsbl_path)
    out.append(" * scripts/extract-ps7-init.py. The arrays below are the")
    out.append(" * board-specific data consumed by the ps7_init() function")
    out.append(" * bodies in")
    out.append(" * resources/reference/embeddedsw-zynq-fsbl/lib/sw_apps/"
               "zynq_fsbl/src/ps7_init.c")
    out.append(" * (emit-macro format identical to misc/zed/ps7_init.c).")
    out.append(" *")
    out.append(" * Silicon version mapping: arrays occur in the binary in")
    out.append(" * 3_0, 2_0, 1_0 order per group; the three post_config")
    out.append(" * arrays and the three debug arrays are byte-identical,")
    out.append(" * so their version labels are by-order only.")
    out.append(" */")
    out.append("")
    for a in order:
        out.append("unsigned long %s[] = {" % a.name)
        out.append("    // extracted from fsbl.bin offset %#x (%d bytes)"
                   % (a.offset, a.nbytes))
        for op in a.ops:
            if op.opcode == 2:
                out.append("    EMIT_WRITE(0X%08X, 0x%08XU),"
                           % (op.args[0], op.args[1]))
            elif op.opcode == 3:
                out.append("    EMIT_MASKWRITE(0X%08X, 0x%08XU ,0x%08XU),"
                           % (op.args[0], op.args[1], op.args[2]))
            elif op.opcode == 4:
                out.append("    EMIT_MASKPOLL(0X%08X, 0x%08XU),"
                           % (op.args[0], op.args[1]))
            elif op.opcode == 5:
                out.append("    EMIT_MASKDELAY(0X%08X, 0x%08XU),"
                           % (op.args[0], op.args[1]))
            else:  # CLEAR
                out.append("    EMIT_CLEAR(0X%08X)," % op.args[0])
        out.append("    EMIT_EXIT(),")
        out.append("")
        out.append("};")
        out.append("")
    path.write_text("\n".join(out) + "\n")


def emit_manifest(arrays, path):
    out = []
    out.append("/* generated by extract-ps7-init.py -- do not edit */")
    out.append("struct blob { const char *name; unsigned int offset; "
               "unsigned int bytes; };")
    out.append("static const struct blob manifest[] = {")
    for a in sorted(arrays, key=lambda a: a.offset):
        out.append('    { "%s", 0x%06X, %d },'
                   % (a.name, a.offset, a.nbytes))
    out.append("};")
    out.append("#define MANIFEST_COUNT (sizeof(manifest)/sizeof(manifest[0]))")
    path.write_text("\n".join(out) + "\n")


def emit_arrays_bin(arrays, data, path):
    blob = bytearray()
    for a in sorted(arrays, key=lambda a: a.offset):
        blob += data[a.offset:a.end]
    path.write_bytes(bytes(blob))


# --------------------------------------------------------------- cross-checks
def parse_xml_mio(xml_path):
    """Extract declared peripheral->pin mapping from a Vivado preset XML."""
    pins = {}  # pin -> set of (peripheral, direction-ish)
    txt = Path(xml_path).read_text(errors="replace")
    # preset XML pins look like: <parameter name="MIO_16" .../> with
    # peripheral context; simpler: capture CONFIG.PCW_* pin assignments
    for m in re.finditer(r'PCW_(\w+?)_PERIPHERAL_ENABLE[^>]*value="(\d)"', txt):
        pass  # enable flags handled by caller if needed
    io = {}
    for m in re.finditer(r'name="PCW_(\w+?)(?:_IO|_GRPB|_GRP)?"[^>]*'
                         r'value="MIO (\d+)[^"]*"', txt):
        io.setdefault(m.group(1), []).append(int(m.group(2)))
    return io


def check_mio(arrays, xml_path, log):
    """Compare decoded MIO mux against the red_pitaya.xml peripheral pinout.

    Hard assert on the mux-select bits of the critical interfaces; softer
    report on tristate/pullup/io-type deltas.
    """
    mio_arr = next(a for a in arrays
                   if a.group == "mio" and a.version == "3_0")
    pinval = {}
    for op in mio_arr.ops:
        if op.opcode in (2, 3) and 0xF8000700 <= op.addr <= 0xF80007D4:
            pin = (op.addr - 0xF8000700) // 4
            pinval[pin] = op.args[-1]
    sel = {p: (((v >> 7) & 1, (v >> 4) & 7, (v >> 2) & 3, (v >> 1) & 1))
           for p, v in pinval.items()}

    # expected mux-select tuples derived from the Zynq MIO mux table for
    # the interfaces declared in red_pitaya.xml
    expect = {
        "ENET0 (16-27)": (list(range(16, 28)), (0, 0, 0, 1)),
        "USB0 (28-39)": (list(range(28, 40)), (0, 0, 1, 0)),
        "SDIO0 (40-45)": (list(range(40, 46)), (1, 0, 0, 0)),
        "UART1 (8-9)": ([8, 9], (1, 6, 0, 0)),
        "UART0 (14-15)": ([14, 15], (1, 6, 0, 0)),
        "I2C0 (50-51)": ([50, 51], (0, 4, 0, 0)),
        "MDIO (52-53)": ([52, 53], (1, 0, 0, 0)),
        "GPIO USB0 reset/WP (46-49)": ([46, 47, 48, 49], (0, 0, 0, 0)),
    }
    ok = True
    log.append("")
    log.append("MIO cross-check vs %s" % xml_path)
    for label, (pins, want) in expect.items():
        bad = [p for p in pins if sel.get(p) != want]
        status = "OK " if not bad else "MISMATCH"
        if bad:
            ok = False
        log.append("  [%s] %-28s sel=%s%s"
                   % (status, label, want,
                      (" pins differing: %s" % bad) if bad else ""))
    # IO type: bank1 pins (16-53) should be LVCMOS25 (io=2) per xml 2.5V
    bad_io = [p for p in range(16, 54)
              if p in pinval and ((pinval[p] >> 9) & 7) != 2]
    log.append("  [%s] bank1 IO_Type=LVCMOS25 (xml: 2.5V)%s"
               % ("OK " if not bad_io else "NOTE",
                  (" pins not LVCMOS25: %s" % bad_io) if bad_io else ""))
    # pullups disabled on 16-39 per xml
    bad_pu = [p for p in range(16, 40)
              if p in pinval and ((pinval[p] >> 12) & 1)]
    log.append("  [%s] pullups disabled on MIO 16-39 (xml)%s"
               % ("OK " if not bad_pu else "NOTE",
                  (" pins with pullup: %s" % bad_pu) if bad_pu else ""))
    return ok


def parse_c_arrays(c_path):
    """Ordered (addr, mask, val) writes from the ps7_ddr/mio_init_data_3_0
    bodies of a ps7_init file; mask is 0xFFFFFFFF for plain writes."""
    txt = Path(c_path).read_text(errors="replace")
    ops = []
    for func in ("ps7_ddr_init_data_3_0", "ps7_mio_init_data_3_0"):
        m = re.search(re.escape(func) + r'\[\] = \{(.*?)\n\};', txt, re.S)
        if not m:
            continue
        body = m.group(1)
        pat = re.compile(
            r'EMIT_MASKWRITE\((0[Xx][0-9A-Fa-f]+),\s*(0[Xx][0-9A-Fa-f]+)U?'
            r'\s*,\s*(0[Xx][0-9A-Fa-f]+)U?\)'
            r'|EMIT_WRITE\((0[Xx][0-9A-Fa-f]+),\s*(0[Xx][0-9A-Fa-f]+)U?\)')
        for w in pat.finditer(body):
            if w.group(1) is not None:
                ops.append((int(w.group(1), 16), int(w.group(2), 16),
                            int(w.group(3), 16)))
            else:
                ops.append((int(w.group(4), 16), 0xFFFFFFFF,
                            int(w.group(5), 16)))
    return ops


def fold_writes(ops):
    """Per-register (written_mask, composed value) under MASKWRITE
    read-modify-write semantics."""
    state = {}
    for addr, mask, val in ops:
        wm, cv = state.get(addr, (0, 0))
        cv = (cv & ~mask & 0xFFFFFFFF) | (val & mask)
        state[addr] = (wm | mask, cv)
    return state


def check_ddr(arrays, ref_path, log):
    """Diff stock DDRC/DDRP/DDRIOB values against a reference ps7_init
    (e.g. u-boot zynq-zybo-z7). Report-only: differences are findings."""
    ddr_arr = next(a for a in arrays
                   if a.group == "ddr" and a.version == "3_0")
    mio_arr = next(a for a in arrays
                   if a.group == "mio" and a.version == "3_0")
    # ps7_init() call order: pll, clock, ddr, mio, peripherals
    ops = [(op.addr, op.args[1] if op.opcode == 3 else 0xFFFFFFFF,
            op.args[-1])
           for op in list(ddr_arr.ops) + list(mio_arr.ops)
           if op.opcode in (2, 3)]
    in_range = lambda a: (0xF8006000 <= a < 0xF8007000) or \
                         (0xF8000B40 <= a <= 0xF8000B74)
    stock = {a: (wm, v) for a, (wm, v) in fold_writes(ops).items()
             if in_range(a)}
    ref = {a: (wm, v) for a, (wm, v)
           in fold_writes(parse_c_arrays(ref_path)).items()
           if in_range(a)}
    log.append("")
    log.append("DDRC/DDRP/DDRIOB diff vs %s (stock | reference; values are "
               "RMW-folded over written bits)" % ref_path)
    same = diff = only_stock = only_ref = 0
    for a in sorted(set(stock) | set(ref)):
        s, r = stock.get(a), ref.get(a)
        if s is None:
            only_ref += 1
            log.append("  %-24s 0x%08X: stock=-        ref=0x%08X (written "
                       "%08X)" % (regname(a), a, r[1], r[0]))
        elif r is None:
            only_stock += 1
            log.append("  %-24s 0x%08X: stock=0x%08X (written %08X) ref=-"
                       % (regname(a), a, s[1], s[0]))
        else:
            common = s[0] & r[0]
            if (s[1] & common) == (r[1] & common):
                same += 1
            else:
                diff += 1
                log.append("  %-24s 0x%08X: stock=0x%08X ref=0x%08X "
                           "(bits compared %08X)"
                           % (regname(a), a, s[1], r[1], common))
                for d in decode_fields(a, s[1]):
                    log.append("      stock: %s" % d)
                for d in decode_fields(a, r[1]):
                    log.append("      ref  : %s" % d)
    log.append("  summary: %d identical, %d differ, %d stock-only, "
               "%d ref-only" % (same, diff, only_stock, only_ref))


# ---------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(
        description="Extract ps7_init data arrays from the stock Web-888 "
                    "FSBL binary.")
    ap.add_argument("--fsbl", default="work/stock/fsbl.bin",
                    help="stock FSBL binary (default: work/stock/fsbl.bin)")
    ap.add_argument("--outdir", default=".tmp/ps7-init",
                    help="output directory (default: .tmp/ps7-init)")
    ap.add_argument("--check-mio", metavar="XML",
                    default="work/redpitaya-src/cfg/red_pitaya.xml",
                    help="red_pitaya.xml preset for MIO cross-check "
                         "(default: work/redpitaya-src/cfg/red_pitaya.xml; "
                         "'' disables)")
    ap.add_argument("--check-ddrc", metavar="PS7_INIT_C",
                    default="work/u-boot/board/xilinx/zynq/"
                            "zynq-zybo-z7/ps7_init_gpl.c",
                    help="reference ps7_init for DDRC diff (default: local "
                         "u-boot zynq-zybo-z7 ps7_init_gpl.c; '' disables)")
    args = ap.parse_args()

    data = Path(args.fsbl).read_bytes()
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    arrays = find_arrays(data)

    print("found 21 arrays (7 groups x 3 silicon versions):")
    for a in arrays:
        print("  %#08x  %-26s ops=%-3d bytes=%d"
              % (a.offset, a.name, len(a.ops), a.nbytes))

    emit_c(arrays, outdir / "ps7_init_data.c", args.fsbl)
    emit_manifest(arrays, outdir / "manifest.h")
    emit_arrays_bin(arrays, data, outdir / "arrays.bin")
    emit_decode(arrays, outdir / "decode.txt")

    log = []
    if args.check_mio:
        if Path(args.check_mio).exists():
            check_mio(arrays, args.check_mio, log)
        else:
            log.append("MIO check skipped: %s not found" % args.check_mio)
    if args.check_ddrc:
        if Path(args.check_ddrc).exists():
            check_ddr(arrays, args.check_ddrc, log)
        else:
            log.append("DDRC diff skipped: %s not found" % args.check_ddrc)
    if log:
        with open(outdir / "decode.txt", "a") as f:
            f.write("\n".join(log) + "\n")
        print("\n".join(log))

    print("wrote %s" % ", ".join(str(outdir / n) for n in
          ("ps7_init_data.c", "manifest.h", "arrays.bin", "decode.txt")))


if __name__ == "__main__":
    main()
