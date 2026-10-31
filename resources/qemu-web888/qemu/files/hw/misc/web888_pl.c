/*
 * Web-888 SDR programmable-logic (PL) model.
 *
 * Models the register contract of the Web-888 FPGA as used by the stock
 * `zynqsdr` kernel driver and by the open web888-ng bitstream
 * (see hw/fpga/doc/register-map.md in web888-ng-hw):
 *
 *   CFG  @ 0x40000000  read/write, byte/halfword/unaligned access
 *   STS  @ 0x41000000  read only
 *   PPS  @ 0x42000000  read pops the PPS period FIFO
 *
 * Instead of an ADC and DDC chain the model synthesises the samples a
 * channel would produce for a configurable scene of real tones (and white
 * noise) and writes them into the guest's DMA rings in whole 128-byte
 * bursts, paced by QEMU's virtual clock:
 *
 *   RX: NRX channels, frame = NRX x {I s32, Q s32}, rate fs/(256*R2),
 *       full-scale real sine -> |I+jQ| = 2^29, CIC1 N=3 R=256 and
 *       CIC2 N=5 R=R2 magnitude response applied per line.
 *   WF: 2 slots, {I s16, Q s16}, rate fs/R, full-scale sine -> 2^14,
 *       CIC N=5 R; one-shot (8192 samples, CFG 0x9e bit set) or continuous ring.
 *
 * Mixing is x * exp(-j w n): a tone at f_nco + d appears at +d.
 *
 * Copyright (c) 2026 web888-ng contributors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "qemu/timer.h"
#include "qapi/error.h"
#include "hw/core/irq.h"
#include "hw/core/sysbus.h"
#include "hw/core/qdev-properties.h"
#include "migration/vmstate.h"
#include "system/address-spaces.h"
#include "system/memory.h"
#include "hw/misc/web888_pl.h"

#include <math.h>

#define BURST 128
#define MASK48 ((1ULL << 48) - 1)
#define TWO48 281474976710656.0
#define RX_SINE_FS 536870912.0      /* 2^29 */
#define WF_SINE_FS 16384.0          /* 2^14 */
#define WF_ONESHOT_SAMPLES 8192

/*
 * Default scene: an AM carrier with 1 kHz tone at 10 MHz, a weak carrier
 * at 7.074 MHz, beacons at 14.2 and 15 MHz, over a -150 dBFS/Hz floor.
 */
#define WEB888_DEFAULT_SCENE \
    "10000000:-30:1000:0.5,7074000:-50,14200000:-60,15000000:-40"
#define WEB888_DEFAULT_NOISE "-150"

/* CFG offsets */
#define CFG_CTRL      0x00
#define CFG_R2        0x02
#define CFG_RX_NCO    0x04
#define CFG_WF0_NCO   0x6C
#define CFG_WF0_DEC   0x74
#define CFG_WF1_NCO   0x78
#define CFG_WF1_DEC   0x80
#define CFG_GPIO      0x84
#define CFG_RX_ADDR   0x8C
#define CFG_RX_LEN    0x90
#define CFG_WF0_ADDR  0x92
#define CFG_WF0_LEN   0x96
#define CFG_WF1_ADDR  0x98
#define CFG_WF1_LEN   0x9C
#define CFG_WF_MODE   0x9E

#define CTRL_RX   (1 << 0)
#define CTRL_WF0  (1 << 1)
#define CTRL_WF1  (1 << 2)
#define CTRL_PPS  (1 << 7)

static const uint32_t wf_nco_off[WEB888_NWF] = { CFG_WF0_NCO, CFG_WF1_NCO };
static const uint32_t wf_dec_off[WEB888_NWF] = { CFG_WF0_DEC, CFG_WF1_DEC };
static const uint32_t wf_addr_off[WEB888_NWF] = { CFG_WF0_ADDR, CFG_WF1_ADDR };
static const uint32_t wf_len_off[WEB888_NWF] = { CFG_WF0_LEN, CFG_WF1_LEN };

/* ------------------------------------------------------------------ util */

static uint64_t cfg_get(Web888PLState *s, unsigned off, unsigned size)
{
    uint64_t v = 0;
    for (unsigned i = 0; i < size; i++) {
        if (off + i < WEB888_CFG_BYTES) {
            v |= (uint64_t)s->cfg[off + i] << (8 * i);
        }
    }
    return v;
}

static uint64_t rng_next(Web888PLState *s)
{
    /* xorshift64* */
    uint64_t x = s->rng;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    s->rng = x;
    return x * 0x2545F4914F6CDD1DULL;
}

static double rng_uniform(Web888PLState *s)
{
    return ((rng_next(s) >> 11) + 0.5) * (1.0 / 9007199254740992.0);
}

static void rng_gauss2(Web888PLState *s, double *a, double *b)
{
    double u1 = rng_uniform(s), u2 = rng_uniform(s);
    double r = sqrt(-2.0 * log(u1));
    *a = r * cos(2.0 * M_PI * u2);
    *b = r * sin(2.0 * M_PI * u2);
}

static double cic_mag(double f, double fs_in, double r, int n)
{
    double x = M_PI * f / fs_in;
    double den = r * sin(x);
    if (fabs(den) < 1e-300) {
        return 1.0;
    }
    return pow(fabs(sin(x * r) / den), n);
}

static double fold(double d, double fs)
{
    double h = fs / 2.0;
    double y = fmod(d + h, fs);
    if (y < 0) {
        y += fs;
    }
    return y - h;
}

static int32_t q32(double x)
{
    x = round(x);
    if (x > 2147483647.0) {
        return INT32_MAX;
    }
    if (x < -2147483648.0) {
        return INT32_MIN;
    }
    return (int32_t)x;
}

static int16_t q16(double x)
{
    x = round(x);
    if (x > 32767.0) {
        return INT16_MAX;
    }
    if (x < -32768.0) {
        return INT16_MIN;
    }
    return (int16_t)x;
}

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = v;
    p[1] = v >> 8;
    p[2] = v >> 16;
    p[3] = v >> 24;
}

/* ------------------------------------------------------------- channels */

static void chan_build(Web888PLState *s, Web888Chan *c, double fs_out,
                       bool is_rx, unsigned decim)
{
    double fs = s->fs;
    double f_nco = (double)(c->word & MASK48) / TWO48 * fs;
    double full = is_rx ? RX_SINE_FS : WF_SINE_FS;

    c->nlines = 0;
    for (int t = 0; t < s->ntones; t++) {
        for (int sign = 1; sign >= -1; sign -= 2) {
            double fl = sign * s->tones[t].f_hz;
            double d = fold(fl - f_nco, fs);
            double m;
            if (is_rx) {
                m = cic_mag(d, fs, 256, 3) *
                    cic_mag(d, fs / 256.0, s->r2, 5);
            } else {
                m = cic_mag(d, fs, decim, 5);
            }
            if (m < 1e-9) {
                continue;
            }
            double amp = full * pow(10.0, s->tones[t].dbfs / 20.0) * m *
                         s->gain;
            double w = 2.0 * M_PI * d / fs_out;
            Web888Line *l = &c->lines[c->nlines++];
            l->pr = amp;
            l->pi = 0;
            l->rr = cos(w);
            l->ri = sin(w);
            l->amp = amp;
        }
    }
}

static inline void chan_step(Web888Chan *c, double *re, double *im)
{
    double zr = 0, zi = 0;
    for (int i = 0; i < c->nlines; i++) {
        Web888Line *l = &c->lines[i];
        zr += l->pr;
        zi += l->pi;
        double nr = l->pr * l->rr - l->pi * l->ri;
        double ni = l->pr * l->ri + l->pi * l->rr;
        l->pr = nr;
        l->pi = ni;
    }
    *re = zr;
    *im = zi;
}

static void chan_renorm(Web888Chan *c)
{
    for (int i = 0; i < c->nlines; i++) {
        Web888Line *l = &c->lines[i];
        double m = hypot(l->pr, l->pi);
        if (m > 0) {
            l->pr *= l->amp / m;
            l->pi *= l->amp / m;
        }
    }
}

static double noise_sigma(Web888PLState *s, double fs_out, double full)
{
    if (!s->has_noise) {
        return 0;
    }
    return sqrt(pow(10.0, s->noise_dbfs_hz / 10.0) * fs_out / 2.0) * full;
}

static double rx_rate(Web888PLState *s)
{
    return s->fs / (256.0 * s->r2);
}

static void rx_rebuild(Web888PLState *s, int ch)
{
    s->rxch[ch].word = cfg_get(s, CFG_RX_NCO + 8 * ch, 8) & MASK48;
    chan_build(s, &s->rxch[ch], rx_rate(s), true, 0);
}

static void wf_rebuild(Web888PLState *s, int n)
{
    unsigned d = cfg_get(s, wf_dec_off[n], 2);
    if (d == 0) {
        d = 1;
    }
    s->wf_decim[n] = d;
    s->wfch[n].word = cfg_get(s, wf_nco_off[n], 8) & MASK48;
    chan_build(s, &s->wfch[n], s->fs / d, false, d);
}

static void rebuild_all(Web888PLState *s)
{
    for (int ch = 0; ch < s->nrx; ch++) {
        rx_rebuild(s, ch);
    }
    for (int n = 0; n < WEB888_NWF; n++) {
        wf_rebuild(s, n);
    }
}

/* -------------------------------------------------------------- streams */

static void stream_start(Web888Stream *st, uint32_t addr, uint32_t len_m1,
                         double fs_out, uint64_t limit)
{
    st->run = true;
    st->addr = addr & ~(BURST - 1);
    st->nbursts = len_m1 + 1;
    st->ptr = 0;
    st->bytes = 0;
    st->samples = 0;
    st->limit = limit;
    st->oneshot = limit != 0;
    st->t0_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    st->fs_out = fs_out;
    st->frames = 0;
    st->drops = 0;
    st->bursts = 0;
    st->ovf = false;
    st->bresp_err = false;
    st->carry_len = 0;
}

/*
 * Append bytes to a stream; whole bursts go to guest memory, the
 * remainder waits in the carry buffer. Returns the bursts written.
 */
static uint32_t stream_put(Web888Stream *st, const uint8_t *buf, size_t len)
{
    uint32_t done = 0;

    while (len) {
        size_t n = MIN(len, BURST - st->carry_len);
        memcpy(st->carry + st->carry_len, buf, n);
        st->carry_len += n;
        buf += n;
        len -= n;
        if (st->carry_len == BURST) {
            hwaddr a = st->addr + (hwaddr)st->ptr * BURST;
            MemTxResult r = address_space_write(&address_space_memory, a,
                                                MEMTXATTRS_UNSPECIFIED,
                                                st->carry, BURST);
            if (r != MEMTX_OK) {
                st->bresp_err = true;
            }
            st->carry_len = 0;
            st->ptr = (st->ptr + 1) % st->nbursts;
            st->bursts++;
            done++;
        }
        st->bytes += n;
    }
    return done;
}

/* Samples due on a stream at time `now` (bounded). */
static uint64_t stream_due(Web888Stream *st, int64_t now, uint64_t max)
{
    double t = (now - st->t0_ns) * 1e-9;
    uint64_t due = t > 0 ? (uint64_t)(t * st->fs_out) : 0;
    uint64_t n;

    if (st->limit && due > st->limit) {
        due = st->limit;
    }
    n = due > st->samples ? due - st->samples : 0;
    if (n > max) {
        /* reader of the ring can't have kept up anyway: skip time */
        st->drops += n - max;
        st->ovf = true;
        st->samples += n - max;
        n = max;
    }
    return n;
}

#define CHUNK_FRAMES 256

static void rx_produce(Web888PLState *s, int64_t now)
{
    Web888Stream *st = &s->rx;
    unsigned fb = 8 * s->nrx;
    uint64_t ring_frames = (uint64_t)st->nbursts * BURST / fb;
    uint64_t n = stream_due(st, now, ring_frames);
    double sigma = noise_sigma(s, st->fs_out, RX_SINE_FS);
    uint8_t buf[CHUNK_FRAMES * 8 * WEB888_MAX_RX];
    uint32_t bursts = 0;

    while (n) {
        unsigned k = MIN(n, CHUNK_FRAMES);
        uint8_t *p = buf;
        for (unsigned f = 0; f < k; f++) {
            for (int ch = 0; ch < s->nrx; ch++) {
                double re, im;
                chan_step(&s->rxch[ch], &re, &im);
                if (sigma > 0) {
                    double a, b;
                    rng_gauss2(s, &a, &b);
                    re += a * sigma;
                    im += b * sigma;
                }
                put32(p, q32(re));
                put32(p + 4, q32(im));
                p += 8;
            }
            st->samples++;
            st->frames++;
            if ((st->samples & 4095) == 0) {
                for (int ch = 0; ch < s->nrx; ch++) {
                    chan_renorm(&s->rxch[ch]);
                }
            }
        }
        bursts += stream_put(st, buf, p - buf);
        n -= k;
    }
    if (bursts) {
        qemu_irq_pulse(s->irq[0]);
    }
}

static void wf_produce(Web888PLState *s, int w, int64_t now)
{
    Web888Stream *st = &s->wf[w];
    Web888Chan *c = &s->wfch[w];
    uint64_t max = (uint64_t)st->nbursts * BURST / 4;
    uint64_t n;
    double sigma = noise_sigma(s, st->fs_out, WF_SINE_FS);
    uint8_t buf[4 * 1024];
    uint32_t bursts = 0;

    if (!st->oneshot && s->wf_cont_max && st->fs_out > s->wf_cont_max) {
        /*
         * Continuous streaming faster than the HP port / CPU could take:
         * only deliver at the capped rate and flag an overflow.
         */
        max = MIN(max, (uint64_t)(s->wf_cont_max * (s->tick_us * 1e-6)) + 1);
    }
    n = stream_due(st, now, max);
    while (n) {
        unsigned k = MIN(n, sizeof(buf) / 4);
        uint8_t *p = buf;
        for (unsigned i = 0; i < k; i++) {
            double re, im;
            chan_step(c, &re, &im);
            if (sigma > 0) {
                double a, b;
                rng_gauss2(s, &a, &b);
                re += a * sigma;
                im += b * sigma;
            }
            uint16_t ii = q16(re), qq = q16(im);
            put32(p, ii | ((uint32_t)qq << 16));
            p += 4;
            st->samples++;
            if ((st->samples & 4095) == 0) {
                chan_renorm(c);
            }
        }
        bursts += stream_put(st, buf, p - buf);
        n -= k;
    }
    if (bursts) {
        qemu_irq_pulse(s->irq[1 + w]);
    }
    if (st->oneshot && st->samples >= st->limit) {
        st->run = false;     /* one block done */
    }
}

/* ------------------------------------------------------------------ PPS */

static void pps_push(Web888PLState *s, uint32_t v)
{
    if (s->pps_count < WEB888_PPS_DEPTH) {
        s->pps_fifo[(s->pps_head + s->pps_count) % WEB888_PPS_DEPTH] = v;
        s->pps_count++;
    }
    s->pps_last = v;
}

static void pps_update(Web888PLState *s, int64_t now)
{
    if (!s->pps_present) {
        return;
    }
    if (s->pps_level && now >= s->pps_low_ns) {
        s->pps_level = false;
        qemu_set_irq(s->pps_out, 0);
    }
    while (now >= s->pps_next_ns) {
        /* rising PPS edge */
        s->pps_level = true;
        s->pps_low_ns = s->pps_next_ns + 100 * SCALE_MS;
        qemu_set_irq(s->pps_out, 1);
        qemu_irq_pulse(s->irq[3]);
        if (s->pps_en) {
            if (s->pps_armed) {
                pps_push(s, (uint32_t)llround(s->fs));
            }
            s->pps_armed = true;
        }
        s->pps_next_ns += NANOSECONDS_PER_SECOND;
    }
}

/* -------------------------------------------------------------- engine */

static void pl_update(Web888PLState *s)
{
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    if (s->rx.run) {
        rx_produce(s, now);
    }
    for (int w = 0; w < WEB888_NWF; w++) {
        if (s->wf[w].run) {
            wf_produce(s, w, now);
        }
    }
    pps_update(s, now);
}

static void pl_schedule(Web888PLState *s)
{
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    int64_t next = now + (int64_t)s->tick_us * 1000;

    for (int w = 0; w < WEB888_NWF; w++) {
        Web888Stream *st = &s->wf[w];
        if (st->run && st->oneshot) {
            /* wake up right when the one-shot block is complete */
            int64_t end = st->t0_ns + (int64_t)(st->limit / st->fs_out * 1e9)
                          + 1000;
            if (end > now && end < next) {
                next = end;
            }
        }
    }
    if (s->pps_present) {
        int64_t e = s->pps_level ? s->pps_low_ns : s->pps_next_ns;
        if (e < next) {
            next = MAX(e, now + 1000);
        }
    }
    timer_mod(s->timer, next);
}

static void pl_tick(void *opaque)
{
    Web888PLState *s = opaque;
    pl_update(s);
    pl_schedule(s);
}

static void ctrl_changed(Web888PLState *s, uint16_t old, uint16_t ctrl)
{
    uint16_t rise = ctrl & ~old, fall = old & ~ctrl;

    pl_update(s);       /* finish what was due under the old settings */

    if (fall & CTRL_RX) {
        s->rx.run = false;
    }
    if (rise & CTRL_RX) {
        uint16_t r2 = cfg_get(s, CFG_R2, 2);
        s->r2 = r2 ? MIN(r2, 63) : 1;
        stream_start(&s->rx, cfg_get(s, CFG_RX_ADDR, 4),
                     cfg_get(s, CFG_RX_LEN, 2), rx_rate(s), 0);
        /* test hook: start STS 0x38 near its wrap */
        s->rx.bursts = s->rx_bursts_start;
        for (int ch = 0; ch < s->nrx; ch++) {
            rx_rebuild(s, ch);
        }
        if (s->log_regs) {
            qemu_log("web888-pl: RX start ring 0x%08x bursts %u r2 %u "
                     "(%.1f S/s, %d ch)\n", s->rx.addr, s->rx.nbursts,
                     s->r2, s->rx.fs_out, s->nrx);
        }
    }
    for (int w = 0; w < WEB888_NWF; w++) {
        uint16_t bit = w ? CTRL_WF1 : CTRL_WF0;
        if (fall & bit) {
            s->wf[w].run = false;
        }
        if (rise & bit) {
            /* CFG 0x9e bit n: 1 = one-shot (plain WF_START), 0 = continuous */
            bool cont = !(cfg_get(s, CFG_WF_MODE, 2) & (1u << w));
            wf_rebuild(s, w);
            stream_start(&s->wf[w], cfg_get(s, wf_addr_off[w], 4),
                         cfg_get(s, wf_len_off[w], 2),
                         s->fs / s->wf_decim[w],
                         cont ? 0 : WF_ONESHOT_SAMPLES);
            if (s->log_regs) {
                qemu_log("web888-pl: WF%d start ring 0x%08x decim %u %s\n",
                         w, s->wf[w].addr, s->wf_decim[w],
                         cont ? "continuous" : "one-shot");
            }
        }
    }
    if (fall & CTRL_PPS) {
        s->pps_en = false;
        s->pps_armed = false;
    }
    if (rise & CTRL_PPS) {
        s->pps_en = true;
        s->pps_armed = false;
        s->pps_count = 0;
        s->pps_head = 0;
    }
    pl_schedule(s);
}

/* ------------------------------------------------------------------ MMIO */

static uint64_t cfg_read(void *opaque, hwaddr addr, unsigned size)
{
    Web888PLState *s = opaque;
    return cfg_get(s, addr, size);
}

static void cfg_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
    Web888PLState *s = opaque;
    uint16_t old = cfg_get(s, CFG_CTRL, 2);

    if (s->log_regs) {
        qemu_log("web888-pl: cfg[0x%02x] <- 0x%" PRIx64 " (%u)\n",
                 (unsigned)addr, val, size);
    }
    if (addr >= WEB888_CFG_BYTES) {
        return;
    }
    /* stage the write: let due samples finish with the old parameters */
    if (s->rx.run || s->wf[0].run || s->wf[1].run) {
        pl_update(s);
    }
    for (unsigned i = 0; i < size && addr + i < WEB888_CFG_BYTES; i++) {
        s->cfg[addr + i] = val >> (8 * i);
    }

    hwaddr end = addr + size;
    /* RX NCO words: retune on the fly */
    for (int ch = 0; ch < s->nrx; ch++) {
        hwaddr o = CFG_RX_NCO + 8 * ch;
        if (addr < o + 8 && end > o) {
            rx_rebuild(s, ch);
        }
    }
    for (int w = 0; w < WEB888_NWF; w++) {
        hwaddr o = wf_nco_off[w];
        if (addr < o + 12 && end > o) {
            unsigned d_old = s->wf_decim[w];
            wf_rebuild(s, w);
            if (s->wf[w].run && s->wf_decim[w] != d_old) {
                /* new rate: restart the timebase, keep the ring position */
                s->wf[w].fs_out = s->fs / s->wf_decim[w];
                s->wf[w].t0_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
                s->wf[w].samples = 0;
            }
        }
    }
    if (addr < CFG_CTRL + 2) {
        uint16_t ctrl = cfg_get(s, CFG_CTRL, 2);
        if (ctrl != old) {
            ctrl_changed(s, old, ctrl);
        }
    }
}

static uint32_t sts_word(Web888PLState *s, unsigned w)
{
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    switch (w) {
    case 0x00 / 4:
        return s->signature;
    case 0x04 / 4:
        return (s->rx.ptr & 0xffff) | (s->wf[0].ptr & 0xffff) << 16;
    case 0x08 / 4:
        return (s->wf[1].ptr & 0xffff) | (s->pps_count & 0xffff) << 16;
    case 0x0C / 4:
        return s->dna & 0xffffffff;
    case 0x10 / 4:
        return (s->dna >> 32) & 0x1ffffff;
    case 0x14 / 4:
        return s->pps_last;
    case 0x18 / 4:
        return s->build_id;
    case 0x1C / 4:
        return 0;                       /* ADC overflow counter */
    case 0x20 / 4: {
        uint32_t f = 0;
        f |= s->rx.ovf ? 1 << 0 : 0;
        f |= s->wf[0].ovf ? 1 << 1 : 0;
        f |= s->wf[1].ovf ? 1 << 2 : 0;
        f |= s->rx.bresp_err ? 1 << 4 : 0;
        f |= s->wf[0].bresp_err ? 1 << 5 : 0;
        f |= s->wf[1].bresp_err ? 1 << 6 : 0;
        f |= 1 << 8;                    /* PLL locked */
        f |= 1 << 9;                    /* DNA valid */
        f |= s->rx.run ? 1 << 10 : 0;
        f |= s->wf[0].run ? 1 << 11 : 0;
        f |= s->wf[1].run ? 1 << 12 : 0;
        return f;
    }
    case 0x24 / 4: {
        double a = 0;
        for (int t = 0; t < s->ntones; t++) {
            a += pow(10.0, s->tones[t].dbfs / 20.0);
        }
        a *= 32767.0 * s->gain;
        return a > 32767 ? 32767 : (uint32_t)a;
    }
    case 0x28 / 4:
    case 0x2C / 4: {
        uint64_t c = (uint64_t)((now - s->boot_ns) * 1e-9 * s->fs);
        return w == 0x28 / 4 ? (uint32_t)c : (uint32_t)(c >> 32);
    }
    case 0x30 / 4:
        return s->rx.frames;
    case 0x34 / 4:
        return s->rx.drops;
    case 0x38 / 4:
        return s->rx.bursts;
    case 0x3C / 4:
        return (s->wf[0].bursts & 0xffff) | (s->wf[1].bursts & 0xffff) << 16;
    default:
        return 0;
    }
}

static uint64_t sts_read(void *opaque, hwaddr addr, unsigned size)
{
    Web888PLState *s = opaque;
    uint64_t v = 0;

    if (addr >= 0x04 && addr < 0x0C) {
        /* pointer poll: bring the rings up to date first */
        pl_update(s);
    }
    for (unsigned i = 0; i < size; i++) {
        hwaddr a = addr + i;
        if (a < WEB888_STS_BYTES) {
            uint32_t w = sts_word(s, a / 4);
            v |= (uint64_t)((w >> (8 * (a & 3))) & 0xff) << (8 * i);
        }
    }
    return v;
}

static void sts_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
    qemu_log_mask(LOG_GUEST_ERROR, "web888-pl: write to STS 0x%x ignored\n",
                  (unsigned)addr);
}

static uint64_t pps_read(void *opaque, hwaddr addr, unsigned size)
{
    Web888PLState *s = opaque;
    uint32_t v = 0;

    pl_update(s);
    if (s->pps_count) {
        v = s->pps_fifo[s->pps_head];
        s->pps_head = (s->pps_head + 1) % WEB888_PPS_DEPTH;
        s->pps_count--;
    }
    return v;
}

static void pps_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
}

static const MemoryRegionOps cfg_ops = {
    .read = cfg_read,
    .write = cfg_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8, .unaligned = true },
    .impl = { .min_access_size = 1, .max_access_size = 8, .unaligned = true },
};

static const MemoryRegionOps sts_ops = {
    .read = sts_read,
    .write = sts_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8, .unaligned = true },
    .impl = { .min_access_size = 1, .max_access_size = 8, .unaligned = true },
};

static const MemoryRegionOps pps_ops = {
    .read = pps_read,
    .write = pps_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 4, .max_access_size = 4 },
};

/* ---------------------------------------------------------- GPIO inputs */

static void gpio_in(void *opaque, int n, int level)
{
    Web888PLState *s = opaque;
    bool old = s->gpio_in[n];

    s->gpio_in[n] = level;
    if (n == WEB888_GPIO_IN_ATT_LATCH && !old && level) {
        /* latch rising: the last 8 bits clocked in are the code */
        if (s->att_bits >= 6) {
            double g;
            s->att_code = s->att_shift;
            g = pow(10.0, -(s->att_code & 0x3f) * 0.5 / 20.0);
            if (g != s->gain) {
                pl_update(s);
                s->gain = g;
                rebuild_all(s);
            }
            if (s->log_regs) {
                qemu_log("web888-pl: attenuator code 0x%02x (%.1f dB)\n",
                         s->att_code, (s->att_code & 0x3f) * 0.5);
            }
        }
        s->att_bits = 0;
        s->att_shift = 0;
    } else if (n == WEB888_GPIO_IN_ATT_CLK && !old && level) {
        s->att_shift = (s->att_shift << 1) |
                       (s->gpio_in[WEB888_GPIO_IN_ATT_DATA] ? 1 : 0);
        s->att_bits++;
    }
}

/* ---------------------------------------------------------------- setup */

static void parse_scene(Web888PLState *s, Error **errp)
{
    s->ntones = 0;
    if (!s->scene || !*s->scene) {
        return;
    }
    g_auto(GStrv) items = g_strsplit(s->scene, ",", -1);
    for (int i = 0; items[i]; i++) {
        char *it = g_strstrip(items[i]);
        if (!*it) {
            continue;
        }
        g_auto(GStrv) f = g_strsplit(it, ":", -1);
        int nf = g_strv_length(f);
        if (nf < 2 || nf > 4) {
            error_setg(errp, "web888-pl: bad scene item '%s' "
                       "(want freq:dBFS[:am_hz[:depth]])", it);
            return;
        }
        double fc = g_ascii_strtod(f[0], NULL);
        double db = g_ascii_strtod(f[1], NULL);
        int need = nf >= 3 ? 3 : 1;
        if (s->ntones + need > WEB888_MAX_TONES) {
            error_setg(errp, "web888-pl: too many tones (max %d)",
                       WEB888_MAX_TONES);
            return;
        }
        s->tones[s->ntones++] = (Web888Tone){ fc, db };
        if (nf >= 3) {
            /* AM: carrier plus two sidebands at depth/2 each */
            double fm = g_ascii_strtod(f[2], NULL);
            double depth = nf == 4 ? g_ascii_strtod(f[3], NULL) : 0.5;
            double sb = db + 20.0 * log10(depth / 2.0);
            s->tones[s->ntones++] = (Web888Tone){ fc - fm, sb };
            s->tones[s->ntones++] = (Web888Tone){ fc + fm, sb };
        }
    }
}

static void web888_pl_realize(DeviceState *dev, Error **errp)
{
    Web888PLState *s = WEB888_PL(dev);
    Error *err = NULL;

    s->nrx = s->signature & 0xf;
    if (s->nrx < 1 || s->nrx > WEB888_MAX_RX) {
        error_setg(errp, "web888-pl: signature 0x%08x: RX channel count %d "
                   "not in 1..%d", s->signature, s->nrx, WEB888_MAX_RX);
        return;
    }
    if (!s->adc_hz) {
        error_setg(errp, "web888-pl: adc-hz must be > 0");
        return;
    }
    if (!s->tick_us) {
        s->tick_us = 2000;
    }
    s->fs = s->adc_hz * (1.0 + s->adc_ppb * 1e-9);
    if (!s->scene) {
        s->scene = g_strdup(WEB888_DEFAULT_SCENE);
    }
    if (!s->noise) {
        s->noise = g_strdup(WEB888_DEFAULT_NOISE);
    }
    parse_scene(s, &err);
    if (err) {
        error_propagate(errp, err);
        return;
    }
    s->has_noise = s->noise && *s->noise;
    if (s->has_noise) {
        s->noise_dbfs_hz = g_ascii_strtod(s->noise, NULL);
    }
    s->rng = s->seed ? s->seed : 1;
    s->timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, pl_tick, s);
}

static void web888_pl_reset_hold(Object *obj, ResetType type)
{
    Web888PLState *s = WEB888_PL(obj);
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    memset(s->cfg, 0, sizeof(s->cfg));
    memset(&s->rx, 0, sizeof(s->rx));
    memset(s->wf, 0, sizeof(s->wf));
    s->r2 = 40;
    s->gain = 1.0;
    s->pps_en = false;
    s->pps_armed = false;
    s->pps_count = 0;
    s->pps_head = 0;
    s->pps_last = 0;
    s->pps_level = false;
    s->pps_next_ns = now + NANOSECONDS_PER_SECOND;
    s->boot_ns = now;
    s->att_bits = 0;
    rebuild_all(s);
    if (s->timer) {
        pl_schedule(s);
    }
}

static void web888_pl_init(Object *obj)
{
    Web888PLState *s = WEB888_PL(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->cfg_mr, obj, &cfg_ops, s, "web888.cfg",
                          WEB888_WIN_SIZE);
    memory_region_init_io(&s->sts_mr, obj, &sts_ops, s, "web888.sts",
                          WEB888_WIN_SIZE);
    memory_region_init_io(&s->pps_mr, obj, &pps_ops, s, "web888.pps",
                          WEB888_WIN_SIZE);
    sysbus_init_mmio(sbd, &s->cfg_mr);
    sysbus_init_mmio(sbd, &s->sts_mr);
    sysbus_init_mmio(sbd, &s->pps_mr);
    for (int i = 0; i < 4; i++) {
        sysbus_init_irq(sbd, &s->irq[i]);
    }
    qdev_init_gpio_out_named(DEVICE(obj), &s->pps_out, "pps", 1);
    qdev_init_gpio_in(DEVICE(obj), gpio_in, WEB888_GPIO_IN_NUM);
}

static const Property web888_pl_props[] = {
    DEFINE_PROP_UINT32("signature", Web888PLState, signature, 0x0E5D020C),
    DEFINE_PROP_UINT64("dna", Web888PLState, dna, 0x0123456789ABCDULL),
    DEFINE_PROP_UINT32("build-id", Web888PLState, build_id, 0x20261016),
    DEFINE_PROP_UINT64("adc-hz", Web888PLState, adc_hz, 122880000),
    DEFINE_PROP_INT32("adc-ppb", Web888PLState, adc_ppb, 0),
    DEFINE_PROP_STRING("scene", Web888PLState, scene),
    DEFINE_PROP_STRING("noise", Web888PLState, noise),
    DEFINE_PROP_UINT32("tick-us", Web888PLState, tick_us, 2000),
    DEFINE_PROP_BOOL("pps", Web888PLState, pps_present, true),
    DEFINE_PROP_UINT32("wf-cont-max", Web888PLState, wf_cont_max, 4000000),
    DEFINE_PROP_UINT32("rx-bursts-start", Web888PLState, rx_bursts_start, 0),
    DEFINE_PROP_UINT64("seed", Web888PLState, seed, 1),
    DEFINE_PROP_BOOL("log", Web888PLState, log_regs, false),
};

static const VMStateDescription vmstate_web888_pl = {
    .name = TYPE_WEB888_PL,
    .unmigratable = 1,
};

static void web888_pl_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    ResettableClass *rc = RESETTABLE_CLASS(klass);

    dc->desc = "Web-888 SDR programmable logic (synthetic DDC)";
    dc->realize = web888_pl_realize;
    dc->vmsd = &vmstate_web888_pl;
    rc->phases.hold = web888_pl_reset_hold;
    device_class_set_props(dc, web888_pl_props);
}

static const TypeInfo web888_pl_info = {
    .name = TYPE_WEB888_PL,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(Web888PLState),
    .instance_init = web888_pl_init,
    .class_init = web888_pl_class_init,
};

static void web888_pl_register_types(void)
{
    type_register_static(&web888_pl_info);
}

type_init(web888_pl_register_types)
