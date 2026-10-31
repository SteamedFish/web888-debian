/* SPDX-License-Identifier: GPL-2.0-or-later */
/* zynqsdr-rearm-test.c — S1 regression: RX_START/WF_START must re-sync the
 * consumer offset to the ring head on EVERY successful (re)arm.
 *
 * Bug (S1): the old driver only zeroed the stream offset when the coherent
 * ring was first allocated. The FPGA producer re-enters the ring at the
 * head on every arm (verified in the QEMU web888-pl model: stream_start
 * resets ptr = 0), so after re-arming a stream that had already been read,
 * the driver consumed from a stale offset — returning wrong bytes and,
 * depending on the producer position, bogus chunk sizes.
 *
 * This test makes the offset non-zero, re-arms, and asserts the post-rearm
 * read behaves as if the ring were fresh. On the QEMU web888-pl model
 * (--emu) every assertion is fully deterministic:
 *
 *   RX (continuous stream, status page polled through /dev/mem):
 *     1. arm, wait for the producer to pass L, read L bytes (offset = L)
 *     2. re-arm -> producer restarts at ring head (position 0)
 *     3. wait until the producer position wrapped back below L/2
 *     4. read L bytes: a fixed driver returns the fresh head bytes
 *        (readed < L/2 + slack); the old driver computes a bogus
 *        ring-end chunk and returns exactly L (readed == L -> FAIL)
 *
 *   WF (model one-shot via the WF_READ_CONTINUES flag, no /dev/mem needed):
 *     1. WF_PARAM decim=1, WF_START ch|WF_READ_CONTINUES -> model writes
 *        exactly one 8192-sample block (32768 B) and stops
 *     2. read 16384 B (offset = 16384)
 *     3. re-arm -> fresh block from the ring head
 *     4. read 32768 B: a fixed driver returns the whole block
 *        (readed == 32768); the old driver starts at the stale offset and
 *        returns only 16384 (readed == 16384 -> FAIL)
 *
 * Modes:
 *   (none) | --hw | hw   run here: real hardware. /dev/mem register access
 *                        is used when available; on hardware only the strict
 *                        RX/WF re-sync assertions of the emu lane are
 *                        relaxed to the documented readed>=0 contract.
 *   --emu | emu          run here: QEMU web888-pl model (signature
 *                        0x0E5D020C, 12 RX / 2 WF channels). All
 *                        assertions strict.
 *   --emu HOST SSH_PORT  host mode (QEMU system lane, scripts/test-
 *                        zynqsdr-qemu.sh): run on the build host; uploads
 *                        the armhf payload to the guest over ssh and runs
 *                        it there with --emu, relaying output and exit.
 *
 * Exit status: 0 = ZYNQSDR_REARM_OK, 1 = failure, 2 = usage/unsupported.
 */
#define _DEFAULT_SOURCE	/* usleep under -std=c11 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "../../config/kernel/zynqsdr_uapi.h"
#include "zynqsdr-emu-launch.h"

#define EMU_SIGNATURE	0x0E5D020Cu
#define RX_CH		12u
#define WF_CH		2u

/* model ring geometry, mirrored from the driver/model contract */
#define RING_BYTES	0x7fc00u
#define BURST		128u
/* producer position limits: the model's ring is RING_BYTES/BURST bursts */
#define MAX_BURSTS	(RING_BYTES / BURST)

/* status page (0x41000000) register offsets */
#define STS_SIGNATURE	0x00
#define STS_RX_FIFO	0x04	/* u16, 128-byte units */
#define STS_WF_FIFO(ch)	(0x06 + (ch) * 2)	/* u16, 128-byte units */
/* config page (0x40000000) register offsets */
#define CFG_RESET	0x00

static int fails;
static int mode_emu;
static volatile uint16_t *sts;	/* status page via /dev/mem, or NULL */
static volatile uint16_t *cfg;	/* config page via /dev/mem, or NULL */

#define CHECK(cond, msg) do { \
	if (cond) { printf("ok: %s\n", msg); } \
	else { printf("FAIL: %s\n", msg); fails++; } \
} while (0)

static void usage(const char *prog)
{
	printf("usage: %s [--emu|emu|--hw|hw]\n", prog);
	printf("  (none)|--hw|hw  run here: real hardware (relaxed checks)\n");
	printf("  --emu|emu       run here: QEMU web888-pl model (strict)\n");
	printf("usage: %s --emu HOST SSH_PORT\n", prog);
	printf("  host mode: upload the armhf payload to the QEMU guest and run\n");
	printf("  it there with --emu, relaying output and exit status (lane:\n");
	printf("  scripts/test-zynqsdr-qemu.sh). Payload: zynqsdr-rearm.armhf next\n");
	printf("  to this binary or in scripts/hw-test/ (ZYNQSDR_REMOTE_BIN overrides)\n");
}

static int map_pl(void)
{
	int m = open("/dev/mem", O_RDWR | O_SYNC);
	void *p;

	if (m < 0)
		return -1;
	p = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, m, 0x41000000);
	if (p == MAP_FAILED) {
		close(m);
		return -1;
	}
	sts = (volatile uint16_t *)p;
	p = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, m, 0x40000000);
	if (p == MAP_FAILED) {
		munmap((void *)sts, 4096);
		sts = NULL;
		close(m);
		return -1;
	}
	cfg = (volatile uint16_t *)p;
	close(m);
	return 0;
}

static uint16_t rx_pos(void)  { return sts[STS_RX_FIFO / 2]; }

/* wait until cond() holds, polling every ms; returns 0 on timeout (5 s) */
static int wait_for(int (*cond)(void), const char *what)
{
	int i;

	for (i = 0; i < 5000; i++) {
		if (cond())
			return 1;
		usleep(1000);
	}
	printf("TIMEOUT waiting for %s\n", what);
	return 0;
}

/* ---- RX rearm -------------------------------------------------------- */

static uint32_t rx_target;
static int rx_past_target(void) { return rx_pos() * BURST >= rx_target; }
static uint32_t rx_window;
static int rx_in_window(void)
{
	uint32_t p = rx_pos();
	return p >= 1 && p * BURST <= rx_window;
}

#define RX_L	131072u	/* first read: makes the offset non-zero */
#define RX_L2	131072u	/* post-rearm read request */

static char rxbuf[RX_L2];

static void test_rx_rearm(int fd)
{
	int rc;
	ssize_t readed;

	printf("---- RX rearm ----\n");

	if (mode_emu) {
		rc = ioctl(fd, ZYNQSDR_RX_START, 20);
		CHECK(rc == 0, "RX_START(20) arm");

		/* deterministic first read: wait for the producer to pass L */
		rx_target = RX_L + 4096;
		CHECK(wait_for(rx_past_target, "RX producer past L"),
		      "RX producer position polled (status page)");
		readed = -1;
		{
			struct zynqsdr_rx_read_op op = {
				(uint32_t)(uintptr_t)rxbuf, RX_L, 0 };
			rc = ioctl(fd, ZYNQSDR_RX_READ, &op);
			readed = rc ? -(ssize_t)errno : (ssize_t)op.readed;
		}
		CHECK(rc == 0 && readed == (ssize_t)RX_L,
		      "RX_READ L bytes (offset now non-zero)");

		/* re-arm: the model producer restarts at ring head (pos 0) */
		rc = ioctl(fd, ZYNQSDR_RX_START, 20);
		CHECK(rc == 0, "RX_START(20) re-arm");

		/* wait until the fresh producer wrapped back below L/2 */
		rx_window = RX_L / 2;
		CHECK(wait_for(rx_in_window, "RX producer wrapped below L/2"),
		      "RX producer restarted at ring head (emu model)");

		memset(rxbuf, 0xa5, RX_L2);
		{
			struct zynqsdr_rx_read_op op = {
				(uint32_t)(uintptr_t)rxbuf, RX_L2, 0 };
			rc = ioctl(fd, ZYNQSDR_RX_READ, &op);
			readed = rc ? -(ssize_t)errno : (ssize_t)op.readed;
		}
		CHECK(rc == 0, "RX_READ after re-arm -> rc=0");
		/* fixed driver: fresh head bytes only (readed <= window+slack);
		 * old driver: bogus ring-end chunk, readed == RX_L2 exactly */
		CHECK(readed > 0 && readed < (ssize_t)(RX_L - 16384),
		      "RX rearm re-synced consumer to ring head (readed < L)");
		printf("post-rearm readed=%zd (buggy driver would return %u)\n",
		       readed, RX_L2);
	} else {
		/* hardware: no deterministic producer model; verify the
		 * sequence completes under the documented contract */
		rc = ioctl(fd, ZYNQSDR_RX_START, 20);
		CHECK(rc == 0, "RX_START(20) arm (hardware)");
		usleep(500000);
		readed = -1;
		{
			struct zynqsdr_rx_read_op op = {
				(uint32_t)(uintptr_t)rxbuf, RX_L, 0 };
			rc = ioctl(fd, ZYNQSDR_RX_READ, &op);
			readed = rc ? -(ssize_t)errno : (ssize_t)op.readed;
		}
		CHECK(rc == 0 && readed >= 0,
		      "RX_READ before rearm (hardware: readed>=0)");
		rc = ioctl(fd, ZYNQSDR_RX_START, 20);
		CHECK(rc == 0, "RX_START(20) re-arm (hardware)");
		usleep(500000);
		{
			struct zynqsdr_rx_read_op op = {
				(uint32_t)(uintptr_t)rxbuf, RX_L2, 0 };
			rc = ioctl(fd, ZYNQSDR_RX_READ, &op);
			readed = rc ? -(ssize_t)errno : (ssize_t)op.readed;
		}
		CHECK(rc == 0 && readed >= 0,
		      "RX_READ after rearm (hardware: readed>=0)");
		printf("note: strict re-sync assertions require --emu "
		       "(deterministic producer)\n");
	}
}

/* ---- WF rearm -------------------------------------------------------- */

#define WF_BLOCK	32768u	/* model one-shot: 8192 samples x 4 bytes */
#define WF_L		16384u	/* first read: makes the offset non-zero */

static char wfbuf[WF_BLOCK];

static int wf_do_read(int fd, int ch, uint32_t len)
{
	struct zynqsdr_wf_read_op op = {
		(uint16_t)ch, (uint32_t)(uintptr_t)wfbuf, len, 0 };
	int rc = ioctl(fd, ZYNQSDR_WF_READ, &op);

	if (rc)
		return -errno;
	return op.readed;
}

static void test_wf_rearm(int fd, int ch)
{
	int rc;
	ssize_t readed;
	char tag[32];

	snprintf(tag, sizeof(tag), "WF%d", ch);
	printf("---- %s rearm ----\n", tag);

	/* one 8192-sample block at decim=1 completes in ~67 us of model
	 * time; 500 ms of guest sleep is orders of magnitude more */
	{
		struct zynqsdr_wf_param_op wp = { (uint16_t)ch, 1, 0 };
		rc = ioctl(fd, ZYNQSDR_WF_PARAM, &wp);
		CHECK(rc == 0, "WF_PARAM(decim=1)");
	}

	if (mode_emu) {
		/* WF_READ_CONTINUES -> model one-shot block */
		rc = ioctl(fd, ZYNQSDR_WF_START,
			   (uint32_t)ch | ZYNQSDR_WF_READ_CONTINUES);
		CHECK(rc == 0, "WF_START (model one-shot)");
		usleep(500000);
		readed = wf_do_read(fd, ch, WF_L);
		CHECK(readed == (ssize_t)WF_L,
		      "WF_READ half block (offset now non-zero)");

		rc = ioctl(fd, ZYNQSDR_WF_START,
			   (uint32_t)ch | ZYNQSDR_WF_READ_CONTINUES);
		CHECK(rc == 0, "WF_START re-arm (fresh block from head)");
		usleep(500000);

		memset(wfbuf, 0xa5, sizeof(wfbuf));
		readed = wf_do_read(fd, ch, WF_BLOCK);
		CHECK(readed == (ssize_t)WF_BLOCK,
		      "WF rearm re-synced consumer to ring head (full block)");
		if (readed == (ssize_t)WF_L)
			printf("readed=%zd: this is the S1 bug signature "
			       "(stale offset survives re-arm)\n", readed);
	} else {
		/* hardware: the flag's engine semantics differ from the
		 * model; only the call contract is asserted */
		rc = ioctl(fd, ZYNQSDR_WF_START,
			   (uint32_t)ch | ZYNQSDR_WF_READ_CONTINUES);
		CHECK(rc == 0, "WF_START (hardware)");
		usleep(500000);
		readed = wf_do_read(fd, ch, WF_L);
		CHECK(readed >= 0, "WF_READ (hardware: readed>=0)");
		rc = ioctl(fd, ZYNQSDR_WF_START,
			   (uint32_t)ch | ZYNQSDR_WF_READ_CONTINUES);
		CHECK(rc == 0, "WF_START re-arm (hardware)");
		usleep(500000);
		readed = wf_do_read(fd, ch, WF_L);
		CHECK(readed >= 0, "WF_READ after rearm (hardware: readed>=0)");
		printf("note: strict re-sync assertions require --emu "
		       "(deterministic one-shot block)\n");
	}
}

int main(int argc, char **argv)
{
	int fd, rc;
	uint32_t sig;
	int have_mem = 0;

	if (argc > 1) {
		/* QEMU system-mode lane: TOOL --emu HOST SSH_PORT (run on the
		 * build host; uploads the armhf payload to the guest and runs
		 * it there with --emu). See zynqsdr-emu-launch.h. */
		if (!strcmp(argv[1], "--emu") && argc == 4)
			return zynqsdr_emu_remote_main("zynqsdr-rearm", argc, argv);
		if (!strcmp(argv[1], "--emu") || !strcmp(argv[1], "emu"))
			mode_emu = 1;
		else if (!strcmp(argv[1], "--hw") || !strcmp(argv[1], "hw"))
			mode_emu = 0;
		else {
			usage(argv[0]);
			return 2;
		}
	}

	fd = open("/dev/zynqsdr", O_RDWR | O_SYNC);
	if (fd < 0) {
		printf("FAIL: open /dev/zynqsdr: %s\n", strerror(errno));
		return 1;
	}
	printf("ok: open /dev/zynqsdr (mode %s)\n", mode_emu ? "emu" : "hw");

	sig = 0;
	rc = ioctl(fd, ZYNQSDR_GET_SIGNATURE, &sig);
	CHECK(rc == 0, "GET_SIGNATURE");
	if (mode_emu) {
		CHECK(sig == EMU_SIGNATURE,
		      "signature 0x0E5D020C (emu model)");
		CHECK((sig & 0xff) == RX_CH && ((sig >> 8) & 0xff) == WF_CH,
		      "12 RX / 2 WF channels (emu model)");
	} else {
		CHECK(sig != 0, "nonzero signature (hardware)");
		printf("signature 0x%08x -> rx_ch=%u wf_ch=%u\n",
		       sig, sig & 0xff, (sig >> 8) & 0xff);
	}

	if (mode_emu) {
		have_mem = map_pl() == 0;
		CHECK(have_mem, "status page mapped via /dev/mem (emu)");
		if (!have_mem) {
			printf("ZYNQSDR_REARM_FAIL (/dev/mem status page "
			       "required for the deterministic emu checks)\n");
			return 1;
		}
	} else if (map_pl() == 0) {
		have_mem = 1;
		printf("ok: PL register pages mapped via /dev/mem\n");
	}

	test_rx_rearm(fd);
	test_wf_rearm(fd, 0);
	if (((sig >> 8) & 0xff) >= 2 || mode_emu)
		test_wf_rearm(fd, 1);

	close(fd);

	if (sts) {
		munmap((void *)sts, 4096);
		munmap((void *)cfg, 4096);
	}

	if (fails) {
		printf("ZYNQSDR_REARM_FAIL (%d failures)\n", fails);
		return 1;
	}
	printf("ZYNQSDR_REARM_OK\n");
	return 0;
}
