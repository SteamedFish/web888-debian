/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * zynqsdr_uapi.h — public userspace ABI of /dev/zynqsdr.
 *
 * SINGLE SOURCE OF TRUTH for the stock Web-888 (RX-888) ioctl ABI:
 * the zynqsdr kernel driver (config/kernel/zynqsdr.c) and every
 * userspace consumers (scripts/hw-test tools) include THIS header; no
 * duplicate local definitions are allowed. The numeric values are
 * locked independently by scripts/hw-test/zynqsdr-abi-lock.c and
 * scripts/ci/check-zynqsdr-abi.sh (host + armhf).
 *
 * The ABI itself (magic 'Z', commands 0-12 and 20-21, packed structs,
 * fixed-width types) is the stock closed-source driver's ABI as used by
 * RaspSDR/server zynq/ioctl.h (vendored at
 * resources/reference/raspsdr-server/ioctl.h) and cross-checked against
 * the open web888-ng-hw driver header (vendored at
 * resources/reference/web888-ng-hw/driver/web888_sdr.h, tag v0.3.0).
 *
 * Works both in kernel space (built next to zynqsdr.c) and in
 * userspace (compiled into the hw-test tools).
 */
#ifndef _ZYNQSDR_UAPI_H
#define _ZYNQSDR_UAPI_H

#include <linux/types.h>
#include <linux/ioctl.h>

#define ZYNQSDR_IOC_TYPE	'Z'

/* attenuator code (PE4312; historical ioctl name "AD8370") */
#define ZYNQSDR_AD8370_SET	_IOW(ZYNQSDR_IOC_TYPE, 0, __u32)

/* 0 - HF Mode, 1 - Airband mode */
#define ZYNQSDR_MODE_SET	_IOW(ZYNQSDR_IOC_TYPE, 1, __u32)

/* 0 - EXT CLK, 1 - INT CLK */
#define ZYNQSDR_CLK_SET		_IOW(ZYNQSDR_IOC_TYPE, 2, __u32)

/* get FPGA DNA */
#define ZYNQSDR_GET_DNA		_IOR(ZYNQSDR_IOC_TYPE, 3, __u64)

/* start RX, u16 is decimate */
#define ZYNQSDR_RX_START	_IOW(ZYNQSDR_IOC_TYPE, 4, __u32)

/* set RX parameter */
struct zynqsdr_rx_param_op {
	__u32 channel;
	__u64 freq;
} __attribute__((packed));
#define ZYNQSDR_RX_PARAM	_IOW(ZYNQSDR_IOC_TYPE, 5, struct zynqsdr_rx_param_op)

/* read RX data */
struct zynqsdr_rx_read_op {
	__u32 address;	/* userspace virtual address of destination buffer */
	__u32 length;	/* requested length in bytes */
	__u32 readed;	/* driver fills: bytes actually transferred */
} __attribute__((packed));
#define ZYNQSDR_RX_READ		_IOWR(ZYNQSDR_IOC_TYPE, 6, struct zynqsdr_rx_read_op)

/* get/set GPIO mask */
#define ZYNQSDR_SET_GPIO_MASK	_IOW(ZYNQSDR_IOC_TYPE, 7, __u32)
#define ZYNQSDR_GET_GPIO_MASK	_IOR(ZYNQSDR_IOC_TYPE, 8, __u32)

/* get FPGA signature */
#define ZYNQSDR_GET_SIGNATURE	_IOR(ZYNQSDR_IOC_TYPE, 9, __u32)

/* u32 low bits are the channel, high bits are flags */
#define ZYNQSDR_WF_READ_CONTINUES	0x00010000

#define ZYNQSDR_WF_START	_IOW(ZYNQSDR_IOC_TYPE, 10, __u32)

/* set waterfall frequency and decimate */
struct zynqsdr_wf_param_op {
	__u16 channel;
	__u16 decimate;
	__u64 freq;
} __attribute__((packed));
#define ZYNQSDR_WF_PARAM	_IOW(ZYNQSDR_IOC_TYPE, 11, struct zynqsdr_wf_param_op)

/* read waterfall data, one-shot or continuous */
struct zynqsdr_wf_read_op {
	__u16 channel;
	__u32 address;	/* userspace virtual address */
	__u32 length;	/* requested length in bytes */
	__u32 readed;	/* driver fills: bytes actually transferred */
} __attribute__((packed));
#define ZYNQSDR_WF_READ		_IOWR(ZYNQSDR_IOC_TYPE, 12, struct zynqsdr_wf_read_op)

#define ZYNQSDR_PPS_START	_IOW(ZYNQSDR_IOC_TYPE, 20, __u32)
#define ZYNQSDR_PPS_READ	_IOR(ZYNQSDR_IOC_TYPE, 21, __u32)

/*
 * Intentionally absent from the public ABI:
 *  - RX_STOP ('Z', 14): a private/probe-only command used by some
 *    diagnostic tools (scripts/hw-test/rx-dump.c defines it locally);
 *    it is NOT part of the stock ABI and must not be added here.
 *  - web888-ng extension ioctls ('Z', 0x20+): not implemented by this
 *    driver; see resources/reference/web888-ng-hw/driver/web888_sdr.h.
 */

#endif /* _ZYNQSDR_UAPI_H */
