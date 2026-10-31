// SPDX-License-Identifier: GPL-3.0-or-later
// Bare-metal smoke test of the web888-pl QEMU model (milestone A).
// Run with: -M web888 -kernel pltest.elf -global web888-pl.scene=10001000:-20
//           -global web888-pl.noise=
#include <stdint.h>

#define UART0 0xE0000000u
#define CFG   0x40000000u
#define STS   0x41000000u
#define PPSF  0x42000000u

#define R32(a) (*(volatile uint32_t *)(a))
#define R16(a) (*(volatile uint16_t *)(a))
#define R8(a)  (*(volatile uint8_t *)(a))

static void putc_(char c)
{
    while (R32(UART0 + 0x2C) & (1 << 4))
        ;
    R32(UART0 + 0x30) = c;
}

static void puts_(const char *s)
{
    while (*s) {
        if (*s == '\n')
            putc_('\r');
        putc_(*s++);
    }
}

static void hex(uint32_t v)
{
    puts_("0x");
    for (int i = 28; i >= 0; i -= 4)
        putc_("0123456789abcdef"[(v >> i) & 15]);
}

static void dec(int64_t v)
{
    char b[24];
    int n = 0;
    uint64_t u;
    if (v < 0) {
        putc_('-');
        u = -v;
    } else {
        u = v;
    }
    do {
        b[n++] = '0' + u % 10;
        u /= 10;
    } while (u);
    while (n)
        putc_(b[--n]);
}

static int fails;

static void check(const char *what, int ok)
{
    puts_(ok ? "PASS " : "FAIL ");
    puts_(what);
    puts_("\n");
    if (!ok)
        fails++;
}

static uint64_t adc_clocks(void)
{
    uint32_t hi, lo;
    do {
        hi = R32(STS + 0x2C);
        lo = R32(STS + 0x28);
    } while (hi != R32(STS + 0x2C));
    return ((uint64_t)hi << 32) | lo;
}

static void wait_ms(uint32_t ms)
{
    uint64_t end = adc_clocks() + (uint64_t)ms * 122880;
    while (adc_clocks() < end)
        ;
}

static uint64_t nco(uint64_t f_hz)
{
    /* f / 122.88 MHz * 2^48, integer: f * 2^48 / 122880000 */
    return (uint64_t)((double)f_hz * 281474976710656.0 / 122880000.0 + 0.5);
}

static void cfg_u64(uint32_t off, uint64_t v)
{
    R32(CFG + off) = (uint32_t)v;
    R32(CFG + off + 4) = (uint32_t)(v >> 32);
}

int main(void)
{
    R32(UART0 + 0x00) = 0x14;   /* RX/TX enable */
    puts_("\nweb888-pl bare-metal test\n");

    uint32_t sig = R32(STS + 0x00);
    puts_("signature ");
    hex(sig);
    puts_("  dna ");
    hex(R32(STS + 0x10));
    hex(R32(STS + 0x0C));
    puts_("  build ");
    hex(R32(STS + 0x18));
    puts_("  flags ");
    hex(R32(STS + 0x20));
    puts_("\n");
    int nrx = sig & 15;
    check("signature has 2 WF and 12/13 RX",
          ((sig >> 8) & 15) == 2 && (nrx == 12 || nrx == 13));

    /* CFG readback incl. byte, halfword and unaligned word access */
    R16(CFG + 0x02) = 40;
    R8(CFG + 0x92) = 0x00;
    R8(CFG + 0x93) = 0x00;
    R8(CFG + 0x94) = 0x30;
    R8(CFG + 0x95) = 0x00;
    check("CFG 0x02 halfword readback", R16(CFG + 0x02) == 40);
    check("CFG 0x92 unaligned word via bytes",
          (R32(CFG + 0x90) >> 16 | (uint32_t)R16(CFG + 0x94) << 16) ==
              0x00300000);

    /* ---------------- RX */
    uint32_t ring = 0x00200000;
    for (int ch = 0; ch < nrx; ch++)
        cfg_u64(0x04 + 8 * ch, nco(10000000 + 1000 * ch));
    R32(CFG + 0x8C) = ring;
    R16(CFG + 0x90) = 0x0FF7;
    R16(CFG + 0x00) = 0x0001;
    wait_ms(100);
    uint32_t frames = R32(STS + 0x30);
    uint32_t ptr = R16(STS + 0x04);
    puts_("RX after 100 ms: frames ");
    dec(frames);
    puts_(" ptr ");
    dec(ptr);
    puts_(" bursts ");
    dec(R32(STS + 0x38));
    puts_("\n");
    check("RX frame rate ~12 kS/s", frames > 1100 && frames < 1300);
    uint32_t b = R32(STS + 0x38) % 0xFF8;
    check("RX pointer = bursts mod ring", b >= ptr && b - ptr <= 4);

    volatile int32_t *f = (volatile int32_t *)ring;
    int64_t i0 = f[0], q0 = f[1];
    int64_t i1 = f[2 * nrx], q1 = f[2 * nrx + 1];
    puts_("ch0 s0 I ");
    dec(i0);
    puts_(" Q ");
    dec(q0);
    puts_("  s1 I ");
    dec(i1);
    puts_(" Q ");
    dec(q1);
    puts_("\n");
    /* -20 dBFS tone at +1 kHz: |z| ~ 2^29 * 0.1 * 0.944 = 5.07e7 */
    double m2 = (double)i1 * i1 + (double)q1 * q1;
    check("ch0 magnitude ~5.07e7",
          m2 > 4.8e7 * 4.8e7 && m2 < 5.3e7 * 5.3e7);
    check("ch0 rotates +1 kHz (counter-clockwise)", i0 * q1 - q0 * i1 > 0);
    /* channel 1 tuned 1 kHz higher -> the tone sits at DC */
    int64_t c1i = f[2], c1q = f[3], c1i2 = f[2 * nrx + 2];
    check("ch1 tone at DC (constant)", c1i == c1i2 && (c1i || c1q));

    /* ---------------- WF0 one-shot */
    uint32_t wring = 0x00300000;
    cfg_u64(0x6C, nco(10000000));
    R32(CFG + 0x74) = 4;
    R16(CFG + 0x96) = 0x0FF7;
    R16(CFG + 0x9E) = 1;            /* bit0 = 1: one-shot */
    R16(CFG + 0x00) = 0x0003;
    wait_ms(10);
    puts_("WF0 ptr ");
    dec(R16(STS + 0x06));
    puts_(" flags ");
    hex(R32(STS + 0x20));
    puts_("\n");
    check("WF0 one-shot stops at 256 bursts",
          R16(STS + 0x06) == 256 && !(R32(STS + 0x20) & (1 << 11)));
    volatile int16_t *w = (volatile int16_t *)wring;
    double wm = (double)w[20] * w[20] + (double)w[21] * w[21];
    puts_("WF0 s10 I ");
    dec(w[20]);
    puts_(" Q ");
    dec(w[21]);
    puts_("\n");
    /* -20 dBFS -> 2^14 * 0.1 = 1638 (CIC droop negligible at 1 kHz) */
    check("WF0 magnitude ~1638", wm > 1600.0 * 1600 && wm < 1680.0 * 1680);
    check("WF0 sample 8192 untouched", R32(wring + 8192 * 4) == 0);

    /* ---------------- PPS */
    R16(CFG + 0x00) = 0x0083;
    wait_ms(2100);
    uint32_t n = R16(STS + 0x0A);
    uint32_t p = R32(PPSF);
    puts_("PPS count ");
    dec(n);
    puts_(" value ");
    dec(p);
    puts_(" after pop ");
    dec(R16(STS + 0x0A));
    puts_("\n");
    check("PPS period = 122880000", n >= 1 && p == 122880000);

    puts_(fails ? "RESULT: FAIL\n" : "RESULT: PASS\n");
    return 0;
}
