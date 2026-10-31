/* zynqsdr-smoke.c — smoke test for the zynqsdr data plane.
 * Static armhf binary; opens /dev/zynqsdr and exercises the control ioctls
 * plus the data-plane: RX/WF/PPS arming, poll-copy reads, concurrent
 * readers, rmmod-while-open, arm/disarm stress.
 *
 * ABI: single source of truth in config/kernel/zynqsdr_uapi.h (included
 * below); no local ioctl definitions.
 *
 * Modes (first positional argument):
 *   (none) | qemu   legacy QEMU/no-PL mode: signature/DNA read 0, all FPGA
 *                    fifo counters read 0, PPS is -EBUSY, 0 WF channels
 *                    (WF_START must fail -EINVAL). RX has no channel
 *                    dependency, so the full RX arm/read path is exercised
 *                    for real: armed + dead FPGA must behave exactly like
 *                    stock — RX_READ returns rc=0 readed=0.
 *   --emu | emu     QEMU with the synthetic web888-pl model: signature
 *                    0x0E5D020C (12 RX / 2 WF channels), non-zero DNA,
 *                    GPIO mask readback, live RX/WF streams (readed>0),
 *                    PPS may or may not have a sample yet.
 *   --hw | hw       real hardware: signature/DNA non-zero, GPIO mask
 *                    readback 0x155, real ADC samples (readed>=0 contract).
 *   --emu HOST SSH_PORT
 *                   host mode (QEMU system lane, scripts/test-zynqsdr-qemu.sh):
 *                    run on the build host; uploads the armhf payload to the
 *                    guest over ssh and runs it there with --emu, relaying
 *                    output and exit status. Anything else prints the usage
 *                    and exits 2.
 */
#define _DEFAULT_SOURCE	/* usleep under -std=c11 */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

#include "../../config/kernel/zynqsdr_uapi.h"
#include "zynqsdr-emu-launch.h"

#define EMU_SIGNATURE	0x0E5D020Cu	/* web888-pl model default */
#define EMU_RX_CH	12u
#define EMU_WF_CH	2u

static int fails;
static int mode;	/* 0 = qemu/no-PL, 1 = emu (model), 2 = hw */

#define CHECK(cond, msg) do { \
	if (cond) { printf("ok: %s\n", msg); } \
	else { printf("FAIL: %s\n", msg); fails++; } \
} while (0)

static char rxbuf[19456];

static void usage(const char *prog)
{
	printf("usage: %s [qemu|--emu|emu|--hw|hw]\n", prog);
	printf("  (none)|qemu  run here (device/guest): no-PL QEMU expectations\n");
	printf("  --emu|emu    run here (device/guest): web888-pl model expectations\n");
	printf("               (sig 0x%08x, %u RX / %u WF ch)\n",
	       EMU_SIGNATURE, EMU_RX_CH, EMU_WF_CH);
	printf("  --hw|hw      run here: real hardware\n");
	printf("usage: %s --emu HOST SSH_PORT\n", prog);
	printf("  host mode: upload the armhf payload to the QEMU guest and run\n");
	printf("  it there with --emu, relaying output and exit status (lane:\n");
	printf("  scripts/test-zynqsdr-qemu.sh). Payload: zynqsdr-smoke.armhf next\n");
	printf("  to this binary or in scripts/hw-test/ (ZYNQSDR_REMOTE_BIN overrides)\n");
}

/* one full RX arm + partial-read cycle; returns readed or -errno */
static int do_rx_read(int fd, uint32_t len, void *buf)
{
	struct zynqsdr_rx_read_op op = { (uint32_t)(uintptr_t)buf, len, 0 };
	int rc = ioctl(fd, ZYNQSDR_RX_READ, &op);

	if (rc)
		return -errno;
	return op.readed;
}

/* fill with a sentinel the driver must never leave behind on readed==0 */
static int buf_all(const char *buf, size_t len, char v)
{
	size_t i;
	for (i = 0; i < len; i++)
		if (buf[i] != v)
			return 0;
	return 1;
}

#define N_READERS 4
#define N_ITERS 100

static void *reader_thread(void *arg)
{
	int fd = (int)(uintptr_t)arg;
	int i, total = 0;

	for (i = 0; i < N_ITERS; i++) {
		int n = do_rx_read(fd, sizeof(rxbuf), (void *)rxbuf);
		if (n < 0)
			return (void *)(uintptr_t)n;
		total += n;
	}
	return (void *)(uintptr_t)total;
}

int main(int argc, char **argv)
{
	int fd, rc, i;
	uint32_t sig, mask, mask2, pps;
	uint64_t dna;
	pthread_t th[N_READERS];
	char buf[19456];

	if (argc > 1) {
		/* QEMU system-mode lane: TOOL --emu HOST SSH_PORT (run on the
		 * build host; uploads the armhf payload to the guest and runs
		 * it there with --emu). See zynqsdr-emu-launch.h. */
		if (!strcmp(argv[1], "--emu") && argc == 4)
			return zynqsdr_emu_remote_main("zynqsdr-smoke", argc, argv);
		if (!strcmp(argv[1], "qemu"))
			mode = 0;
		else if (!strcmp(argv[1], "--emu") || !strcmp(argv[1], "emu"))
			mode = 1;
		else if (!strcmp(argv[1], "--hw") || !strcmp(argv[1], "hw"))
			mode = 2;
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
	printf("ok: open /dev/zynqsdr (mode %s)\n",
	       mode == 1 ? "emu" : mode == 2 ? "hw" : "qemu");

	/* ---- single-opener semantics (regression) ---- */

	{
		int fd2 = open("/dev/zynqsdr", O_RDWR | O_SYNC);
		CHECK(fd2 == -1 && errno == EBUSY,
		      "second open while held -> EBUSY");
		if (fd2 >= 0)
			close(fd2);
	}

	/* ---- control plane (regression) ---- */

	sig = 0xdeadbeef;
	rc = ioctl(fd, ZYNQSDR_GET_SIGNATURE, &sig);
	if (mode == 0) {
		CHECK(rc == 0 && sig == 0, "GET_SIGNATURE round-trip (0 under QEMU)");
	} else if (mode == 1) {
		CHECK(rc == 0 && sig == EMU_SIGNATURE,
		      "GET_SIGNATURE == 0x0E5D020C (emu model)");
		CHECK((sig & 0xff) == EMU_RX_CH && ((sig >> 8) & 0xff) == EMU_WF_CH,
		      "emu model exposes 12 RX / 2 WF channels");
	} else {
		CHECK(rc == 0 && sig != 0, "GET_SIGNATURE nonzero (hardware)");
		printf("signature 0x%08x -> rx_ch=%u wf_ch=%u\n",
		       sig, sig & 0xff, (sig >> 8) & 0xff);
	}

	dna = 0xdeadbeefcafebabeULL;
	rc = ioctl(fd, ZYNQSDR_GET_DNA, &dna);
	if (mode == 0) {
		CHECK(rc == 0 && dna == 0, "GET_DNA round-trip (0 under QEMU)");
	} else if (mode == 1) {
		CHECK(rc == 0 && dna != 0, "GET_DNA nonzero (emu model)");
		printf("dna 0x%016llx\n", (unsigned long long)dna);
	} else {
		CHECK(rc == 0 && dna != 0, "GET_DNA nonzero (hardware)");
		printf("dna 0x%016llx\n", (unsigned long long)dna);
	}

	rc = ioctl(fd, ZYNQSDR_GET_GPIO_MASK, &mask);
	CHECK(rc == 0, "GET_GPIO_MASK");
	rc = ioctl(fd, ZYNQSDR_SET_GPIO_MASK, 0x155);
	CHECK(rc == 0, "SET_GPIO_MASK 0x155");
	rc = ioctl(fd, ZYNQSDR_GET_GPIO_MASK, &mask2);
	CHECK(rc == 0, "GET_GPIO_MASK after set");
	printf("GPIO mask readback 0x%08x (0 under QEMU; must be 0x155 with PL)\n",
	       mask2);
	if (mode == 1)
		CHECK(mask2 == 0x155, "GPIO mask write/read back (emu model)");
	if (mode == 2)
		CHECK(mask2 == 0x155, "GPIO mask write/read back (hardware)");

	rc = ioctl(fd, ZYNQSDR_AD8370_SET, 0);
	CHECK(rc == 0, "AD8370_SET(0)");
	rc = ioctl(fd, ZYNQSDR_AD8370_SET, 63);
	CHECK(rc == 0, "AD8370_SET(63)");
	rc = ioctl(fd, ZYNQSDR_AD8370_SET, 256);
	CHECK(rc == -1 && errno == EINVAL, "AD8370_SET(256) -> EINVAL");

	rc = ioctl(fd, ZYNQSDR_MODE_SET, 1);
	CHECK(rc == 0, "MODE_SET(1)");
	rc = ioctl(fd, ZYNQSDR_CLK_SET, 1);
	CHECK(rc == 0, "CLK_SET(1)");

	/* ---- data plane ---- */

	/* RX_READ before any RX_START: rc=0, readed=0, buffer untouched.
	 * The sentinel catches a driver that copies length bytes regardless. */
	memset(buf, 0xa5, sizeof(buf));
	{
		struct zynqsdr_rx_read_op op = {
			(uint32_t)(uintptr_t)buf, sizeof(buf), 0 };
		rc = ioctl(fd, ZYNQSDR_RX_READ, &op);
		CHECK(rc == 0 && op.readed == 0,
		      "RX_READ before arm -> rc=0 readed=0");
		CHECK(buf_all(buf, sizeof(buf), 0xa5),
		      "RX_READ before arm leaves buffer untouched (sentinel)");
	}

	/* RX_START validation: decimate must be in [5,40] */
	rc = ioctl(fd, ZYNQSDR_RX_START, 4);
	CHECK(rc == -1 && errno == EINVAL, "RX_START(4) -> EINVAL");
	rc = ioctl(fd, ZYNQSDR_RX_START, 41);
	CHECK(rc == -1 && errno == EINVAL, "RX_START(41) -> EINVAL");
	rc = ioctl(fd, ZYNQSDR_RX_START, 20);
	CHECK(rc == 0, "RX_START(20) arm (coherent ring alloc + engine on)");

	/* re-arm: buffer persists, no leak (checked by rmmod cleanliness) */
	rc = ioctl(fd, ZYNQSDR_RX_START, 10);
	CHECK(rc == 0, "RX_START(10) re-arm");

	/* RX_PARAM channel validation against the signature's channel count */
	{
		struct zynqsdr_rx_param_op rp = { 0, 1000000 };
		rc = ioctl(fd, ZYNQSDR_RX_PARAM, &rp);
		if (mode == 0)
			CHECK(rc == -1 && errno == EINVAL,
			      "RX_PARAM(0) -> EINVAL (0 rx channels)");
		else
			CHECK(rc == 0, "RX_PARAM(0) accepted");
	}
	if (mode == 1) {
		struct zynqsdr_rx_param_op rp = { EMU_RX_CH - 1, 1000000 };
		rc = ioctl(fd, ZYNQSDR_RX_PARAM, &rp);
		CHECK(rc == 0, "RX_PARAM(11) accepted (emu model)");
		rp.channel = EMU_RX_CH;
		rc = ioctl(fd, ZYNQSDR_RX_PARAM, &rp);
		CHECK(rc == -1 && errno == EINVAL,
		      "RX_PARAM(12) -> EINVAL (emu model)");
	}

	/* armed + dead FPGA: producer counter 0 -> partial read of 0 */
	if (mode == 0) {
		rc = do_rx_read(fd, sizeof(rxbuf), (void *)rxbuf);
		CHECK(rc == 0, "RX_READ armed -> rc=0 readed=0 (dead FPGA)");
	} else if (mode == 1) {
		/* the model streams ~2.3 MB/s; after 300 ms the ring head is full */
		usleep(300000);
		rc = do_rx_read(fd, sizeof(rxbuf), buf);
		CHECK(rc == (int)sizeof(rxbuf),
		      "RX_READ armed -> full buffer (emu model live stream)");
		CHECK(!buf_all(buf, sizeof(buf), 0xa5) && !buf_all(buf, sizeof(buf), 0),
		      "RX_READ data non-constant (emu model tone+noise scene)");
	} else {
		rc = do_rx_read(fd, sizeof(rxbuf), (void *)rxbuf);
		CHECK(rc >= 0, "RX_READ armed (hardware: readed>=0 contract)");
	}
	memset(buf, 0xa5, sizeof(buf));
	{
		struct zynqsdr_rx_read_op op = {
			(uint32_t)(uintptr_t)buf, 0, 0 };
		rc = ioctl(fd, ZYNQSDR_RX_READ, &op);
		CHECK(rc == 0 && op.readed == 0, "RX_READ length 0 -> readed=0");
		CHECK(buf_all(buf, 4, 0xa5),
		      "RX_READ length 0 leaves buffer untouched");
	}

	/* concurrent readers on the shared fd (websdr thread model) */
	for (i = 0; i < N_READERS; i++) {
		rc = pthread_create(&th[i], NULL, reader_thread,
				    (void *)(uintptr_t)fd);
		CHECK(rc == 0, "pthread_create reader");
	}
	for (i = 0; i < N_READERS; i++) {
		void *ret;
		pthread_join(th[i], &ret);
		CHECK((int)(uintptr_t)ret >= 0, "concurrent RX_READ no error");
	}

	/* ---- waterfall ---- */

	/* WF_PARAM channel validation (signature's wf channel count) */
	if (mode != 0) {
		struct zynqsdr_wf_param_op wp = { 0, 20, 1000000 };
		rc = ioctl(fd, ZYNQSDR_WF_PARAM, &wp);
		CHECK(rc == 0, "WF_PARAM(0, decim=20) accepted");
		wp.channel = EMU_WF_CH;
		rc = ioctl(fd, ZYNQSDR_WF_PARAM, &wp);
		CHECK(rc == -1 && errno == EINVAL,
		      "WF_PARAM(2) -> EINVAL (2 wf channels)");
	}

	/* WF_READ before arm on a valid channel: rc=0 readed=0, sentinel holds */
	if (mode != 0) {
		struct zynqsdr_wf_read_op wop = { 0, (uint32_t)(uintptr_t)buf,
						  sizeof(buf), 0 };
		memset(buf, 0xa5, sizeof(buf));
		rc = ioctl(fd, ZYNQSDR_WF_READ, &wop);
		CHECK(rc == 0 && wop.readed == 0,
		      "WF_READ before arm -> rc=0 readed=0");
		CHECK(buf_all(buf, sizeof(buf), 0xa5),
		      "WF_READ before arm leaves buffer untouched (sentinel)");
	}

	rc = ioctl(fd, ZYNQSDR_WF_START, 0);
	if (mode == 0)
		CHECK(rc == -1 && errno == EINVAL, "WF_START(0) -> EINVAL (0 wf channels)");
	else
		CHECK(rc == 0, "WF_START(0) accepted");
	{
		struct zynqsdr_wf_read_op wop = { 0, (uint32_t)(uintptr_t)rxbuf,
						  sizeof(rxbuf), 0 };
		rc = ioctl(fd, ZYNQSDR_WF_READ, &wop);
		if (mode == 0)
			CHECK(rc == -1 && errno == EINVAL,
			      "WF_READ(0) -> EINVAL (0 wf channels)");
		else
			CHECK(rc == 0, "WF_READ(0) accepted");
	}

	/* PPS: arms fine (register writes); read depends on a GPS fix/sample */
	rc = ioctl(fd, ZYNQSDR_PPS_START, 1);
	CHECK(rc == 0, "PPS_START(1)");
	pps = 0xa5a5a5a5;
	rc = ioctl(fd, ZYNQSDR_PPS_READ, &pps);
	if (mode == 0 || mode == 2) {
		CHECK(rc == -1 && errno == EBUSY, "PPS_READ -> EBUSY (no FPGA)");
	} else {
		/* the model may or may not have pushed a sample yet */
		CHECK((rc == 0) || (rc == -1 && errno == EBUSY),
		      "PPS_READ -> sample or EBUSY (emu model)");
		if (rc == 0)
			printf("pps sample 0x%08x\n", pps);
	}

	rc = ioctl(fd, 0x1234, 0);
	CHECK(rc == -1 && errno == ENOTTY, "unknown ioctl -> ENOTTY");

	/* rmmod while this fd is open must fail cleanly (module in use),
	 * and the open fd must keep working afterwards. */
	rc = system("rmmod zynqsdr 2>/dev/null");
	CHECK(rc != 0, "rmmod with open fd -> refused (EBUSY)");
	rc = do_rx_read(fd, sizeof(rxbuf), (void *)rxbuf);
	if (mode == 2)
		/* ABI contract (RaspSDR/server zynq/peri.cpp): userspace RETRIES
		 * reads until `readed` fills the request — success is ANY
		 * non-negative readed (0..len); transient errnos EAGAIN/EBUSY/
		 * ETIMEDOUT/EIO/EINTR are also legal (stock giveup/wfe/IRQ races
		 * widen once the Si5351 ADC clock runs). errno is STALE on the
		 * success path — never test it when rc >= 0. */
		CHECK(rc >= 0 || errno == EAGAIN || errno == EBUSY ||
		      errno == ETIMEDOUT || errno == EIO || errno == EINTR,
		      "RX_READ after failed rmmod (hardware: readed>=0 or transient errno)");
	else
		CHECK(rc == 0, "RX_READ still works after failed rmmod");

	close(fd);

	/* single-opener semantics: reopen must work after close */
	fd = open("/dev/zynqsdr", O_RDWR);
	CHECK(fd >= 0, "reopen after close");
	if (fd >= 0)
		close(fd);

	/* arm/disarm stress: 50x open -> RX_START -> RX_READ -> PPS -> close */
	for (i = 0; i < 50; i++) {
		fd = open("/dev/zynqsdr", O_RDWR);
		if (fd < 0)
			break;
		ioctl(fd, ZYNQSDR_RX_START, 20);
		do_rx_read(fd, sizeof(rxbuf), (void *)rxbuf);
		ioctl(fd, ZYNQSDR_PPS_START, 1);
		close(fd);
	}
	CHECK(i == 50, "50x arm/disarm stress");

	if (fails) {
		printf("ZYNQSDR_SMOKE_FAIL (%d failures)\n", fails);
		return 1;
	}
	printf("ZYNQSDR_SMOKE_OK\n");
	return 0;
}
