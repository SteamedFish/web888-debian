// hw-probe.c — static armhf hardware state probe for the Web-888
// (stock-vs-Debian golden-reference diffing). Runs on ANY userspace (Debian glibc, Alpine
// busybox) because it is statically linked and only talks to /dev/mem and
// /dev/i2c-0 directly. READ-ONLY: never writes a register — safe on stock.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/ioctl.h>

#define I2C_SLAVE 0x0703

static void dump_mem(uint32_t base, const uint32_t *offs, int n, const char *name) {
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { printf("[%s] /dev/mem: %s\n", name, strerror(errno)); return; }
    volatile uint8_t *m = mmap(NULL, 0x1000, PROT_READ, MAP_SHARED, fd, base & ~0xfff);
    if (m == MAP_FAILED) { printf("[%s] mmap: %s\n", name, strerror(errno)); close(fd); return; }
    printf("[%s @0x%08x]\n", name, base);
    for (int i = 0; i < n; i++) {
        uint32_t v = *(volatile uint32_t *)(m + (base & 0xfff) + offs[i]);
        printf("  +0x%03x = 0x%08x\n", offs[i], v);
    }
    munmap((void *)m, 0x1000);
    close(fd);
}

static void si5351(void) {
    static const uint8_t regs[] = {
        0, 1, 3, 15, 16, 17, 18, 19, 20, 21, 22, 23,
        26, 27, 28, 29, 30, 31, 32, 33,
        34, 35, 36, 37, 38, 39, 40, 41,
        42, 43, 44, 45, 46, 47, 48, 49,
        177, 183, 187
    };
    int fd = open("/dev/i2c-0", O_RDWR);
    if (fd < 0) { printf("[Si5351] /dev/i2c-0: %s\n", strerror(errno)); return; }
    if (ioctl(fd, I2C_SLAVE, 0x60) < 0) { printf("[Si5351] ioctl: %s\n", strerror(errno)); close(fd); return; }
    printf("[Si5351 @0x60 /dev/i2c-0, single-byte reads]\n");
    for (unsigned i = 0; i < sizeof(regs); i++) {
        uint8_t v = 0xff;
        if (write(fd, &regs[i], 1) == 1 && read(fd, &v, 1) == 1)
            printf("  reg%3d = 0x%02x\n", regs[i], v);
        else
            printf("  reg%3d = ERROR(%s)\n", regs[i], strerror(errno));
    }
    close(fd);
}

static void ring(uint32_t base, const char *name) {
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { printf("[%s] /dev/mem: %s\n", name, strerror(errno)); return; }
    volatile uint8_t *m = mmap(NULL, 0x2000, PROT_READ, MAP_SHARED, fd, base);
    if (m == MAP_FAILED) { printf("[%s] mmap: %s\n", name, strerror(errno)); close(fd); return; }
    uint8_t s1[8192], s2[8192];
    memcpy(s1, (const void *)m, 8192);
    usleep(1000000);
    memcpy(s2, (const void *)m, 8192);
    int diff = 0;
    for (int i = 0; i < 8192; i++) if (s1[i] != s2[i]) diff++;
    printf("[%s @0x%08x] diff=%d/8192 -> %s\n", name, base, diff, diff > 10 ? "LIVE" : "STATIC");
    uint32_t *w = (uint32_t *)s1;
    double sum = 0; int32_t mx = -0x7fffffff, mn = 0x7fffffff;
    for (int i = 0; i < 2048; i += 4) {
        int32_t s = (int32_t)w[i];
        sum += s < 0 ? -(double)s : (double)s;
        if (s > mx) mx = s;
        if (s < mn) mn = s;
    }
    printf("  word0 stats: mean_abs=%.0f max=%d min=%d\n", sum / 512, mx, mn);
    printf("  head32: ");
    for (int i = 0; i < 32; i++) printf("%02x", s1[i]);
    printf("\n");
    munmap((void *)m, 0x2000);
    close(fd);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    si5351();
    {
        static const uint32_t o[] = {0x100, 0x120, 0x170, 0x180, 0x190, 0x1A0, 0x240};
        dump_mem(0xF8000000, o, sizeof(o)/4, "SLCR");
    }
    {
        static const uint32_t o[] = {0x00, 0x04, 0x0c};
        dump_mem(0xF8007000, o, sizeof(o)/4, "devcfg");
    }
    {
        static const uint32_t o[] = {0x00, 0x04, 0x0c, 0x6c, 0x74, 0x78, 0x80, 0x84, 0x8c, 0x90};
        dump_mem(0x40000000, o, sizeof(o)/4, "PL cfg");
    }
    {
        static const uint32_t o[] = {0x00, 0x04, 0x08};
        dump_mem(0x41000000, o, sizeof(o)/4, "PL status");
    }
    {
        static const uint32_t o[] = {0x00, 0x04, 0x40, 0x44, 0x204, 0x208, 0x244, 0x248};
        dump_mem(0xE000A000, o, sizeof(o)/4, "PS GPIO");
    }
    ring(0x1bc80000, "RX ring");
    ring(0x1bd00000, "WF ring");
    return 0;
}
