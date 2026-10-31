/* SPDX-License-Identifier: (GPL-2.0-or-later WITH Linux-syscall-note) OR MIT */
/*
 * web888-sdr: user-space interface of the open Web-888 SDR kernel driver.
 *
 * /dev/zynqsdr keeps the stock driver's ioctl ABI (type 'Z', numbers 0..21,
 * see web888-ng-hw docs/stock-driver.md), so existing servers work
 * unchanged. Numbers from 0x20 up are extensions of this driver.
 *
 * All structures are for 32-bit ARM; buffer addresses are 32-bit user
 * virtual addresses, as in the stock ABI.
 */
#ifndef _UAPI_WEB888_SDR_H
#define _UAPI_WEB888_SDR_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define ZSDR_IOC_TYPE 'Z'

struct zsdr_rx_param {
	__u32 channel;
	__u64 freq;		/* NCO phase increment, f / fs * 2^48 */
} __attribute__((packed));

struct zsdr_rx_read {
	__u32 address;		/* user buffer */
	__u32 length;		/* bytes */
	__u32 readed;		/* out: bytes copied */
} __attribute__((packed));

struct zsdr_wf_param {
	__u16 channel;
	__u16 decimate;		/* 1..8192 */
	__u64 freq;
} __attribute__((packed));

struct zsdr_wf_read {
	__u16 channel;
	__u32 address;
	__u32 length;
	__u32 readed;
} __attribute__((packed));

/* stock ABI: scalar arguments by value, results through a pointer */
#define ZSDR_AD8370_SET		_IOW(ZSDR_IOC_TYPE, 0, __u32)	/* code 0..63 */
#define ZSDR_MODE_SET		_IOW(ZSDR_IOC_TYPE, 1, __u32)	/* HF/VHF switch */
#define ZSDR_CLK_SET		_IOW(ZSDR_IOC_TYPE, 2, __u32)	/* ref clock select */
#define ZSDR_GET_DNA		_IOR(ZSDR_IOC_TYPE, 3, __u64)
#define ZSDR_RX_START		_IOW(ZSDR_IOC_TYPE, 4, __u32)	/* stage-2 decimation */
#define ZSDR_RX_PARAM		_IOW(ZSDR_IOC_TYPE, 5, struct zsdr_rx_param)
#define ZSDR_RX_READ		_IOWR(ZSDR_IOC_TYPE, 6, struct zsdr_rx_read)
#define ZSDR_SET_GPIO		_IOW(ZSDR_IOC_TYPE, 7, __u32)
#define ZSDR_GET_GPIO		_IOR(ZSDR_IOC_TYPE, 8, __u32)
#define ZSDR_GET_SIGNATURE	_IOR(ZSDR_IOC_TYPE, 9, __u32)
#define ZSDR_WF_START		_IOW(ZSDR_IOC_TYPE, 10, __u32)	/* channel | flags */
#define ZSDR_WF_PARAM		_IOW(ZSDR_IOC_TYPE, 11, struct zsdr_wf_param)
#define ZSDR_WF_READ		_IOWR(ZSDR_IOC_TYPE, 12, struct zsdr_wf_read)
#define ZSDR_PPS_START		_IOW(ZSDR_IOC_TYPE, 20, __u32)
#define ZSDR_PPS_READ		_IOR(ZSDR_IOC_TYPE, 21, __u32)	/* EBUSY if none */

/* ZSDR_WF_START flag: continuous ring instead of one 8192-sample block */
#define ZSDR_WF_READ_CONTINUES	(1u << 16)

/* GPIO word (ZSDR_SET_GPIO / ZSDR_GET_GPIO) */
#define ZSDR_GPIO_ANTENNA_MASK	0x3fu
#define ZSDR_GPIO_DITHER	(1u << 6)
#define ZSDR_GPIO_PGA		(1u << 7)
#define ZSDR_GPIO_LED		(1u << 8)

/* ---- extensions of this driver ---- */

/*
 * Counters and status. FPGA fields are zero with a bitstream that has no
 * extension registers (stock); driver fields are always valid.
 */
struct zsdr_stats {
	__u32 size;			/* sizeof(struct zsdr_stats) */
	__u32 signature;
	__u32 ext;			/* 1 if the FPGA fields are valid */
	__u32 build_id;
	__u32 flags;			/* STS 0x20, see register-map.md */
	__u32 adc_overflows;		/* clocks with ADC OVF high */
	__u32 adc_peak;
	__u32 rx_frames;		/* written since RX start */
	__u64 adc_samples;
	__u32 rx_frames_dropped;	/* in the FPGA FIFO */
	__u32 rx_bursts;
	__u32 wf_bursts;		/* [15:0] WF0, [31:16] WF1 */
	__u32 rx_overruns;		/* driver: ring lapped, data skipped */
	__u64 rx_overrun_bytes;
};

#define ZSDR_GET_STATS		_IOR(ZSDR_IOC_TYPE, 0x20, struct zsdr_stats)

/*
 * The channelizer bitstream (signature 0x0E5D0010, register-map.md "The
 * channelizer build"): 2048 bins of 30 kHz at 60 kS/s, up to 64 selected
 * per frame, and a full-band power line. The stock RX/WF ioctls fail with
 * EOPNOTSUPP there; these fail with ENODEV with any other bitstream.
 */
struct zsdr_pfb_info {
	__u32 size;			/* sizeof(struct zsdr_pfb_info) */
	__u32 bins;			/* 2048 */
	__u32 max_selected;		/* 64 */
	__u32 bin_hz;			/* 30000 at 122.88 MHz */
	__u32 frame_hz;			/* 60000 */
	__u32 bins_ring_bytes;
	__u32 power_ring_bytes;
};

/*
 * Bit b of mask[w] selects bin 32w + b (bin 2047 can't be). The next frame
 * after the call uses it and carries gen (1..15) in its header.
 */
struct zsdr_pfb_mask {
	__u32 gen;
	__u32 mask[64];
};

#define ZSDR_PFB_BINS		(1u << 0)
#define ZSDR_PFB_POWER		(1u << 1)

/*
 * Start the streams in `streams`, stop the others; a stream already
 * running keeps its ring position. power_frames: frames summed per power
 * line (1..65535).
 */
struct zsdr_pfb_start {
	__u32 streams;
	__u32 power_frames;
};

/*
 * Ring bytes in order since the last read (frames as in register-map.md;
 * a header starts each). Overruns aren't detected here: a reader that
 * falls a ring behind sees the frame and line numbers jump.
 */
struct zsdr_pfb_read {
	__u32 stream;			/* ZSDR_PFB_BINS or ZSDR_PFB_POWER */
	__u32 address;			/* user buffer */
	__u32 length;
	__u32 readed;			/* out: bytes copied */
};

struct zsdr_pfb_status {
	__u32 size;
	__u32 gen;			/* the gen of the frames now written */
	__u32 flags;			/* STS 0x44 */
	__u32 bins_frames;
	__u32 bins_dropped;
	__u32 power_chunks;		/* 16 a line */
	__u32 power_dropped;
};

#define ZSDR_PFB_INFO		_IOR(ZSDR_IOC_TYPE, 0x21, struct zsdr_pfb_info)
#define ZSDR_PFB_SET_MASK	_IOW(ZSDR_IOC_TYPE, 0x22, struct zsdr_pfb_mask)
#define ZSDR_PFB_START		_IOW(ZSDR_IOC_TYPE, 0x23, struct zsdr_pfb_start)
#define ZSDR_PFB_READ		_IOWR(ZSDR_IOC_TYPE, 0x24, struct zsdr_pfb_read)
#define ZSDR_PFB_STATUS		_IOR(ZSDR_IOC_TYPE, 0x25, struct zsdr_pfb_status)

/*
 * poll()/select() on /dev/zynqsdr: POLLIN when a running RX, WF, bins or
 * power stream has new data, POLLPRI when the PPS FIFO is not empty.
 */

#endif /* _UAPI_WEB888_SDR_H */
