#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>
int main(void) {
    int fd = open("/dev/mem", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    struct { const char *name; off_t addr; size_t len; } regions[] = {
        {"cfg  @0x40000000", 0x40000000, 4096},
        {"sts  @0x41000000", 0x41000000, 4096},
        {"rxd4 @0x42000000", 0x42000000, 4*4096},
        {"rxd8 @0x42000000", 0x42000000, 8*4096},
    };
    for (int i = 0; i < 4; i++) {
        void *p = mmap(NULL, regions[i].len, PROT_READ|PROT_WRITE, MAP_SHARED, fd, regions[i].addr);
        if (p == MAP_FAILED) { printf("%s len=%zu: mmap FAIL errno=%d (%s)\n", regions[i].name, regions[i].len, errno, strerror(errno)); }
        else { volatile unsigned v = *(volatile unsigned *)p; printf("%s len=%zu: mmap OK first_word=0x%08x\n", regions[i].name, regions[i].len, v); munmap(p, regions[i].len); }
    }
    return 0;
}
