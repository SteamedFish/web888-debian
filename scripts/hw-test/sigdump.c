#include <stdio.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <stdint.h>
#define ZYNQSDR_GET_DNA       _IOR('Z', 3, uint64_t)
#define ZYNQSDR_GET_SIGNATURE _IOR('Z', 9, uint32_t)
int main(void) {
    int fd = open("/dev/zynqsdr", O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    uint32_t sig = 0xdeadbeef;
    uint64_t dna = 0xdeadbeef;
    int rc1 = ioctl(fd, ZYNQSDR_GET_SIGNATURE, &sig);
    int rc2 = ioctl(fd, ZYNQSDR_GET_DNA, &dna);
    printf("sig=%08x rc=%d  dna=%016llx rc=%d\n", sig, rc1, (unsigned long long)dna, rc2);
    return 0;
}
