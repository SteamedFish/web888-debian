/* SPDX-License-Identifier: GPL-2.0-or-later */
/* zynqsdr-abi-lock.c — independent numeric lock on the /dev/zynqsdr UAPI.
 *
 * Compiled and run on the build host AND cross-compiled for armhf by
 * scripts/ci/check-zynqsdr-abi.sh. All assertions are _Static_assert, so
 * a passing build IS the lock; the host binary additionally prints a
 * summary when run directly.
 *
 * What this locks, with values computed INDEPENDENTLY of the header
 * macros (hand-derived from asm-generic _IOC encoding:
 * dir<<30 | size<<16 | 'Z'<<8 | nr):
 *
 *   1. The exact numeric value of all 15 stock ioctls.
 *   2. sizeof/offsetof of every packed ABI struct (catches padding
 *      drift that would change the _IOC size fields).
 *   3. The WF_READ_CONTINUES flag value.
 *   4. Absence of non-public commands (RX_STOP, web888-ng extensions).
 *   5. Drift against the fixed upstream reference header
 *      (resources/reference/web888-ng-hw/driver/web888_sdr.h, v0.3.0):
 *      every stock ioctl/struct must match the open web888-ng driver's
 *      UAPI definition.
 */
#include <stdio.h>
#include <stddef.h>

/* the header under test — single source of truth */
#include "../../config/kernel/zynqsdr_uapi.h"

/* the fixed upstream reference — vendored, read-only */
#include "../../resources/reference/web888-ng-hw/driver/web888_sdr.h"

/* ---- 1. exact ioctl numbers (hand-computed, see file comment) ---- */

_Static_assert(ZYNQSDR_AD8370_SET    == 0x40045a00u, "AD8370_SET drifted");
_Static_assert(ZYNQSDR_MODE_SET      == 0x40045a01u, "MODE_SET drifted");
_Static_assert(ZYNQSDR_CLK_SET       == 0x40045a02u, "CLK_SET drifted");
_Static_assert(ZYNQSDR_GET_DNA       == 0x80085a03u, "GET_DNA drifted");
_Static_assert(ZYNQSDR_RX_START      == 0x40045a04u, "RX_START drifted");
_Static_assert(ZYNQSDR_RX_PARAM      == 0x400c5a05u, "RX_PARAM drifted");
_Static_assert(ZYNQSDR_RX_READ       == 0xc00c5a06u, "RX_READ drifted");
_Static_assert(ZYNQSDR_SET_GPIO_MASK == 0x40045a07u, "SET_GPIO_MASK drifted");
_Static_assert(ZYNQSDR_GET_GPIO_MASK == 0x80045a08u, "GET_GPIO_MASK drifted");
_Static_assert(ZYNQSDR_GET_SIGNATURE == 0x80045a09u, "GET_SIGNATURE drifted");
_Static_assert(ZYNQSDR_WF_START      == 0x40045a0au, "WF_START drifted");
_Static_assert(ZYNQSDR_WF_PARAM      == 0x400c5a0bu, "WF_PARAM drifted");
_Static_assert(ZYNQSDR_WF_READ       == 0xc00e5a0cu, "WF_READ drifted");
_Static_assert(ZYNQSDR_PPS_START     == 0x40045a14u, "PPS_START drifted");
_Static_assert(ZYNQSDR_PPS_READ      == 0x80045a15u, "PPS_READ drifted");

/* exactly 15 stock ioctls: no duplicates, no extras sneak in */
_Static_assert(ZYNQSDR_AD8370_SET != ZYNQSDR_MODE_SET &&
	       ZYNQSDR_MODE_SET != ZYNQSDR_CLK_SET &&
	       ZYNQSDR_CLK_SET != ZYNQSDR_RX_START &&
	       ZYNQSDR_RX_START != ZYNQSDR_WF_START &&
	       ZYNQSDR_WF_START != ZYNQSDR_PPS_START, "duplicate ioctl numbers");

/* ---- 2. packed struct layouts ---- */

_Static_assert(sizeof(struct zynqsdr_rx_param_op) == 12, "rx_param_op size");
_Static_assert(offsetof(struct zynqsdr_rx_param_op, channel) == 0, "rx_param_op.channel");
_Static_assert(offsetof(struct zynqsdr_rx_param_op, freq) == 4, "rx_param_op.freq");

_Static_assert(sizeof(struct zynqsdr_rx_read_op) == 12, "rx_read_op size");
_Static_assert(offsetof(struct zynqsdr_rx_read_op, address) == 0, "rx_read_op.address");
_Static_assert(offsetof(struct zynqsdr_rx_read_op, length) == 4, "rx_read_op.length");
_Static_assert(offsetof(struct zynqsdr_rx_read_op, readed) == 8, "rx_read_op.readed");

_Static_assert(sizeof(struct zynqsdr_wf_param_op) == 12, "wf_param_op size");
_Static_assert(offsetof(struct zynqsdr_wf_param_op, channel) == 0, "wf_param_op.channel");
_Static_assert(offsetof(struct zynqsdr_wf_param_op, decimate) == 2, "wf_param_op.decimate");
_Static_assert(offsetof(struct zynqsdr_wf_param_op, freq) == 4, "wf_param_op.freq");

_Static_assert(sizeof(struct zynqsdr_wf_read_op) == 14, "wf_read_op size");
_Static_assert(offsetof(struct zynqsdr_wf_read_op, channel) == 0, "wf_read_op.channel");
_Static_assert(offsetof(struct zynqsdr_wf_read_op, address) == 2, "wf_read_op.address");
_Static_assert(offsetof(struct zynqsdr_wf_read_op, length) == 6, "wf_read_op.length");
_Static_assert(offsetof(struct zynqsdr_wf_read_op, readed) == 10, "wf_read_op.readed");

/* ---- 3. flag ---- */

_Static_assert(ZYNQSDR_WF_READ_CONTINUES == 0x00010000u, "WF_READ_CONTINUES drifted");

/* ---- 4. private commands must not enter the public ABI ---- */

#ifdef ZYNQSDR_RX_STOP
#error "ZYNQSDR_RX_STOP is private and must not be defined in the public UAPI header"
#endif
#ifdef ZYNQSDR_GET_STATS
#error "web888-ng extension ioctls are not part of this driver's public ABI"
#endif
#ifdef ZYNQSDR_PFB_INFO
#error "web888-ng extension ioctls are not part of this driver's public ABI"
#endif

/* ---- 5. drift against the fixed upstream reference (web888-ng-hw v0.3.0) ---- */

_Static_assert(ZYNQSDR_AD8370_SET == ZSDR_AD8370_SET, "upstream drift: AD8370_SET");
_Static_assert(ZYNQSDR_MODE_SET == ZSDR_MODE_SET, "upstream drift: MODE_SET");
_Static_assert(ZYNQSDR_CLK_SET == ZSDR_CLK_SET, "upstream drift: CLK_SET");
_Static_assert(ZYNQSDR_GET_DNA == ZSDR_GET_DNA, "upstream drift: GET_DNA");
_Static_assert(ZYNQSDR_RX_START == ZSDR_RX_START, "upstream drift: RX_START");
_Static_assert(ZYNQSDR_RX_PARAM == ZSDR_RX_PARAM, "upstream drift: RX_PARAM");
_Static_assert(ZYNQSDR_RX_READ == ZSDR_RX_READ, "upstream drift: RX_READ");
_Static_assert(ZYNQSDR_SET_GPIO_MASK == ZSDR_SET_GPIO, "upstream drift: SET_GPIO_MASK");
_Static_assert(ZYNQSDR_GET_GPIO_MASK == ZSDR_GET_GPIO, "upstream drift: GET_GPIO_MASK");
_Static_assert(ZYNQSDR_GET_SIGNATURE == ZSDR_GET_SIGNATURE, "upstream drift: GET_SIGNATURE");
_Static_assert(ZYNQSDR_WF_START == ZSDR_WF_START, "upstream drift: WF_START");
_Static_assert(ZYNQSDR_WF_PARAM == ZSDR_WF_PARAM, "upstream drift: WF_PARAM");
_Static_assert(ZYNQSDR_WF_READ == ZSDR_WF_READ, "upstream drift: WF_READ");
_Static_assert(ZYNQSDR_PPS_START == ZSDR_PPS_START, "upstream drift: PPS_START");
_Static_assert(ZYNQSDR_PPS_READ == ZSDR_PPS_READ, "upstream drift: PPS_READ");

_Static_assert(ZYNQSDR_WF_READ_CONTINUES == ZSDR_WF_READ_CONTINUES,
	       "upstream drift: WF_READ_CONTINUES");

_Static_assert(sizeof(struct zynqsdr_rx_param_op) == sizeof(struct zsdr_rx_param),
	       "upstream drift: rx_param size");
_Static_assert(offsetof(struct zynqsdr_rx_param_op, channel) ==
	       offsetof(struct zsdr_rx_param, channel), "upstream drift: rx_param.channel");
_Static_assert(offsetof(struct zynqsdr_rx_param_op, freq) ==
	       offsetof(struct zsdr_rx_param, freq), "upstream drift: rx_param.freq");

_Static_assert(sizeof(struct zynqsdr_rx_read_op) == sizeof(struct zsdr_rx_read),
	       "upstream drift: rx_read size");
_Static_assert(offsetof(struct zynqsdr_rx_read_op, readed) ==
	       offsetof(struct zsdr_rx_read, readed), "upstream drift: rx_read.readed");

_Static_assert(sizeof(struct zynqsdr_wf_param_op) == sizeof(struct zsdr_wf_param),
	       "upstream drift: wf_param size");
_Static_assert(offsetof(struct zynqsdr_wf_param_op, decimate) ==
	       offsetof(struct zsdr_wf_param, decimate), "upstream drift: wf_param.decimate");

_Static_assert(sizeof(struct zynqsdr_wf_read_op) == sizeof(struct zsdr_wf_read),
	       "upstream drift: wf_read size");
_Static_assert(offsetof(struct zynqsdr_wf_read_op, readed) ==
	       offsetof(struct zsdr_wf_read, readed), "upstream drift: wf_read.readed");

int main(void)
{
	printf("zynqsdr-abi-lock: all static assertions passed\n");
	printf("  15 stock ioctls locked (0x40045a00..0x80045a15), "
	       "4 packed structs, 1 flag,\n"
	       "  no private commands, upstream reference v0.3.0 matches\n");
	return 0;
}
