/*
 * Web-888 SDR programmable-logic (PL) model: register hub, RX/WF DMA
 * rings with synthetic DDC data, PPS counter.
 *
 * Copyright (c) 2026 web888-ng contributors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_WEB888_PL_H
#define HW_MISC_WEB888_PL_H

#include "hw/core/sysbus.h"
#include "qom/object.h"

#define TYPE_WEB888_PL "web888-pl"
OBJECT_DECLARE_SIMPLE_TYPE(Web888PLState, WEB888_PL)

#define WEB888_CFG_BASE   0x40000000
#define WEB888_STS_BASE   0x41000000
#define WEB888_PPS_BASE   0x42000000
#define WEB888_WIN_SIZE   0x1000

#define WEB888_CFG_BYTES  0xA0
#define WEB888_STS_BYTES  0x40
#define WEB888_MAX_RX     13
#define WEB888_NWF        2
#define WEB888_PPS_DEPTH  16
#define WEB888_MAX_TONES  32

/* GPIO input lines of the device (from the PS GPIO block, MIO pins). */
enum {
    WEB888_GPIO_IN_HFVHF,     /* MIO 10: HF / VHF switch       */
    WEB888_GPIO_IN_ATT_CLK,   /* MIO 13: AD8370 CLK            */
    WEB888_GPIO_IN_ATT_LATCH, /* MIO 12: AD8370 LATCH          */
    WEB888_GPIO_IN_ATT_DATA,  /* MIO 11: AD8370 DATA           */
    WEB888_GPIO_IN_REFCLK,    /* MIO 49: reference clock select */
    WEB888_GPIO_IN_NUM
};

typedef struct Web888Line {
    double pr, pi;      /* phasor */
    double rr, ri;      /* per-sample rotation */
    double amp;         /* nominal |phasor| (renormalisation) */
} Web888Line;

typedef struct Web888Chan {
    uint64_t word;      /* 48-bit NCO increment as programmed */
    int nlines;
    Web888Line lines[2 * WEB888_MAX_TONES];
} Web888Chan;

typedef struct Web888Tone {
    double f_hz;
    double dbfs;
} Web888Tone;

/* One DMA stream (RX or a WF slot). */
typedef struct Web888Stream {
    bool run;
    bool oneshot;
    uint32_t addr;          /* ring base */
    uint32_t nbursts;       /* ring length in 128-byte bursts */
    uint32_t ptr;           /* completed bursts mod nbursts */
    uint64_t bytes;         /* bytes produced since start */
    uint64_t samples;       /* output samples produced since start */
    uint64_t limit;         /* one-shot sample limit (0 = none) */
    int64_t t0_ns;          /* virtual time of (re)start */
    double fs_out;          /* output sample rate */
    uint32_t frames;        /* ext counters */
    uint32_t drops;
    uint32_t bursts;
    bool ovf;
    bool bresp_err;
    uint8_t carry[128];     /* partial burst not yet written */
    uint32_t carry_len;
} Web888Stream;

struct Web888PLState {
    SysBusDevice parent_obj;

    MemoryRegion cfg_mr;
    MemoryRegion sts_mr;
    MemoryRegion pps_mr;
    qemu_irq irq[4];        /* IRQ_F2P[3:0] */
    qemu_irq pps_out;       /* EMIO GPIO 54 */
    QEMUTimer *timer;

    uint8_t cfg[WEB888_CFG_BYTES];
    uint16_t ctrl_prev;

    /* properties */
    uint32_t signature;
    uint64_t dna;
    uint32_t build_id;
    uint64_t adc_hz;
    int32_t adc_ppb;
    char *scene;
    char *noise;
    uint32_t tick_us;
    bool pps_present;
    uint32_t wf_cont_max;   /* max continuous WF rate, samples/s */
    uint32_t rx_bursts_start; /* STS 0x38 value at RX start (test hook) */
    uint64_t seed;
    bool log_regs;

    /* derived */
    int nrx;
    double fs;              /* true ADC rate */
    int ntones;
    Web888Tone tones[WEB888_MAX_TONES];
    bool has_noise;
    double noise_dbfs_hz;
    double gain;            /* front-end gain from the attenuator */
    uint64_t rng;

    /* RX */
    uint16_t r2;
    Web888Stream rx;
    Web888Chan rxch[WEB888_MAX_RX];

    /* WF */
    Web888Stream wf[WEB888_NWF];
    Web888Chan wfch[WEB888_NWF];
    uint16_t wf_decim[WEB888_NWF];

    /* PPS */
    bool pps_en;
    bool pps_armed;
    int64_t pps_next_ns;
    int64_t pps_low_ns;
    uint32_t pps_fifo[WEB888_PPS_DEPTH];
    unsigned pps_head, pps_count;
    uint32_t pps_last;
    bool pps_level;

    /* ADC sample counter base */
    int64_t boot_ns;

    /* AD8370 bit-bang decoder (driver AD8370_SET) */
    bool gpio_in[WEB888_GPIO_IN_NUM];
    uint8_t att_shift;
    uint8_t att_code;
    int att_bits;
};

#endif
