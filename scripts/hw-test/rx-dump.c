/* rx-dump.c — diagnose whether the ADC data path delivers live samples.
 *
 * Opens /dev/zynqsdr, arms RX (decim=40, matching websdr's rx_decim=10240/256),
 * reads raw RX bytes, and classifies them:
 *   - all-zero       -> DMA ring never filled (ADC clock / bitstream data path dead)
 *   - all-constant   -> stuck/DC (ADC input not clocking, or bitstream frozen)
 *   - varying        -> live data (real ADC samples; signal vs noise is the only
 *                       remaining question, and that's an antenna/RF issue)
 *
 * Reports per-16-bit-word stats (RX bytes are complex I/Q, 16-bit two's-complement,
 * output of the FPGA DDC chain). Two reads are compared so a constant-but-nonzero
 * stream is distinguished from a live one.
 *
 * Build (Arch host):
 *   arm-linux-gnueabihf-gcc -static -O2 -L. -o rx-dump rx-dump.c
 * Run (device), with bitstream loaded + si5351-init done first:
 *   /root/rx-dump
 *
 * Prerequisite: nothing else may hold /dev/zynqsdr (single-opener). Stop websdr
 * first: `systemctl stop web888-websdr`.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/* direct PL register peek via /dev/mem, to see the RX engine state
 * (reset bit, decimate, DMA addr, start bytes) and the status-page fifo
 * producer counter — independent of the driver's view. */
#define CONFIG_PHYS 0x40000000UL
#define STATUS_PHYS 0x41000000UL
static volatile uint32_t *config_map, *status_map;
static void map_pl(void) {
	int m = open("/dev/mem", O_RDWR | O_SYNC);
	if (m < 0) { perror("open /dev/mem"); return; }
	config_map = mmap(0, 4096, PROT_READ|PROT_WRITE, MAP_SHARED, m, CONFIG_PHYS);
	status_map = mmap(0, 4096, PROT_READ, MAP_SHARED, m, STATUS_PHYS);
	if (config_map == MAP_FAILED || status_map == MAP_FAILED)
		printf("(PL mmap failed — continuing without register peek)\n");
	close(m);
}
/* config register reads (sizes per driver: u16 for reset/decimate, u32 for dma/gpio) */
static uint16_t cfg_reset(void)   { return config_map ? *(volatile uint16_t*)((char*)config_map+0x00) : 0xffff; }
static uint16_t cfg_decim(void)   { return config_map ? *(volatile uint16_t*)((char*)config_map+0x02) : 0xffff; }
static uint32_t cfg_dma(void)     { return config_map ? *(volatile uint32_t*)((char*)config_map+0x8c) : 0xffffffff; }
static uint16_t st_fifo(void)     { return status_map ? *(volatile uint16_t*)((char*)status_map+0x04) : 0xffff; }
static void dump_pl(const char *tag) {
	if (!config_map) return;
	printf("  [%s] RESET=0x%04x DECIM=0x%04x RX_DMA_ADDR=0x%08x  fifo(128B units)=%u\n",
		tag, cfg_reset(), cfg_decim(), cfg_dma(), st_fifo());
}

#define RX_START	_IOW('Z', 4, uint32_t)
#define RX_STOP		_IOW('Z', 14, uint32_t) /* if present; harmless if absent */

struct rx_read_op {
	uint32_t address;
	uint32_t length;
	uint32_t readed;
} __attribute__((packed));
#define RX_READ		_IOWR('Z', 6, struct rx_read_op)

#define SET_GPIO_MASK	_IOW('Z', 7, uint32_t)
#define MODE_SET	_IOW('Z', 1, uint32_t)
#define AD8370_SET	_IOW('Z', 0, uint32_t)
#define CLK_SET		_IOW('Z', 2, uint32_t)

#define RX_DECIM 40   /* websdr: rx_decim=10240, arg = 10240/256 = 40 */
#define BUFSZ    19456
#define N_READS  3    /* collect a few buffers so a live stream shows change */

static unsigned char buf[N_READS][BUFSZ];

/* classify a buffer of raw bytes */
static void classify(const char *tag, const unsigned char *b, int n)
{
	int i;
	int allzero = 1;
	for (i = 0; i < n; i++)
		if (b[i] != 0) { allzero = 0; break; }

	/* 16-bit word stats (little-endian; Zynq is LE) */
	int nwords = n / 2;
	int min16 = 0x7fff, max16 = -0x8000;
	long long sum = 0;
	int distinct = 0;
	int16_t prev = 0;
	for (i = 0; i < nwords; i++) {
		int16_t s = (int16_t)((b[2*i+1] << 8) | b[2*i]);
		if (s < min16) min16 = s;
		if (s > max16) max16 = s;
		sum += s;
		if (i == 0) { prev = s; }
		else if (s != prev) { distinct = 1; prev = s; }
	}
	double dc = nwords ? (double)sum / nwords : 0;

	printf("[%s] bytes=%d %s\n", tag, n,
		allzero ? "*** ALL ZERO ***" : "(non-zero)");
	printf("    16-bit words=%d  min=%d  max=%d  DC(mean)=%.1f  range=%d\n",
		nwords, min16, max16, dc, max16 - min16);
	printf("    varying=%s\n", distinct ? "YES (live data)" : "NO (constant stream)");
	if (!allzero && n >= 32) {
		printf("    first 32 bytes (hex):");
		for (i = 0; i < 32; i++) printf(" %02x", b[i]);
		printf("\n");
	}
}

int main(void)
{
	int fd = open("/dev/zynqsdr", O_RDWR);
	if (fd < 0) { perror("open /dev/zynqsdr"); printf("Is websdr stopped? Single-opener device.\n"); return 1; }
	map_pl();
	dump_pl("before RX_START");

	/* mirror websdr's RF init so the path is in the same state stock runs:
	 * MODE=HF(0), atten=0dB, int clk. The driver reads these ioctls as a
	 * raw unsigned long arg (NOT a dereferenced pointer), so pass the value
	 * directly — see zynqsdr.c RX_START handler + zynqsdr-smoke.c usage. */
	ioctl(fd, MODE_SET, 0);     /* HF */
	ioctl(fd, AD8370_SET, 0);   /* 0 dB */
	ioctl(fd, CLK_SET, 1);      /* internal clock */

	printf("Arming RX (decim=%d)...\n", RX_DECIM);
	int rc = ioctl(fd, RX_START, RX_DECIM);
	if (rc) { printf("RX_START failed: %s\n", strerror(errno)); close(fd); return 1; }
	dump_pl("after RX_START");

	int total = 0;
	for (int r = 0; r < N_READS; r++) {
		struct rx_read_op op = { (uint32_t)(uintptr_t)buf[r], BUFSZ, 0 };
		/* poll a few times: producer may need a moment to fill the ring */
		int tries = 0;
		do {
			rc = ioctl(fd, RX_READ, &op);
			if (rc) { printf("RX_READ[%d] error: %s\n", r, strerror(errno)); break; }
			if (op.readed > 0) break;
			usleep(100000); /* 100 ms */
		} while (++tries < 30);
		char tag[16];
		snprintf(tag, sizeof tag, "read %d", r);
		classify(tag, buf[r], op.readed);
		dump_pl(tag);
		total += op.readed;
		if (op.readed == 0) {
			printf("    (readed=0 after %d tries — producer not advancing)\n", tries);
		}
	}
	printf("----\ntotal bytes read: %d\n", total);

	/* compare read 0 vs read N-1 to confirm the stream is still moving */
	if (N_READS >= 2 && total > 0) {
		int last = N_READS - 1;
		int same = (memcmp(buf[0], buf[last], BUFSZ) == 0);
		printf("read 0 vs read %d identical: %s%s\n", last,
			same ? "YES" : "NO",
			same ? " (DMA not advancing / frozen)" : " (data changing over time = live)");
	}

	close(fd);
	return 0;
}
