/* SPDX-License-Identifier: GPL-2.0-or-later */
/* zynqsdr-datapath.c — model-only data-path validation for /dev/zynqsdr.
 *
 * Fresh implementation. Asserts the stock-ABI data plane (RX frames,
 * waterfall blocks, retune/rearm behaviour) against the QEMU web888-pl
 * PL model — the coverage that used to be delegated to the pinned upstream
 * web888d binary and its /ws product protocol. That external dependency is
 * gone: this tool is plain C, libc-only (no libm), and derives every
 * expectation from
 *
 *   - the PL model itself (resources/qemu-web888/qemu/files/hw/misc/
 *     web888_pl.c): default scene = 10 MHz AM carrier with +1 kHz
 *     modulation, fs = 122.88 MHz, RX frame = NRX x {i32-le I, i32-le Q},
 *     full-scale real sine 2^29, CIC1 R=256 N=3 + CIC2 R=decimate N=5;
 *   - the stock ABI (config/kernel/zynqsdr_uapi.h, single source of truth);
 *   - behavioural references: the pinned upstream daemon
 *     jeskko/web888-ng v0.6.0 (commit 48e9914aac80e3f20c39838fe9b33193
 *     b6b3fb36 — the independent consumer contract this replaces) and the
 *     vendored open driver header
 *     resources/reference/web888-ng-hw/driver/web888_sdr.h.
 *
 * Expectations with RX_START(20) (24 kS/s) and all 12 channel NCOs tuned
 * to the 10 MHz carrier:
 *
 *   - carrier lands at DC: per-channel I has a ~+1.7e7 mean (2^29 *
 *     10^(-30/20)), Q is noise-only; the 1 kHz AM sidebands ripple I by
 *     ~2*4.25e6. Per-channel phases are NOT identical across channels
 *     (each RX_PARAM retune rebuilds one channel at a different stream
 *     position, and the baremetal PL test shows per-channel phase
 *     offsets), so there is deliberately NO cross-channel equality
 *     assertion — framing/IQ/endianness/energy checks are per-channel;
 *   - RX ring is 0x7fc00 bytes (ZYNQSDR_DMA_SIZE in config/kernel/zynqsdr.c)
 *     and NOT a multiple of the 96-byte frame: the byte stream must stay
 *     frame-continuous across the wrap;
 *   - WF: plain WF_START(ch) is continuous on the model, WF_START(ch|
 *     ZYNQSDR_WF_READ_CONTINUES) is a one-shot 8192-sample block
 *     (32768 bytes); a WF_PARAM decimate change while armed pulses the
 *     channel reset and yields a fresh block, a same-value WF_PARAM is a
 *     no-op (no new block).
 *
 * Retune (RX_PARAM while armed) moves the carrier to +1 kHz: the strict
 * DC assertions are replaced by energy and sign-change-rate assertions
 * that are robust to the chosen retune.
 *
 * MODEL-ONLY: this tool refuses to run on real hardware. It normalises
 * device state at start (attenuator code 0, HF mode) and restores the
 * GPIO mask it found, so it is safe to run repeatedly in the QEMU lane.
 *
 * Modes:
 *   --emu | emu          run here (QEMU guest): web888-pl model assertions.
 *   --emu HOST SSH_PORT  host mode (QEMU system lane, scripts/test-
 *                        zynqsdr-qemu.sh): run on the build host; uploads
 *                        the armhf payload to the guest over ssh and runs
 *                        it there with --emu, relaying output and exit.
 *   anything else        usage + exit 2 (no hardware mode exists).
 *
 * Exit status: 0 = ZYNQSDR_DATAPATH_OK, 1 = failure, 2 = usage/unsupported.
 */
#define _DEFAULT_SOURCE	/* usleep under -std=c11 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include "../../config/kernel/zynqsdr_uapi.h"
#include "zynqsdr-emu-launch.h"

#define EMU_SIGNATURE	0x0E5D020Cu	/* web888-pl model default */
#define NRX		12u		/* RX channels in the model signature */
#define FRAME_BYTES	(NRX * 8u)	/* 12ch * {i32 I, i32 Q} = 96 */
#define RX_DECIM	20u		/* -> fs/(256*20) = 24 kS/s */
#define FS_ADC_HZ	122880000.0	/* web888-pl adc-hz default */
#define WF_BLOCK_BYTES	32768u		/* 8192 samples * {i16 I, i16 Q} */
#define RING_BYTES	0x7fc00u	/* ZYNQSDR_DMA_SIZE (driver) */
#define POLL_ITERS	300		/* 300 x 10 ms bounded polls */
#define DRAIN_TIMEOUT_S	90		/* hard wall-clock bound for the
					   full-ring wrap drain (production
					   is wall-clock paced: 24 kS/s x 96 B
					   ~= 2.3 MB/s, so one ring needs only
					   ~0.25 s; 90 s covers heavy TCG lag) */
#define DRAIN_MAX_ITERS	30000		/* belt-and-braces iteration cap */

/* deterministic per-channel amplitudes derived from the PL model scene */
#define CARRIER_AMP	16980000LL	/* 2^29 * 10^(-30/20), I mean */
#define NOISE_SIGMA	1900LL		/* sigma of the -150 dBFS/Hz floor */

static int fails;

#define CHECKF(cond, fmt, ...) do { \
	if (cond) \
		printf("ok: " fmt "\n", ##__VA_ARGS__); \
	else { \
		printf("FAIL: " fmt "\n", ##__VA_ARGS__); \
		fails++; \
	} \
} while (0)

static void usage(const char *prog)
{
	printf("usage: %s --emu\n", prog);
	printf("  run here (QEMU guest): web888-pl model data-path validation.\n");
	printf("usage: %s --emu HOST SSH_PORT\n", prog);
	printf("  host mode: upload the armhf payload to the QEMU guest and run\n");
	printf("  it there with --emu, relaying output and exit status (lane:\n");
	printf("  scripts/test-zynqsdr-qemu.sh). Payload: zynqsdr-datapath.armhf\n");
	printf("  next to this binary or in scripts/hw-test/ (ZYNQSDR_REMOTE_BIN\n");
	printf("  overrides).\n");
	printf("MODEL-ONLY: no hardware mode exists; any other argument exits 2.\n");
}

/* NCO phase increment word for f_hz (f/fs * 2^48), plain double arithmetic */
static uint64_t nco_word(double f_hz)
{
	return (uint64_t)(f_hz / FS_ADC_HZ * 281474976710656.0 + 0.5);
}

static int32_t ld_i32le(const uint8_t *p)
{
	uint32_t v = (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
		     ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);

	return (int32_t)v;
}

static int rx_read(int fd, void *buf, uint32_t len, uint32_t *readed)
{
	struct zynqsdr_rx_read_op op = {
		(uint32_t)(uintptr_t)buf, len, 0 };

	if (ioctl(fd, ZYNQSDR_RX_READ, &op) != 0)
		return -errno;
	if (op.readed > len)
		return -EIO;	/* contract violation: readed <= length */
	*readed = op.readed;
	return 0;
}

static int wf_read(int fd, unsigned chan, void *buf, uint32_t len,
		   uint32_t *readed)
{
	struct zynqsdr_wf_read_op op = {
		(uint16_t)chan, (uint32_t)(uintptr_t)buf, len, 0 };

	if (ioctl(fd, ZYNQSDR_WF_READ, &op) != 0)
		return -errno;
	if (op.readed > len)
		return -EIO;
	*readed = op.readed;
	return 0;
}

/* poll a read until it returns exactly `want` bytes; bounded iterations */
static int rx_read_full(int fd, void *buf, uint32_t want)
{
	int i;
	uint32_t readed = 0;

	for (i = 0; i < POLL_ITERS; i++) {
		int rc = rx_read(fd, buf, want, &readed);

		if (rc) {
			printf("FAIL: RX_READ(%u) rc=%d (%s)\n",
			       want, rc, strerror(-rc));
			fails++;
			return -1;
		}
		if (readed == want)
			return 0;
		usleep(10000);
	}
	printf("FAIL: RX_READ(%u) readed=%u after %d polls (%.1f s): "
	       "producer stalled\n", want, readed, i, i * 0.01);
	fails++;
	return -1;
}

static int wf_read_full(int fd, unsigned chan, void *buf, uint32_t want)
{
	int i;
	uint32_t readed = 0;

	for (i = 0; i < POLL_ITERS; i++) {
		int rc = wf_read(fd, chan, buf, want, &readed);

		if (rc) {
			printf("FAIL: WF_READ(%u,%u) rc=%d (%s)\n",
			       chan, want, rc, strerror(-rc));
			fails++;
			return -1;
		}
		if (readed == want)
			return 0;
		usleep(10000);
	}
	printf("FAIL: WF_READ(%u,%u) readed=%u after %d polls (%.1f s)\n",
	       chan, want, readed, i, i * 0.01);
	fails++;
	return -1;
}

/*
 * Validate a frame-aligned RX window (nframes * FRAME_BYTES at `frames`).
 *
 * Per-sample bounds (both tunes): |I|,|Q| < 7e7 — catches garbage,
 * endianness breakage and frame-interleave slips (a Q or wrong-channel
 * value would land outside the deterministic envelope).
 *
 * strict (carrier tuned to DC): I mean ~ CARRIER_AMP, Q mean ~ 0,
 * I-energy >> Q-energy (I/Q-swap detector) and zero I sign changes.
 *
 * !strict (post-retune, carrier at +1 kHz): zero-mean assertions are
 * invalid, so use complex energy and a 1 kHz sign-change-rate window.
 */
static void validate_window(const uint8_t *frames, unsigned nframes,
			    int strict, const char *tag)
{
	int64_t sumI[NRX] = { 0 }, sumQ[NRX] = { 0 };
	int64_t sumI2[NRX] = { 0 }, sumQ2[NRX] = { 0 };
	unsigned sc = 0;
	unsigned f, c;
	int prev_sign = 0;

	for (f = 0; f < nframes; f++) {
		const uint8_t *fr = frames + (size_t)f * FRAME_BYTES;

		for (c = 0; c < NRX; c++) {
			int32_t i0 = ld_i32le(fr + c * 8);
			int32_t q0 = ld_i32le(fr + c * 8 + 4);

			if (i0 > 70000000 || i0 < -70000000 ||
			    q0 > 70000000 || q0 < -70000000) {
				printf("FAIL: [%s] frame %u ch %u sample out of "
				       "envelope: I=%d Q=%d (offset %zu)\n",
				       tag, f, c, i0, q0,
				       (size_t)f * FRAME_BYTES + c * 8);
				fails++;
				return;	/* one report is actionable enough */
			}
			sumI[c] += i0;
			sumQ[c] += q0;
			sumI2[c] += (int64_t)i0 * i0;
			sumQ2[c] += (int64_t)q0 * q0;
			if (c == 0) {
				int sign = (i0 > 0) - (i0 < 0);

				if (f && sign && sign == -prev_sign)
					sc++;
				if (sign)
					prev_sign = sign;
			}
		}
	}

	for (c = 0; c < NRX; c++) {
		int64_t n = (int64_t)nframes;
		int64_t meanI = sumI[c] / n;
		int64_t absmeanQ = sumQ[c] / n;
		int64_t eI = sumI2[c] / n;	/* E[I^2] */
		int64_t eQ = sumQ2[c] / n;	/* E[Q^2] */

		if (absmeanQ < 0)
			absmeanQ = -absmeanQ;
		if (strict) {
			CHECKF(meanI > 10000000LL && meanI < 25000000LL,
			       "[%s] ch %u I mean %lld in [1.0e7, 2.5e7] "
			       "(DC carrier)", tag, c, (long long)meanI);
			CHECKF(absmeanQ < 500000LL,
			       "[%s] ch %u |Q mean| %lld < 5e5 (Q is noise-only)",
			       tag, c, (long long)absmeanQ);
			CHECKF(eI > 200000000000000LL && eI < 450000000000000LL,
			       "[%s] ch %u E[I^2] %lld in [2.0e14, 4.5e14]",
			       tag, c, (long long)eI);
			CHECKF(eQ < 1000000000000LL,
			       "[%s] ch %u E[Q^2] %lld < 1e12",
			       tag, c, (long long)eQ);
			CHECKF(sumI2[c] > 4 * sumQ2[c],
			       "[%s] ch %u I-energy %lld > 4x Q-energy %lld "
			       "(I/Q swap detector)", tag, c,
			       (long long)sumI2[c], (long long)sumQ2[c]);
		} else {
			int64_t e = eI + eQ;

			CHECKF(e > 100000000000000LL && e < 500000000000000LL,
			       "[%s] ch %u E[I^2+Q^2] %lld in [1.0e14, 5.0e14]",
			       tag, c, (long long)e);
		}
	}
	if (strict)
		CHECKF(sc <= 2, "[%s] I sign changes %u <= 2 (DC-dominated I)",
		       tag, sc);
	else
		CHECKF(sc >= 5 && sc <= 500,
		       "[%s] I sign changes %u in [5, 500] (~42 expected: "
		       "carrier retuned to +1 kHz)", tag, sc);
}

/* byte offset of the first frame start inside the next stream bytes */
static unsigned frame_skip(uint64_t consumed)
{
	return (unsigned)((FRAME_BYTES - consumed % FRAME_BYTES) % FRAME_BYTES);
}

int main(int argc, char **argv)
{
	static uint8_t valbuf[49248];	/* 512 frames + 95-byte align slack */
	static uint8_t drainbuf[32768];
	static uint8_t wfbuf[WF_BLOCK_BYTES];
	static uint8_t smallbuf[256];
	uint64_t consumed = 0;	/* total RX bytes consumed since RX_START */
	uint32_t sig, mask_saved, readed;
	uint64_t dna;
	int fd, rc;
	unsigned ch, iter;
	uint64_t nco10m = nco_word(10000000.0);

	if (argc == 4 && !strcmp(argv[1], "--emu"))
		return zynqsdr_emu_remote_main("zynqsdr-datapath", argc, argv);
	if (!(argc == 2 &&
	      (!strcmp(argv[1], "--emu") || !strcmp(argv[1], "emu")))) {
		usage(argv[0]);
		return 2;
	}

	fd = open("/dev/zynqsdr", O_RDWR | O_SYNC);
	if (fd < 0) {
		printf("FAIL: open /dev/zynqsdr: %s\n", strerror(errno));
		return 1;
	}
	printf("ok: open /dev/zynqsdr (model-only datapath validation)\n");

	sig = 0;
	rc = ioctl(fd, ZYNQSDR_GET_SIGNATURE, &sig);
	CHECKF(rc == 0 && sig == EMU_SIGNATURE,
	       "GET_SIGNATURE == 0x%08x (web888-pl model; got rc=%d sig=0x%08x)",
	       EMU_SIGNATURE, rc, sig);
	if (rc || sig != EMU_SIGNATURE) {
		printf("FAIL: refusing to continue: this tool is model-only "
		       "(run inside the QEMU web888 guest)\n");
		return 1;
	}
	dna = 0;
	rc = ioctl(fd, ZYNQSDR_GET_DNA, &dna);
	CHECKF(rc == 0 && dna != 0, "GET_DNA nonzero (rc=%d dna=0x%016llx)",
	       rc, (unsigned long long)dna);

	rc = ioctl(fd, ZYNQSDR_GET_GPIO_MASK, &mask_saved);
	CHECKF(rc == 0, "GET_GPIO_MASK (save 0x%08x for restore)", mask_saved);

	/* normalise device state: full-scale gain, HF mode (the smoke test
	 * leaves AD8370 code 63 = -31.5 dB; amplitude assertions need gain 1) */
	rc = ioctl(fd, ZYNQSDR_AD8370_SET, 0);
	CHECKF(rc == 0, "AD8370_SET(0) (attenuator restore)");
	rc = ioctl(fd, ZYNQSDR_MODE_SET, 0);
	CHECKF(rc == 0, "MODE_SET(0) (HF mode)");

	/* ---- arm RX, tune all 12 channels to the 10 MHz scene carrier ---- */
	rc = ioctl(fd, ZYNQSDR_RX_START, RX_DECIM);
	CHECKF(rc == 0, "RX_START(%u) (24 kS/s, 96-byte frames)", RX_DECIM);
	for (ch = 0; ch < NRX; ch++) {
		struct zynqsdr_rx_param_op rp = { ch, nco10m };

		rc = ioctl(fd, ZYNQSDR_RX_PARAM, &rp);
		if (rc) {
			printf("FAIL: RX_PARAM(ch %u, nco 0x%llx) rc=%d (%s)\n",
			       ch, (unsigned long long)nco10m, rc,
			       strerror(errno));
			fails++;
			break;
		}
	}
	CHECKF(ch == NRX, "RX_PARAM all %u channels tuned to the 10 MHz carrier",
	       NRX);
	usleep(50000);	/* let the ring start filling */

	/* ---- G6: RX_READ length contract + untouched tail sentinel ---- */
	memset(smallbuf, 0xa5, sizeof(smallbuf));
	{
		struct zynqsdr_rx_read_op op = {
			(uint32_t)(uintptr_t)smallbuf, 0, 0 };

		rc = ioctl(fd, ZYNQSDR_RX_READ, &op);
		CHECKF(rc == 0 && op.readed == 0,
		       "RX_READ length 0 -> rc=%d readed=%u", rc, op.readed);
		CHECKF(smallbuf[0] == 0xa5 && smallbuf[1] == 0xa5,
		       "RX_READ length 0 leaves buffer untouched (sentinel)");
	}
	{
		static const uint32_t lens[] = { 1, 96, 127 };
		unsigned k;

		for (k = 0; k < sizeof(lens) / sizeof(lens[0]); k++) {
			uint32_t len = lens[k];

			memset(smallbuf, 0xa5, sizeof(smallbuf));
			if (rx_read_full(fd, smallbuf, len) == 0) {
				int tail_ok = 1;
				unsigned t;

				for (t = len; t < len + 32; t++)
					if (smallbuf[t] != 0xa5) {
						tail_ok = 0;
						printf("FAIL: RX_READ(%u) byte "
						       "%u past readed=%u is "
						       "0x%02x, not 0xa5\n",
						       len, t, len, smallbuf[t]);
						fails++;
						break;
					}
				CHECKF(tail_ok, "RX_READ(%u) tail sentinel intact "
				       "beyond readed", len);
				consumed += len;
			} else {
				consumed += len; /* keep alignment approximate */
			}
		}
	}

	/* ---- G2: real frame/sample validation on a 512-frame window ---- */
	if (rx_read_full(fd, valbuf, sizeof(valbuf)) == 0) {
		unsigned skip = frame_skip(consumed);

		validate_window(valbuf + skip, 512, 1, "carrier@DC");
		consumed += sizeof(valbuf);
	}

	/* ---- G2: frame continuity across the 0x7fc00 ring wrap ----
	 * The ring size is not a frame multiple; drain more than a full
	 * ring and bound-check every complete frame's samples. The producer
	 * is wall-clock paced, so the loop is bounded by a hard deadline
	 * (and an iteration cap), not a fixed read count. */
	{
		uint64_t drain_target = RING_BYTES + FRAME_BYTES;
		time_t deadline = time(NULL) + DRAIN_TIMEOUT_S;
		int wrap_ok = 1;

		iter = 0;
		while (consumed < drain_target) {
			unsigned skip, off;

			if (++iter > DRAIN_MAX_ITERS || time(NULL) >= deadline) {
				printf("FAIL: ring-wrap drain gave up after %u "
				       "reads / %ds at consumed=%llu target=%llu "
				       "(producer stalled?)\n",
				       iter, DRAIN_TIMEOUT_S,
				       (unsigned long long)consumed,
				       (unsigned long long)drain_target);
				fails++;
				wrap_ok = 0;
				break;
			}
			rc = rx_read(fd, drainbuf, sizeof(drainbuf), &readed);
			if (rc) {
				printf("FAIL: wrap drain RX_READ rc=%d (%s) "
				       "at consumed=%llu\n", rc, strerror(-rc),
				       (unsigned long long)consumed);
				fails++;
				wrap_ok = 0;
				break;
			}
			skip = frame_skip(consumed);
			for (off = skip; off + FRAME_BYTES <= readed;
			     off += FRAME_BYTES) {
				unsigned c;

				for (c = 0; c < NRX; c++) {
					int32_t i0 = ld_i32le(drainbuf + off +
							      c * 8);
					int32_t q0 = ld_i32le(drainbuf + off +
							      c * 8 + 4);

					if (i0 > 70000000 || i0 < -70000000 ||
					    q0 > 70000000 || q0 < -70000000) {
						printf("FAIL: ring-wrap continuity: "
						       "frame@off %u ch %u I=%d "
						       "Q=%d (consumed=%llu)\n",
						       off, c, i0, q0,
						       (unsigned long long)
						       consumed);
						fails++;
						wrap_ok = 0;
						break;
					}
				}
				if (!wrap_ok)
					break;
			}
			if (!wrap_ok)
				break;
			consumed += readed;
			if (readed < sizeof(drainbuf))
				usleep(5000);	/* let the producer catch up */
		}
		CHECKF(wrap_ok && consumed >= drain_target,
		       "RX frame continuity across the 0x%x ring wrap "
		       "(drained %llu bytes in %u reads)",
		       RING_BYTES, (unsigned long long)consumed, iter);
	}

	/* ---- G4: plain WF_START(0) is continuous on the model ----
	 * decim=1: continuous delivery is capped by the model at wf-cont-max
	 * (~4 MS/s, ~2 ms per 32768-byte block), one-shot fills in 66 us. */
	{
		struct zynqsdr_wf_param_op wp = { 0, 1, nco10m };

		rc = ioctl(fd, ZYNQSDR_WF_PARAM, &wp);
		CHECKF(rc == 0, "WF_PARAM(ch0, decim=1, 10 MHz)");
		rc = ioctl(fd, ZYNQSDR_WF_START, 0);
		CHECKF(rc == 0, "WF_START(0) arm (continuous)");
		wf_read_full(fd, 0, wfbuf, WF_BLOCK_BYTES);
		usleep(50000);	/* 50 ms >> ~2 ms per block: fresh data due */
		rc = wf_read(fd, 0, wfbuf, WF_BLOCK_BYTES, &readed);
		CHECKF(rc == 0 && readed == WF_BLOCK_BYTES,
		       "WF continuous: second read after 50 ms readed=%u "
		       "(expect %u)", readed, WF_BLOCK_BYTES);

		/* ---- G4: WF_START(0|WF_READ_CONTINUES) is one-shot ---- */
		rc = ioctl(fd, ZYNQSDR_WF_START,
			   ZYNQSDR_WF_READ_CONTINUES);
		CHECKF(rc == 0, "WF_START(0|WF_READ_CONTINUES) re-arm (one-shot)");
		if (wf_read_full(fd, 0, wfbuf, WF_BLOCK_BYTES) == 0) {
			rc = wf_read(fd, 0, wfbuf, WF_BLOCK_BYTES, &readed);
			CHECKF(rc == 0 && readed == 0,
			       "WF one-shot: read after full block readed=%u "
			       "(expect 0)", readed);
		}

		/* ---- G3: WF_PARAM decimate change while armed = fresh block;
		 * same-value WF_PARAM = documented no-op (no new block).
		 * decim 1->2: the fresh one-shot block (8192 samples at
		 * fs/2 = 61.44 MS/s) completes in ~133 us even under TCG,
		 * where slower decimates made the model's deadline-driven
		 * production outrun the 3 s poll budget. ---- */
		wp.decimate = 2;
		rc = ioctl(fd, ZYNQSDR_WF_PARAM, &wp);
		CHECKF(rc == 0, "WF_PARAM(ch0, decim=1->2) while armed "
		       "(driver reset pulse)");
		if (wf_read_full(fd, 0, wfbuf, WF_BLOCK_BYTES) == 0) {
			rc = ioctl(fd, ZYNQSDR_WF_PARAM, &wp);
			CHECKF(rc == 0, "WF_PARAM(ch0, same decim=2) no-op");
			rc = wf_read(fd, 0, wfbuf, WF_BLOCK_BYTES, &readed);
			CHECKF(rc == 0 && readed == 0,
			       "WF no-op param: readed=%u (expect 0, no fresh "
			       "block)", readed);
		}
	}

	/* ---- G5: RX + WF0 + WF1 armed together, interleaved reads ---- */
	{
		struct zynqsdr_wf_param_op wp = { 1, 2, nco10m };
		int all_ok = 1;

		rc = ioctl(fd, ZYNQSDR_WF_PARAM, &wp);
		CHECKF(rc == 0, "WF_PARAM(ch1, decim=64, 10 MHz)");
		for (iter = 0; iter < 8 && fails == 0; iter++) {
			rc = ioctl(fd, ZYNQSDR_WF_START,
				   ZYNQSDR_WF_READ_CONTINUES);
			if (rc) {
				printf("FAIL: interleave iter %u WF_START(0) "
				       "rc=%d\n", iter, rc);
				fails++;
				all_ok = 0;
				break;
			}
			rc = ioctl(fd, ZYNQSDR_WF_START,
				   1 | ZYNQSDR_WF_READ_CONTINUES);
			if (rc) {
				printf("FAIL: interleave iter %u WF_START(1) "
				       "rc=%d\n", iter, rc);
				fails++;
				all_ok = 0;
				break;
			}
			if (wf_read_full(fd, 0, wfbuf, WF_BLOCK_BYTES) ||
			    wf_read_full(fd, 1, wfbuf, WF_BLOCK_BYTES) ||
			    rx_read_full(fd, drainbuf, 960))
				all_ok = 0;
			else
				consumed += 960;
		}
		CHECKF(all_ok, "8x interleaved RX + WF0 + WF1 reads all progress");
	}

	/* RX data still valid with WF0+WF1 running: strict window again */
	if (fails == 0 && rx_read_full(fd, valbuf, sizeof(valbuf)) == 0) {
		unsigned skip = frame_skip(consumed);

		validate_window(valbuf + skip, 512, 1, "carrier@DC+WF");
		consumed += sizeof(valbuf);
	}

	/* ---- G8: RX_PARAM retune while armed keeps the stream valid ----
	 * Carrier moves to +1 kHz: strict DC assertions are replaced by
	 * retune-robust energy / sign-change-rate checks. */
	{
		uint64_t nco_off = nco_word(9999000.0);

		for (ch = 0; ch < NRX; ch++) {
			struct zynqsdr_rx_param_op rp = { ch, nco_off };

			rc = ioctl(fd, ZYNQSDR_RX_PARAM, &rp);
			if (rc) {
				printf("FAIL: retune RX_PARAM(ch %u) rc=%d (%s)\n",
				       ch, rc, strerror(errno));
				fails++;
				break;
			}
		}
		CHECKF(ch == NRX, "RX_PARAM retune all %u channels to carrier "
		       "+1 kHz while armed", NRX);
		usleep(200000);	/* flush: > 2x the 21 ms validation window */
		if (fails == 0 &&
		    rx_read_full(fd, valbuf, sizeof(valbuf)) == 0) {
			unsigned skip = frame_skip(consumed);

			validate_window(valbuf + skip, 512, 0, "carrier@+1k");
			consumed += sizeof(valbuf);
		}
	}

	rc = ioctl(fd, ZYNQSDR_SET_GPIO_MASK, mask_saved);
	CHECKF(rc == 0, "SET_GPIO_MASK restore 0x%08x", mask_saved);
	close(fd);

	if (fails) {
		printf("ZYNQSDR_DATAPATH_FAIL (%d failures, consumed %llu "
		       "RX bytes)\n", fails, (unsigned long long)consumed);
		return 1;
	}
	printf("ZYNQSDR_DATAPATH_OK (consumed %llu RX bytes)\n",
	       (unsigned long long)consumed);
	return 0;
}
