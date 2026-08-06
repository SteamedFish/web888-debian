/* zynqsdr-smoke.c — QEMU smoke test for the zynqsdr data plane.
 * Static armhf binary; opens /dev/zynqsdr and exercises the control ioctls
 * plus the data-plane: RX/WF/PPS arming, poll-copy reads, concurrent
 * readers, rmmod-while-open, arm/disarm stress.
 * ABI mirror of RaspSDR/server zynq/ioctl.h (struct names adapted).
 * In QEMU there is no PL fabric: signature/DNA read 0, all FPGA fifo
 * counters read 0, PPS is -EBUSY, WF channel count is 0 (WF_START must
 * fail -EINVAL). RX has no channel dependency, so the full RX arm/read
 * path is exercised for real: armed + dead FPGA must behave exactly like
 * stock — RX_READ returns rc=0 readed=0 (partial read of nothing).
 */
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

#define AD8370_SET	_IOW('Z', 0, uint32_t)
#define MODE_SET	_IOW('Z', 1, uint32_t)
#define CLK_SET		_IOW('Z', 2, uint32_t)
#define GET_DNA		_IOR('Z', 3, uint64_t)
#define RX_START	_IOW('Z', 4, uint32_t)

struct rx_param_op {
	uint32_t channel;
	uint64_t freq;
} __attribute__((packed));
#define RX_PARAM	_IOW('Z', 5, struct rx_param_op)

struct rx_read_op {
	uint32_t address;
	uint32_t length;
	uint32_t readed;
} __attribute__((packed));
#define RX_READ		_IOWR('Z', 6, struct rx_read_op)

#define SET_GPIO_MASK	_IOW('Z', 7, uint32_t)
#define GET_GPIO_MASK	_IOR('Z', 8, uint32_t)
#define GET_SIGNATURE	_IOR('Z', 9, uint32_t)
#define WF_START	_IOW('Z', 10, uint32_t)

struct wf_read_op {
	uint16_t channel;
	uint32_t address;
	uint32_t length;
	uint32_t readed;
} __attribute__((packed));
#define WF_READ		_IOWR('Z', 12, struct wf_read_op)

#define PPS_START	_IOW('Z', 20, uint32_t)
#define PPS_READ	_IOR('Z', 21, uint32_t)

static int fails;

#define CHECK(cond, msg) do { \
	if (cond) { printf("ok: %s\n", msg); } \
	else { printf("FAIL: %s\n", msg); fails++; } \
} while (0)

static char rxbuf[19456];

/* one full RX arm + partial-read cycle; returns readed */
static int do_rx_read(int fd, uint32_t len)
{
	struct rx_read_op op = { (uint32_t)(uintptr_t)rxbuf, len, 0 };
	int rc = ioctl(fd, RX_READ, &op);

	if (rc)
		return -errno;
	return op.readed;
}

#define N_READERS 4
#define N_ITERS 100

static void *reader_thread(void *arg)
{
	int fd = (int)(uintptr_t)arg;
	int i, total = 0;

	for (i = 0; i < N_ITERS; i++) {
		int n = do_rx_read(fd, sizeof(rxbuf));
		if (n < 0)
			return (void *)(uintptr_t)n;
		total += n;
	}
	return (void *)(uintptr_t)total;
}

int main(int argc, char **argv)
{
	int fd, rc, i;
	int on_hardware = (argc > 1 && strcmp(argv[1], "hw") == 0);
	uint32_t sig, mask, mask2, pps;
	uint64_t dna;
	pthread_t th[N_READERS];

	fd = open("/dev/zynqsdr", O_RDWR | O_SYNC);
	if (fd < 0) {
		printf("FAIL: open /dev/zynqsdr: %s\n", strerror(errno));
		return 1;
	}
	printf("ok: open /dev/zynqsdr\n");

	/* ---- control plane (regression) ---- */

	sig = 0xdeadbeef;
	rc = ioctl(fd, GET_SIGNATURE, &sig);
	if (on_hardware) {
		CHECK(rc == 0 && sig != 0, "GET_SIGNATURE nonzero (hardware)");
		printf("signature 0x%08x -> rx_ch=%u wf_ch=%u\n",
		       sig, sig & 0xff, (sig >> 8) & 0xff);
	} else {
		CHECK(rc == 0 && sig == 0, "GET_SIGNATURE round-trip (0 under QEMU)");
	}

	dna = 0xdeadbeefcafebabeULL;
	rc = ioctl(fd, GET_DNA, &dna);
	if (on_hardware) {
		CHECK(rc == 0 && dna != 0, "GET_DNA nonzero (hardware)");
		printf("dna 0x%016llx\n", (unsigned long long)dna);
	} else {
		CHECK(rc == 0 && dna == 0, "GET_DNA round-trip (0 under QEMU)");
	}

	rc = ioctl(fd, GET_GPIO_MASK, &mask);
	CHECK(rc == 0, "GET_GPIO_MASK");
	rc = ioctl(fd, SET_GPIO_MASK, 0x155);
	CHECK(rc == 0, "SET_GPIO_MASK 0x155");
	rc = ioctl(fd, GET_GPIO_MASK, &mask2);
	CHECK(rc == 0, "GET_GPIO_MASK after set");
	printf("GPIO mask readback 0x%08x (0 under QEMU; must be 0x155 on hardware)\n",
	       mask2);
	if (on_hardware)
		CHECK(mask2 == 0x155, "GPIO mask write/read back (hardware)");

	rc = ioctl(fd, AD8370_SET, 0);
	CHECK(rc == 0, "AD8370_SET(0)");
	rc = ioctl(fd, AD8370_SET, 63);
	CHECK(rc == 0, "AD8370_SET(63)");
	rc = ioctl(fd, AD8370_SET, 256);
	CHECK(rc == -1 && errno == EINVAL, "AD8370_SET(256) -> EINVAL");

	rc = ioctl(fd, MODE_SET, 1);
	CHECK(rc == 0, "MODE_SET(1)");
	rc = ioctl(fd, CLK_SET, 1);
	CHECK(rc == 0, "CLK_SET(1)");

	/* ---- data plane ---- */

	/* RX_READ before any RX_START: rc=0, readed=0 (never armed) */
	rc = do_rx_read(fd, sizeof(rxbuf));
	CHECK(rc == 0, "RX_READ before arm -> rc=0 readed=0");

	/* RX_START validation: decimate must be in [5,40] */
	rc = ioctl(fd, RX_START, 4);
	CHECK(rc == -1 && errno == EINVAL, "RX_START(4) -> EINVAL");
	rc = ioctl(fd, RX_START, 41);
	CHECK(rc == -1 && errno == EINVAL, "RX_START(41) -> EINVAL");
	rc = ioctl(fd, RX_START, 20);
	CHECK(rc == 0, "RX_START(20) arm (coherent ring alloc + engine on)");

	/* re-arm: buffer persists, no leak (checked by rmmod cleanliness) */
	rc = ioctl(fd, RX_START, 10);
	CHECK(rc == 0, "RX_START(10) re-arm");

	/* RX_PARAM: no PL under QEMU -> 0 rx channels -> EINVAL */
	{
		struct rx_param_op rp = { 0, 1000000 };
		rc = ioctl(fd, RX_PARAM, &rp);
		if (on_hardware)
			CHECK(rc == 0, "RX_PARAM(0) accepted (hardware)");
		else
			CHECK(rc == -1 && errno == EINVAL,
			      "RX_PARAM(0) -> EINVAL (0 rx channels)");
	}

	/* armed + dead FPGA: producer counter 0 -> partial read of 0 */
	rc = do_rx_read(fd, sizeof(rxbuf));
	CHECK(rc == 0, "RX_READ armed -> rc=0 readed=0 (dead FPGA)");
	rc = do_rx_read(fd, 0);
	CHECK(rc == 0, "RX_READ length 0 -> readed=0");

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

	/* WF: no PL under QEMU -> 0 wf channels -> EINVAL (stock parity) */
	rc = ioctl(fd, WF_START, 0);
	if (on_hardware)
		CHECK(rc == 0, "WF_START(0) accepted (hardware)");
	else
		CHECK(rc == -1 && errno == EINVAL, "WF_START(0) -> EINVAL (0 wf channels)");
	{
		struct wf_read_op wop = { 0, (uint32_t)(uintptr_t)rxbuf,
					  sizeof(rxbuf), 0 };
		rc = ioctl(fd, WF_READ, &wop);
		if (on_hardware)
			CHECK(rc == 0, "WF_READ(0) accepted (hardware)");
		else
			CHECK(rc == -1 && errno == EINVAL,
			      "WF_READ(0) -> EINVAL (0 wf channels)");
	}

	/* PPS: arms fine (register writes), read is -EBUSY with no fix */
	rc = ioctl(fd, PPS_START, 1);
	CHECK(rc == 0, "PPS_START(1)");
	pps = 0xa5a5a5a5;
	rc = ioctl(fd, PPS_READ, &pps);
	CHECK(rc == -1 && errno == EBUSY, "PPS_READ -> EBUSY (no FPGA)");

	rc = ioctl(fd, 0x1234, 0);
	CHECK(rc == -1 && errno == ENOTTY, "unknown ioctl -> ENOTTY");

	/* rmmod while this fd is open must fail cleanly (module in use),
	 * and the open fd must keep working afterwards. */
	rc = system("rmmod zynqsdr 2>/dev/null");
	CHECK(rc != 0, "rmmod with open fd -> refused (EBUSY)");
	rc = do_rx_read(fd, sizeof(rxbuf));
	if (on_hardware)
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
		ioctl(fd, RX_START, 20);
		do_rx_read(fd, sizeof(rxbuf));
		ioctl(fd, PPS_START, 1);
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
