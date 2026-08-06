#include <stdio.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <stdint.h>
static void dump(int fd, uint32_t base, int words, const char *name) {
    void *m = mmap(0, 4096, PROT_READ, MAP_SHARED, fd, base);
    if (m == MAP_FAILED) { perror("mmap"); return; }
    volatile uint32_t *r = (volatile uint32_t *)m;
    printf("%s @0x%08x:", name, base);
    for (int i = 0; i < words; i++) printf(" %08x", r[i]);
    printf("\n");
    munmap(m, 4096);
}
int main(void) {
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open"); return 1; }
    dump(fd, 0x40000000, 40, "config");
    dump(fd, 0x41000000, 8,  "status");
    return 0;
}
