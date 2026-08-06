// SPDX-License-Identifier: GPL-2.0
/*
 * Web-888 (RX-888) zynqsdr driver — /dev/zynqsdr control plane
 *
 * Clean-room re-implementation of the vendor's closed-source built-in
 * driver (compiled from "drivers/char/ad8370_driver.c" in the stock
 * kernel; no source published). ABI and register semantics were
 * reconstructed from:
 *
 *  - RaspSDR/server zynq/ioctl.h + zynq/peri.cpp (the exact userspace,
 *    vendored at resources/reference/raspsdr-server/)
 *  - docs/zynqsdr-driver-spec.md (reverse-engineered spec)
 *  - radare2 disassembly of the stock kernel image (.tmp/ioctl-disasm.txt,
 *    dis-zynqsdr_open/probe.txt) — see docs/research/zynqsdr-port-notes.md §9 for
 *    the corrected register offsets, which differ from the iliasam
 *    OpenZynqSDRApp register map that earlier docs were based on
 *
 * This is the data plane on top of the control plane (probe, GPIO,
 * MMIO, 15-ioctl dispatch).
 *
 * DATA-PLANE ARCHITECTURE (recovered from a complete disassembly
 * inventory of every function in the stock driver: probe 0xc0487228,
 * remove 0xc04871e8, open 0xc07a7828, release 0xc0487074, ioctl
 * 0xc048738c-0xc0488020, license-challenge 0xc0488088):
 *
 * The stock driver has NO IRQ handler, NO workqueue and NO kfifo. probe()
 * merely validates that the 4 DT interrupts resolve via
 * platform_get_irq(pdev, 0..3); nothing ever calls request_irq — the
 * "no handler on SPI 29-32" live finding is permanent, not an idle state.
 * (Earlier docs inferred lazily-requested IRQs; the binary disproves it.
 * Whether the bitstream even wires the PL-PS IRQ lines is unknown, so
 * registering handlers would be invention, not parity.)
 *
 * The real data flow is FPGA-bus-master DMA into PS DDR:
 *
 *   RX_START/WF_START: dma_alloc_coherent(0x7fc00) per stream (persists
 *     across re-arms), program the buffer bus address into the config
 *     space (RX @+0x8c, WF @+0x92+ch*6), write start bytes (-9 @+0x90 /
 *     +0x96+ch*6, 15 @+0x91 / +0x97+ch*6) on first arm, then set the
 *     engine's reset-register bit.
 *   FPGA: streams samples into the DDR ring, maintains producer counters
 *     in the status page (RX u16 @+0x04, WF u16 @+0x06+ch*2, 128-byte
 *     units).
 *   RX_READ/WF_READ: poll-copy loop in ioctl context — available =
 *     (fifo << 7) - read_offset (mod 0x7fc00), dma_sync_single_for_cpu(),
 *     copy_to_user() of up to the requested length, exit when the request
 *     is filled or the producer is caught up (partial read: readed <
 *     length, rc = 0 — userspace retries with TaskSleepMsec). No sleeping
 *     in the driver; the userspace retry loop is the pacer.
 *   release(): stop flag, drain, clear all start bytes, zero the reset
 *     register, dma_free_coherent() every allocated ring.
 *
 * Copyright (c) 2026 web888-debian project
 */

#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/gpio/consumer.h>
#include <linux/io.h>
#include <linux/ioctl.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/types.h>
#include <linux/uaccess.h>

#define ZYNQSDR_NAME		"zynqsdr"

/*
 * PL register map — hardcoded physical addresses, ioremap'd like stock
 * (the stock DT node carries no reg property, so neither does ours).
 * Region sizes are the stock driver's ioremap() sizes recovered from the
 * open() disassembly; RX/WF/PPS data regions follow the spec map.
 */
#define ZYNQSDR_CONFIG_PHYS	0x40000000
#define ZYNQSDR_CONFIG_SIZE	0xa0	/* stock ioremap size */
#define ZYNQSDR_STATUS_PHYS	0x41000000
#define ZYNQSDR_STATUS_SIZE	0x18	/* stock ioremap size */
#define ZYNQSDR_RX_PHYS		0x42000000
#define ZYNQSDR_RX_SIZE		(2 * PAGE_SIZE)	/* spec: 2 pages */
#define ZYNQSDR_WF_PHYS(ch)	(0x43000000 + (ch) * 0x01000000)
#define ZYNQSDR_WF_CHANNELS	4
#define ZYNQSDR_WF_SIZE		PAGE_SIZE
#define ZYNQSDR_PPS_PHYS	0x47000000
#define ZYNQSDR_PPS_SIZE	PAGE_SIZE

/*
 * FPGA config register offsets (0x40000000 region), recovered from the
 * stock binary — NOT from the iliasam write-c2-files.c struct, whose
 * layout belongs to a different bitstream:
 *   reset is u16 @0x00, decimate u16 @0x02, RX NCO freqs are u64 slots
 *   @0x04+ch*8, GPIO mask u32 @0x84, WF per-channel config 12-byte
 *   stride @0x6c+ch*0xc (u64 freq, u16 decimate at +8 — decimate offset
 *   to be confirmed on hardware), WF continuous-mode mask u16 @0x9e.
 */
#define ZYNQSDR_CFG_RESET	0x00	/* u16: bit0 RX, bit(ch+1) WF(ch), bit7 PPS */
#define ZYNQSDR_CFG_RX_DECIMATE	0x02	/* u16 */
#define ZYNQSDR_CFG_RX_FREQ(ch)	(0x04 + (ch) * 8)	/* u64 */
#define ZYNQSDR_CFG_GPIO_MASK	0x84	/* u32 */
#define ZYNQSDR_CFG_RX_DMA_ADDR	0x8c	/* u32: RX ring bus address */
#define ZYNQSDR_CFG_RX_START0	0x90	/* u8: -9 written on first RX arm */
#define ZYNQSDR_CFG_RX_START1	0x91	/* u8: 15 written on first RX arm */
#define ZYNQSDR_CFG_WF_DMA_ADDR(ch) (0x92 + (ch) * 6)	/* u32, 6-byte stride */
#define ZYNQSDR_CFG_WF_START0(ch) (0x96 + (ch) * 6)	/* u8: -9 */
#define ZYNQSDR_CFG_WF_START1(ch) (0x97 + (ch) * 6)	/* u8: 15 */
#define ZYNQSDR_CFG_WF_FREQ(ch)	(0x6c + (ch) * 0x0c)	/* u64 */
#define ZYNQSDR_CFG_WF_DECIM(ch) (0x6c + (ch) * 0x0c + 8)	/* u16 */
#define ZYNQSDR_CFG_WF_CONT	0x9e	/* u16, bit per WF channel */

/*
 * Start-byte values recovered from the stock RX_START/WF_START handlers:
 * 0xf7 (-9) and 0x0f (15) are written to the config space when an engine
 * is armed for the first time and cleared to 0 by release().
 */
#define ZYNQSDR_START_BYTE0	0xf7	/* (-9) */
#define ZYNQSDR_START_BYTE1	0x0f	/* (15) */

/*
 * Coherent ring size recovered from the stock dma_alloc_coherent() calls
 * (identical for RX and each WF channel; gfp = 0xcc0 in the binary).
 */
#define ZYNQSDR_DMA_SIZE	0x7fc00

#define ZYNQSDR_RESET_RX	BIT(0)
#define ZYNQSDR_RESET_WF(ch)	BIT((ch) + 1)
#define ZYNQSDR_RESET_PPS	BIT(7)

/*
 * FPGA status register offsets (0x41000000 region), from the stock binary:
 * signature u32 @0x00, RX fifo fill u16 @0x04 (units of 128 bytes), PPS
 * fifo count u16 @0x0a, device DNA u64 @0x0c. (The iliasam-derived spec
 * struct puts the DNA at 0x1c — wrong for the Web-888 bitstream.)
 */
#define ZYNQSDR_STS_SIGNATURE	0x00	/* u32: rx_ch = &0xff, wf_ch = (>>8)&0xff */
#define ZYNQSDR_STS_RX_FIFO	0x04	/* u16, 128-byte units */
#define ZYNQSDR_STS_WF_FIFO(ch)	(0x06 + (ch) * 2)	/* u16, 128-byte units */
#define ZYNQSDR_STS_PPS_FIFO	0x0a	/* u16 */
#define ZYNQSDR_STS_DNA		0x0c	/* u64 */

/* DT "gpios" array indices — the ABI of the DT node (order fixed) */
#define ZYNQSDR_GPIO_MODE	0	/* MIO 10: 0 = HF, 1 = airband/VHF */
#define ZYNQSDR_GPIO_DSA_CLK	1	/* MIO 13: attenuator serial clock */
#define ZYNQSDR_GPIO_DSA_LE	2	/* MIO 12: attenuator latch enable */
#define ZYNQSDR_GPIO_DSA_DATA	3	/* MIO 11: attenuator serial data */
#define ZYNQSDR_GPIO_CLK_SEL	4	/* EMIO 49: 0 = ext clk, 1 = int clk */
#define ZYNQSDR_NUM_GPIOS	5

/* ------------------------------------------------------------------ */
/* Userspace ABI — verbatim from RaspSDR/server zynq/ioctl.h (the ABI  */
/* authority; struct/field names must match what websdr compiles       */
/* against). Magic 'Z', commands 0-12 and 20-21, plus one flag.        */
/* ------------------------------------------------------------------ */

#define ZYNQSDR_AD8370_SET	_IOW('Z', 0, __u32)

/* 0 - HF Mode, 1 - Airband mode */
#define ZYNQSDR_MODE_SET	_IOW('Z', 1, __u32)

/* 0 - EXT CLK, 1 - INT CLK */
#define ZYNQSDR_CLK_SET		_IOW('Z', 2, __u32)

/* get FPGA DNA */
#define ZYNQSDR_GET_DNA		_IOR('Z', 3, __u64)

/* start RX, u16 is decimate */
#define ZYNQSDR_RX_START	_IOW('Z', 4, __u32)

/* set RX parameter */
struct zynqsdr_rx_param_op {
	__u32 channel;
	__u64 freq;
} __packed;
#define ZYNQSDR_RX_PARAM	_IOW('Z', 5, struct zynqsdr_rx_param_op)

/* read RX data */
struct zynqsdr_rx_read_op {
	__u32 address;	/* userspace virtual address of destination buffer */
	__u32 length;	/* requested length in bytes */
	__u32 readed;	/* driver fills: bytes actually transferred */
} __packed;
#define ZYNQSDR_RX_READ		_IOWR('Z', 6, struct zynqsdr_rx_read_op)

/* get/set GPIO mask */
#define ZYNQSDR_SET_GPIO_MASK	_IOW('Z', 7, __u32)
#define ZYNQSDR_GET_GPIO_MASK	_IOR('Z', 8, __u32)

/* get FPGA signature */
#define ZYNQSDR_GET_SIGNATURE	_IOR('Z', 9, __u32)

/* u32 low bits are the channel, high bits are flags */
#define ZYNQSDR_WF_READ_CONTINUES	0x00010000

#define ZYNQSDR_WF_START	_IOW('Z', 10, __u32)

/* set waterfall frequency and decimate */
struct zynqsdr_wf_param_op {
	__u16 channel;
	__u16 decimate;
	__u64 freq;
} __packed;
#define ZYNQSDR_WF_PARAM	_IOW('Z', 11, struct zynqsdr_wf_param_op)

/* read waterfall data, one-shot or continuous */
struct zynqsdr_wf_read_op {
	__u16 channel;
	__u32 address;	/* userspace virtual address */
	__u32 length;	/* requested length in bytes */
	__u32 readed;	/* driver fills: bytes actually transferred */
} __packed;
#define ZYNQSDR_WF_READ		_IOWR('Z', 12, struct zynqsdr_wf_read_op)

#define ZYNQSDR_PPS_START	_IOW('Z', 20, __u32)
#define ZYNQSDR_PPS_READ	_IOR('Z', 21, __u32)

/**
 * struct zynqsdr_dev - per-device state (one instance)
 * @dev:	platform device
 * @misc:	misc device for /dev/zynqsdr
 * @config:	ioremap of the FPGA config region (0x40000000)
 * @status:	ioremap of the FPGA status region (0x41000000)
 * @rx:		ioremap of the RX data region (0x42000000); stock also
 *		serves the PPS sample from offset 0 of this mapping
 * @wf:		ioremaps of the 4 waterfall data regions (0x43-0x46000000)
 * @pps:	ioremap of the PPS data region (0x47000000)
 * @gpios:	the 5 control GPIOs in DT order (mode, DSA clk/le/data, clksel)
 * @open_count:	single-opener guard (stock: one open at a time, -EBUSY)
 */
struct zynqsdr_dev {
	struct device *dev;
	struct miscdevice misc;
	void __iomem *config;
	void __iomem *status;
	void __iomem *rx;
	void __iomem *wf[ZYNQSDR_WF_CHANNELS];
	void __iomem *pps;
	struct gpio_desc *gpios[ZYNQSDR_NUM_GPIOS];
	atomic_t open_count;
};

/**
 * struct zynqsdr_stream - one FPGA-to-DDR DMA ring (RX or one WF channel)
 * @cpu:	coherent buffer CPU address (NULL until first arm)
 * @dma:	coherent buffer bus address (programmed into config space)
 * @offset:	driver read position in the ring, modulo ZYNQSDR_DMA_SIZE
 * @armed:	engine start sequence completed at least once
 *
 * Mirrors the stock per-open priv layout (RX handle/cpu/offset at
 * priv+0x10/0x14/0x18, WF at priv+0x30+ch*0x28 +0/0x34/0x38). The buffer
 * is allocated on first arm and kept until release, exactly like stock.
 */
struct zynqsdr_stream {
	void *cpu;
	dma_addr_t dma;
	__u32 offset;
	bool armed;
};

/**
 * struct zynqsdr_file - per-open private data
 * @zdev:	back-pointer to the device
 * @lock:	serializes ioctls on this fd (stock: mutex at priv+0x78)
 * @busy:	in-flight ioctl counter (stock: priv+0x74)
 * @stop:	set by release; forces -EINTR out of any ioctl
 *		(stock: priv+0x70, breaks userspace read loops)
 * @rx:	RX DMA ring state
 * @rx_decimate:	last RX decimation factor
 * @wf:	per-channel WF DMA ring state
 * @wf_continuous:	per-channel WF_READ_CONTINUES flag state
 * @wf_decimate:	per-channel last WF decimation factor (0 = unset)
 * @wf_freq:	per-channel last WF NCO frequency word
 */
struct zynqsdr_file {
	struct zynqsdr_dev *zdev;
	struct mutex lock;
	atomic_t busy;
	bool stop;
	struct zynqsdr_stream rx;
	__u16 rx_decimate;
	struct zynqsdr_stream wf[ZYNQSDR_WF_CHANNELS];
	bool wf_continuous[ZYNQSDR_WF_CHANNELS];
	__u16 wf_decimate[ZYNQSDR_WF_CHANNELS];
	__u64 wf_freq[ZYNQSDR_WF_CHANNELS];
};

static inline u32 zynqsdr_signature(struct zynqsdr_dev *zdev)
{
	return ioread32(zdev->status + ZYNQSDR_STS_SIGNATURE);
}

/* channel-count semantics follow the stock binary: full bytes, not nibbles */
static inline u32 zynqsdr_rx_channels(struct zynqsdr_dev *zdev)
{
	return zynqsdr_signature(zdev) & 0xff;
}

static inline u32 zynqsdr_wf_channels(struct zynqsdr_dev *zdev)
{
	return (zynqsdr_signature(zdev) >> 8) & 0xff;
}

/**
 * zynqsdr_dsa_write() - bit-bang the PE4312 6-bit DSA over 3-wire serial
 * @zdev:	device
 * @code:	attenuation code (stock accepts 0-255, shifts all 8 bits;
 *		the PE4312 semantics are 0-63 = 0-31.5 dB in 0.5 dB steps)
 *
 * Protocol recovered from the stock binary (AD8370_SET handler): LE low,
 * CLK low, then 8 bits MSB-first (data setup, CLK high, CLK low — no
 * delays; the Zynq GPIO write latency exceeds the chip's setup/hold
 * times), then LE high to latch. The "AD8370" ioctl name is a historical
 * misnomer; the on-board part behaves as a PE4312 (docs/ad8370-driver-analysis.md).
 */
static void zynqsdr_dsa_write(struct zynqsdr_dev *zdev, __u32 code)
{
	int i;

	gpiod_set_value(zdev->gpios[ZYNQSDR_GPIO_DSA_LE], 0);
	gpiod_set_value(zdev->gpios[ZYNQSDR_GPIO_DSA_CLK], 0);

	for (i = 0; i < 8; i++) {
		gpiod_set_value(zdev->gpios[ZYNQSDR_GPIO_DSA_DATA],
				(code >> 7) & 1);
		gpiod_set_value(zdev->gpios[ZYNQSDR_GPIO_DSA_CLK], 1);
		code = (code << 1) & 0xff;
		gpiod_set_value(zdev->gpios[ZYNQSDR_GPIO_DSA_CLK], 0);
	}

	gpiod_set_value(zdev->gpios[ZYNQSDR_GPIO_DSA_LE], 1);
}

/**
 * zynqsdr_stream_arm() - allocate the coherent ring on first arm (stock:
 * buffer persists across re-arms; start bytes only written on first arm)
 * @zdev:	device
 * @st:		stream to arm
 *
 * Returns 0 or -ENOMEM (stock: mvn r7, 0xb on dma_alloc_coherent failure).
 */
static int zynqsdr_stream_arm(struct zynqsdr_dev *zdev,
			      struct zynqsdr_stream *st)
{
	if (st->cpu)
		return 0;

	st->cpu = dma_alloc_coherent(zdev->dev, ZYNQSDR_DMA_SIZE, &st->dma,
				     GFP_KERNEL);
	if (!st->cpu)
		return -ENOMEM;
	st->offset = 0;
	return 0;
}

/**
 * zynqsdr_stream_free() - release the coherent ring (stock release() order)
 * @zdev:	device
 * @st:		stream to free
 */
static void zynqsdr_stream_free(struct zynqsdr_dev *zdev,
				struct zynqsdr_stream *st)
{
	if (!st->cpu)
		return;
	dma_free_coherent(zdev->dev, ZYNQSDR_DMA_SIZE, st->cpu, st->dma);
	st->cpu = NULL;
	st->armed = false;
	st->offset = 0;
}

/**
 * zynqsdr_stream_read() - stock poll-copy loop for one stream
 * @zfile:	open file state (stop flag polled per iteration)
 * @st:		stream to drain
 * @fifo_reg:	status-page producer counter (u16, 128-byte units)
 * @user:	userspace destination (already access_ok'd)
 * @length:	requested bytes
 * @readed:	out: bytes actually copied
 *
 * The FPGA bus-masters samples into the coherent ring and advances the
 * producer counter; this loop copies whatever is available up to @length
 * and stops when the producer is caught up — that is the partial-read
 * contract (rc = 0, readed < length; userspace retries with
 * TaskSleepMsec). The producer counter and the read offset both live
 * modulo ZYNQSDR_DMA_SIZE; a counter below the offset means the producer
 * wrapped, so the chunk runs to the ring end first.
 *
 * The stock loop additionally consults a license-check byte and an
 * IRQ-deadline timestamp before copying. Neither is replicated: the
 * license check is deliberately out of scope and the
 * deadline only gated the unlicensed path (no IRQ handler exists in the
 * stock binary to refresh it).
 *
 * Returns 0 on success (partial fills included) or -EFAULT on a bad
 * userspace pointer (stock: printk + -EFAULT, readed not written back).
 */
static long zynqsdr_stream_read(struct zynqsdr_file *zfile,
				struct zynqsdr_stream *st,
				u16 __iomem *fifo_reg,
				void __user *user, __u32 length, __u32 *readed)
{
	struct zynqsdr_dev *zdev = zfile->zdev;
	__u32 remaining = length, done = 0;

	while (remaining) {
		__u32 fifo_bytes, chunk;

		if (READ_ONCE(zfile->stop))
			break;

		fifo_bytes = (__u32)ioread16(fifo_reg) << 7;
		if (fifo_bytes == st->offset)
			break;	/* producer caught up: partial read */

		if (fifo_bytes > st->offset)
			chunk = fifo_bytes - st->offset;
		else
			chunk = ZYNQSDR_DMA_SIZE - st->offset;
		chunk = min(chunk, remaining);

		dma_sync_single_for_cpu(zdev->dev, st->dma + st->offset,
					chunk, DMA_FROM_DEVICE);
		if (copy_to_user(user + done, st->cpu + st->offset, chunk)) {
			dev_warn(zdev->dev, "read: copy_to_user failed\n");
			return -EFAULT;
		}

		st->offset = (st->offset + chunk) % ZYNQSDR_DMA_SIZE;
		done += chunk;
		remaining -= chunk;
	}

	*readed = done;
	return 0;
}

/**
 * zynqsdr_do_ioctl() - ioctl dispatch (caller holds the per-file mutex)
 * @zfile:	open file state
 * @cmd:	ioctl command
 * @arg:	userspace argument (value for _IOW, pointer for _IOR/_IOWR)
 *
 * Error semantics mirror the stock driver: -EINVAL for out-of-range
 * values/channels, -EFAULT for bad userspace addresses, -ENOTTY for
 * unknown commands, -EBUSY from PPS_READ when no PPS sample is ready.
 */
static long zynqsdr_do_ioctl(struct zynqsdr_file *zfile,
			     unsigned int cmd, unsigned long arg)
{
	struct zynqsdr_dev *zdev = zfile->zdev;
	void __user *argp = (void __user *)arg;
	__u32 val32;
	__u64 val64;
	__u16 val16;

	switch (cmd) {
	case ZYNQSDR_AD8370_SET:
		if (arg > 0xff)
			return -EINVAL;
		zynqsdr_dsa_write(zdev, arg);
		return 0;

	case ZYNQSDR_MODE_SET:
		gpiod_set_value(zdev->gpios[ZYNQSDR_GPIO_MODE], !!arg);
		return 0;

	case ZYNQSDR_CLK_SET:
		gpiod_set_value(zdev->gpios[ZYNQSDR_GPIO_CLK_SEL], !!arg);
		return 0;

	case ZYNQSDR_GET_DNA:
		/* Web-888 layout per stock binary: u64 at status+0x0c */
		memcpy_fromio(&val64, zdev->status + ZYNQSDR_STS_DNA, 8);
		if (copy_to_user(argp, &val64, sizeof(val64)))
			return -EFAULT;
		return 0;

	case ZYNQSDR_RX_START: {
		bool first_arm = !zfile->rx.cpu;
		int ret;

		/* stock: decimate must be in [5, 40] */
		if (arg < 5 || arg > 40)
			return -EINVAL;
		/*
		 * Stock arm sequence (disasm 0xc0487a30): clear reset bit 0,
		 * program decimate, allocate the 0x7fc00 coherent ring on
		 * first arm and hand its bus address to the FPGA @config+0x8c
		 * plus start bytes -9/15 @+0x90/0x91, then set reset bit 0
		 * (bit set = engine running) and program decimate again.
		 */
		iowrite16(ioread16(zdev->config + ZYNQSDR_CFG_RESET) &
			  ~ZYNQSDR_RESET_RX,
			  zdev->config + ZYNQSDR_CFG_RESET);
		iowrite16((__u16)arg, zdev->config + ZYNQSDR_CFG_RX_DECIMATE);
		ret = zynqsdr_stream_arm(zdev, &zfile->rx);
		if (ret)
			return ret;
		if (first_arm) {
			iowrite32((__u32)zfile->rx.dma,
				  zdev->config + ZYNQSDR_CFG_RX_DMA_ADDR);
			iowrite8(ZYNQSDR_START_BYTE0,
				 zdev->config + ZYNQSDR_CFG_RX_START0);
			iowrite8(ZYNQSDR_START_BYTE1,
				 zdev->config + ZYNQSDR_CFG_RX_START1);
		}
		iowrite16(ioread16(zdev->config + ZYNQSDR_CFG_RESET) |
			  ZYNQSDR_RESET_RX,
			  zdev->config + ZYNQSDR_CFG_RESET);
		iowrite16((__u16)arg, zdev->config + ZYNQSDR_CFG_RX_DECIMATE);
		zfile->rx_decimate = (__u16)arg;
		zfile->rx.armed = true;
		return 0;
	}

	case ZYNQSDR_RX_PARAM: {
		struct zynqsdr_rx_param_op op;

		if (copy_from_user(&op, argp, sizeof(op)))
			return -EFAULT;
		if (op.channel >= zynqsdr_rx_channels(zdev))
			return -EINVAL;
		iowrite32((__u32)op.freq,
			  zdev->config + ZYNQSDR_CFG_RX_FREQ(op.channel));
		iowrite32((__u32)(op.freq >> 32),
			  zdev->config + ZYNQSDR_CFG_RX_FREQ(op.channel) + 4);
		return 0;
	}

	case ZYNQSDR_RX_READ: {
		struct zynqsdr_rx_read_op op;
		__u32 readed = 0;
		long ret = 0;

		if (copy_from_user(&op, argp, sizeof(op)))
			return -EFAULT;
		if (!access_ok((void __user *)(unsigned long)op.address,
			       op.length))
			return -EFAULT;
		/*
		 * Stock gates the copy loop on the reset register's run bit
		 * read back from the FPGA (-EIO + printk when clear). With a
		 * dead/unprogrammed PL the register always reads 0, so the
		 * check would fire spuriously — we gate on the cached armed
		 * state instead, which is equivalent on real hardware. Never
		 * armed (no ring): rc = 0, readed = 0 (stock returns 0
		 * without even writing readed back; writing 0 is harmless
		 * and matches userspace's zero-initialised struct).
		 */
		if (zfile->rx.armed)
			ret = zynqsdr_stream_read(zfile, &zfile->rx,
						  zdev->status +
						  ZYNQSDR_STS_RX_FIFO,
						  (void __user *)(unsigned long)
						  op.address,
						  op.length, &readed);
		if (ret)
			return ret;
		if (copy_to_user(argp + offsetof(struct zynqsdr_rx_read_op,
						 readed),
				 &readed, sizeof(readed)))
			return -EFAULT;
		return 0;
	}

	case ZYNQSDR_SET_GPIO_MASK:
		iowrite32((__u32)arg, zdev->config + ZYNQSDR_CFG_GPIO_MASK);
		return 0;

	case ZYNQSDR_GET_GPIO_MASK:
		val32 = ioread32(zdev->config + ZYNQSDR_CFG_GPIO_MASK);
		if (copy_to_user(argp, &val32, sizeof(val32)))
			return -EFAULT;
		return 0;

	case ZYNQSDR_GET_SIGNATURE:
		val32 = zynqsdr_signature(zdev);
		if (copy_to_user(argp, &val32, sizeof(val32)))
			return -EFAULT;
		return 0;

	case ZYNQSDR_WF_START: {
		__u32 chan = arg & 0xff;
		struct zynqsdr_stream *st;
		__u16 val16;
		int ret;

		if (chan >= zynqsdr_wf_channels(zdev))
			return -EINVAL;
		st = &zfile->wf[chan];
		/*
		 * Stock arm sequence (disasm 0xc0487964): clear the channel
		 * reset bit, allocate the per-channel 0x7fc00 coherent ring
		 * on first arm, program the bus address u32 @config+0x92+ch*6
		 * and start bytes -9/15 @+0x96/+0x97+ch*6, update the
		 * continuous-mode mask u16 @config+0x9e, set the reset bit.
		 *
		 * Stock quirk (verified in the binary): the handler tests
		 * the WF_READ_CONTINUES flag from a stack slot it never
		 * stored the argument into, so it always takes the
		 * flag-set path and the mask bit is set unconditionally.
		 * We honour the flag from the argument, matching the
		 * documented ABI intent; validate against real hardware in
		 * the hardware gate (docs/research/zynqsdr-port-notes.md §4.4).
		 */
		zfile->wf_continuous[chan] = !!(arg & ZYNQSDR_WF_READ_CONTINUES);
		iowrite16(ioread16(zdev->config + ZYNQSDR_CFG_RESET) &
			  ~ZYNQSDR_RESET_WF(chan),
			  zdev->config + ZYNQSDR_CFG_RESET);
		ret = zynqsdr_stream_arm(zdev, st);
		if (ret)
			return ret;
		if (zfile->wf_continuous[chan])
			val16 = ioread16(zdev->config + ZYNQSDR_CFG_WF_CONT) |
				(__u16)BIT(chan);
		else
			val16 = ioread16(zdev->config + ZYNQSDR_CFG_WF_CONT) &
				~(__u16)BIT(chan);
		iowrite16(val16, zdev->config + ZYNQSDR_CFG_WF_CONT);
		if (!st->armed) {
			iowrite32((__u32)st->dma,
				  zdev->config + ZYNQSDR_CFG_WF_DMA_ADDR(chan));
			iowrite8(ZYNQSDR_START_BYTE0,
				 zdev->config + ZYNQSDR_CFG_WF_START0(chan));
			iowrite8(ZYNQSDR_START_BYTE1,
				 zdev->config + ZYNQSDR_CFG_WF_START1(chan));
		}
		iowrite16(ioread16(zdev->config + ZYNQSDR_CFG_RESET) |
			  ZYNQSDR_RESET_WF(chan),
			  zdev->config + ZYNQSDR_CFG_RESET);
		st->armed = true;
		return 0;
	}

	case ZYNQSDR_WF_PARAM: {
		struct zynqsdr_wf_param_op op;
		struct zynqsdr_stream *st;
		bool decim_chg;

		if (copy_from_user(&op, argp, sizeof(op)))
			return -EFAULT;
		if (op.channel >= zynqsdr_wf_channels(zdev))
			return -EINVAL;
		/*
		 * Stock writes only on change, caching both values
		 * (disasm 0xc048786c/0xc0487edc): decimate equal + freq
		 * equal = no-op; either different = rewrite both and
		 * update the caches. Stock issues NO reset pulse — but
		 * on the Web-888 bitstream the WF engine latches decimate
		 * at (re)start and provably ignores later register writes
		 * (BUG 3, verified live: rate stuck at the
		 * first-arm decimate regardless of the register), so on
		 * a decimate change we additionally pulse the channel
		 * reset bit PPS_START-style (stop, 215 µs, start) to
		 * force the running engine to re-latch. The producer
		 * restarts from the ring head after the pulse, so the
		 * consumer offset is resynced to 0.
		 */
		if (zfile->wf_decimate[op.channel] == op.decimate &&
		    zfile->wf_freq[op.channel] == op.freq)
			return 0;
		decim_chg = zfile->wf_decimate[op.channel] != op.decimate;
		zfile->wf_decimate[op.channel] = op.decimate;
		zfile->wf_freq[op.channel] = op.freq;
		iowrite32((__u32)op.freq,
			  zdev->config + ZYNQSDR_CFG_WF_FREQ(op.channel));
		iowrite32((__u32)(op.freq >> 32),
			  zdev->config + ZYNQSDR_CFG_WF_FREQ(op.channel) + 4);
		iowrite16(op.decimate,
			  zdev->config + ZYNQSDR_CFG_WF_DECIM(op.channel));
		st = &zfile->wf[op.channel];
		if (decim_chg && st->armed) {
			val16 = ioread16(zdev->config + ZYNQSDR_CFG_RESET);
			iowrite16(val16 & ~ZYNQSDR_RESET_WF(op.channel),
				  zdev->config + ZYNQSDR_CFG_RESET);
			udelay(215);
			iowrite16(val16 | ZYNQSDR_RESET_WF(op.channel),
				  zdev->config + ZYNQSDR_CFG_RESET);
			st->offset = 0;
		}
		return 0;
	}

	case ZYNQSDR_WF_READ: {
		struct zynqsdr_wf_read_op op;
		struct zynqsdr_stream *st;
		__u32 readed = 0;
		long ret = 0;

		if (copy_from_user(&op, argp, sizeof(op)))
			return -EFAULT;
		if ((op.channel & 0xff) >= zynqsdr_wf_channels(zdev))
			return -EINVAL;
		if (!access_ok((void __user *)(unsigned long)op.address,
			       op.length))
			return -EFAULT;
		/*
		 * Same cached-armed gating as RX_READ (stock reads the
		 * channel's reset bit back, which is dead-register 0 with
		 * no PL). WF_READ_CONTINUES flows through WF_START's
		 * argument; userspace passes a plain channel number here.
		 * Never armed: rc = 0, readed = 0 (see RX_READ).
		 */
		st = &zfile->wf[op.channel & 0xff];
		if (st->armed)
			ret = zynqsdr_stream_read(zfile, st,
						  zdev->status +
						  ZYNQSDR_STS_WF_FIFO(
							  op.channel & 0xff),
						  (void __user *)(unsigned long)
						  op.address,
						  op.length, &readed);
		if (ret)
			return ret;
		if (copy_to_user(argp + offsetof(struct zynqsdr_wf_read_op,
						 readed),
				 &readed, sizeof(readed)))
			return -EFAULT;
		return 0;
	}

	case ZYNQSDR_PPS_START:
		/*
		 * Stock: pulse the PPS reset bit (clear, delay, set when
		 * arg != 0). The exact stock delay constant could not be
		 * resolved (indirect call through arm_delay_ops); 215 µs
		 * matches the constant's magnitude. Verified on hardware.
		 */
		val16 = ioread16(zdev->config + ZYNQSDR_CFG_RESET);
		iowrite16(val16 & ~ZYNQSDR_RESET_PPS,
			  zdev->config + ZYNQSDR_CFG_RESET);
		udelay(215);
		if (arg)
			iowrite16(val16 | ZYNQSDR_RESET_PPS,
				  zdev->config + ZYNQSDR_CFG_RESET);
		return 0;

	case ZYNQSDR_PPS_READ:
		/*
		 * Stock: PPS fifo count is u16 at status+0x0a; zero means
		 * no GPS fix / no sample → -EBUSY (normal for userspace).
		 * The sample itself is served from offset 0 of the RX
		 * data mapping (stock reads priv+0x00 + 0).
		 */
		val16 = ioread16(zdev->status + ZYNQSDR_STS_PPS_FIFO);
		if (!val16)
			return -EBUSY;
		val32 = ioread32(zdev->rx);
		if (copy_to_user(argp, &val32, sizeof(val32)))
			return -EFAULT;
		return 0;

	default:
		return -ENOTTY;
	}
}

static long zynqsdr_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct zynqsdr_file *zfile = file->private_data;
	long rc;

	/* stock: the release stop flag short-circuits ioctls with -EINTR */
	if (READ_ONCE(zfile->stop))
		return -EINTR;

	atomic_inc(&zfile->busy);
	mutex_lock(&zfile->lock);
	rc = zynqsdr_do_ioctl(zfile, cmd, arg);
	mutex_unlock(&zfile->lock);
	atomic_dec(&zfile->busy);

	if (READ_ONCE(zfile->stop))
		rc = -EINTR;
	return rc;
}

static int zynqsdr_open(struct inode *inode, struct file *file)
{
	struct miscdevice *misc = file->private_data;
	struct zynqsdr_dev *zdev =
		container_of(misc, struct zynqsdr_dev, misc);
	struct zynqsdr_file *zfile;

	/* stock: single opener; contention after retries → -EBUSY */
	if (atomic_inc_return(&zdev->open_count) != 1) {
		atomic_dec(&zdev->open_count);
		return -EBUSY;
	}

	zfile = kzalloc(sizeof(*zfile), GFP_KERNEL);
	if (!zfile) {
		atomic_dec(&zdev->open_count);
		return -ENOMEM;
	}

	zfile->zdev = zdev;
	mutex_init(&zfile->lock);
	atomic_set(&zfile->busy, 0);
	file->private_data = zfile;

	/* stock open() clears the reset register (stop all engines) */
	iowrite16(0, zdev->config + ZYNQSDR_CFG_RESET);

	/* keep the stock log line verbatim (sic) for log-diff fidelity */
	pr_info("zynqsdr: device is openning (%d)\n", current->pid);
	return 0;
}

static int zynqsdr_release(struct inode *inode, struct file *file)
{
	struct zynqsdr_file *zfile = file->private_data;
	struct zynqsdr_dev *zdev = zfile->zdev;
	int i;

	/* break any in-flight/looping ioctl, then drain it */
	WRITE_ONCE(zfile->stop, true);
	mutex_lock(&zfile->lock);

	/*
	 * Stock release teardown (disasm 0xc0487074): clear the RX and WF
	 * start bytes, wait, zero the reset register, wait, then free the
	 * coherent rings. (Stock clears the start bytes of WF channels 0
	 * and 1 only — the two the stock bitstream exposes; clearing all
	 * four here is harmless: the bytes are plain config storage.)
	 */
	if (zfile->rx.armed) {
		iowrite8(0, zdev->config + ZYNQSDR_CFG_RX_START0);
		iowrite8(0, zdev->config + ZYNQSDR_CFG_RX_START1);
	}
	for (i = 0; i < ZYNQSDR_WF_CHANNELS; i++) {
		if (!zfile->wf[i].armed)
			continue;
		iowrite8(0, zdev->config + ZYNQSDR_CFG_WF_START0(i));
		iowrite8(0, zdev->config + ZYNQSDR_CFG_WF_START1(i));
	}
	if (zfile->rx.armed) {
		msleep(100);
		iowrite16(0, zdev->config + ZYNQSDR_CFG_RESET);
		msleep(100);
	}

	zynqsdr_stream_free(zdev, &zfile->rx);
	for (i = 0; i < ZYNQSDR_WF_CHANNELS; i++)
		zynqsdr_stream_free(zdev, &zfile->wf[i]);

	mutex_unlock(&zfile->lock);

	atomic_dec(&zdev->open_count);
	kfree(zfile);
	return 0;
}

static const struct file_operations zynqsdr_fops = {
	.owner		= THIS_MODULE,
	.open		= zynqsdr_open,
	.release	= zynqsdr_release,
	.unlocked_ioctl	= zynqsdr_ioctl,
	/* No .llseek: since 6.12 (no_llseek removal) a NULL llseek clears
	 * FMODE_LSEEK in do_dentry_open, so lseek fails with -ESPIPE —
	 * identical semantics to the old .llseek = no_llseek. */
};

static int zynqsdr_probe(struct platform_device *pdev)
{
	struct zynqsdr_dev *zdev;
	int i, ret;

	zdev = devm_kzalloc(&pdev->dev, sizeof(*zdev), GFP_KERNEL);
	if (!zdev)
		return -ENOMEM;

	zdev->dev = &pdev->dev;
	atomic_set(&zdev->open_count, 0);

	/*
	 * The 5 control GPIOs in DT order (mode, DSA clk/le/data, clk
	 * select). The gpiod API honours the DT active-low flags, so all
	 * gpiod_set_value() calls in this driver use logical levels.
	 */
	for (i = 0; i < ZYNQSDR_NUM_GPIOS; i++) {
		zdev->gpios[i] = devm_gpiod_get_index(&pdev->dev, NULL, i,
						      GPIOD_OUT_LOW);
		if (IS_ERR(zdev->gpios[i]))
			return dev_err_probe(&pdev->dev,
					     PTR_ERR(zdev->gpios[i]),
					     "request gpio index %d\n", i);
	}

	zdev->config = devm_ioremap(&pdev->dev, ZYNQSDR_CONFIG_PHYS,
				    ZYNQSDR_CONFIG_SIZE);
	if (!zdev->config)
		return dev_err_probe(&pdev->dev, -ENOMEM,
				     "ioremap config 0x%08x\n", ZYNQSDR_CONFIG_PHYS);

	zdev->status = devm_ioremap(&pdev->dev, ZYNQSDR_STATUS_PHYS,
				    ZYNQSDR_STATUS_SIZE);
	if (!zdev->status)
		return dev_err_probe(&pdev->dev, -ENOMEM,
				     "ioremap status 0x%08x\n", ZYNQSDR_STATUS_PHYS);

	zdev->rx = devm_ioremap(&pdev->dev, ZYNQSDR_RX_PHYS, ZYNQSDR_RX_SIZE);
	if (!zdev->rx)
		return dev_err_probe(&pdev->dev, -ENOMEM,
				     "ioremap rx 0x%08x\n", ZYNQSDR_RX_PHYS);

	for (i = 0; i < ZYNQSDR_WF_CHANNELS; i++) {
		zdev->wf[i] = devm_ioremap(&pdev->dev, ZYNQSDR_WF_PHYS(i),
					   ZYNQSDR_WF_SIZE);
		if (!zdev->wf[i])
			return dev_err_probe(&pdev->dev, -ENOMEM,
					     "ioremap wf%d 0x%08x\n", i,
					     ZYNQSDR_WF_PHYS(i));
	}

	zdev->pps = devm_ioremap(&pdev->dev, ZYNQSDR_PPS_PHYS, ZYNQSDR_PPS_SIZE);
	if (!zdev->pps)
		return dev_err_probe(&pdev->dev, -ENOMEM,
				     "ioremap pps 0x%08x\n", ZYNQSDR_PPS_PHYS);

	/*
	 * The 4 PL-PS IRQs (SPI 29-32, rising edge) are declared in DT.
	 * Stock probe validates them via platform_get_irq() but NEVER
	 * requests a handler — the complete function inventory of the
	 * stock binary contains no IRQ handler, no workqueue, no kfifo:
	 * the FPGA bus-masters data into the coherent DDR rings and the
	 * driver polls the status-page producer counters in ioctl context
	 * (see the data-plane note at the top of this file). We mirror
	 * that: validate only.
	 */
	for (i = 0; i < 4; i++) {
		ret = platform_get_irq(pdev, i);
		if (ret < 0)
			return dev_err_probe(&pdev->dev, ret,
					     "platform_get_irq %d\n", i);
	}

	zdev->misc.minor = MISC_DYNAMIC_MINOR;
	zdev->misc.name = ZYNQSDR_NAME;
	zdev->misc.fops = &zynqsdr_fops;
	zdev->misc.mode = 0666;	/* stock udev rule: MODE=0666 GROUP=plugdev */

	ret = misc_register(&zdev->misc);
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
				     "misc_register %s\n", ZYNQSDR_NAME);

	platform_set_drvdata(pdev, zdev);

	/*
	 * Deliberately NO PL register access in probe: with the PL
	 * unprogrammed (prog_done=0 — the normal state before userspace
	 * pushes a bitstream through /dev/xdevcfg) any AXI read to the PL
	 * address windows stalls the GP master forever and hard-hangs the
	 * CPU (observed on hardware: modprobe zynqsdr on blank
	 * PL killed the kernel instantly, no oops). The signature is
	 * available via the GET_SIGNATURE ioctl once the fabric is live.
	 */
	dev_info(&pdev->dev,
		 "zynqsdr control+data plane loaded (no PL access until bitstream is loaded)\n");
	return 0;
}

static void zynqsdr_remove(struct platform_device *pdev)
{
	struct zynqsdr_dev *zdev = platform_get_drvdata(pdev);

	misc_deregister(&zdev->misc);
}

static const struct of_device_id zynqsdr_of_match[] = {
	{ .compatible = "rx888,zynqsdr" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, zynqsdr_of_match);

static struct platform_driver zynqsdr_driver = {
	.probe	= zynqsdr_probe,
	.remove	= zynqsdr_remove,
	.driver	= {
		.name		= ZYNQSDR_NAME,
		.of_match_table	= zynqsdr_of_match,
	},
};
module_platform_driver(zynqsdr_driver);

MODULE_AUTHOR("web888-debian project");
MODULE_DESCRIPTION("Web-888 (RX-888) SDR platform control/data driver");
MODULE_LICENSE("GPL");
