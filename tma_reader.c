// TMA counter reader for BOOM v3 via /dev/mem MMIO access
// Reads all TMA performance counters and prints them as CSV to stdout.
// Counter definitions are sourced from tma_counters.h (single source of truth).
// Must be run as root.

#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "tma_counters.h"

#define TMA_MMIO_SIZE 0x1000

int main(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    volatile uint8_t *base = mmap(NULL, TMA_MMIO_SIZE, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, fd, TMA_MMIO_BASE);
    if (base == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    // Snapshot all counters atomically
    *(volatile uint64_t *)(base + TMA_CTL_OFFSET) = TMA_CTL_SNAPSHOT;

    // Print CSV header
    printf("counter,value\n");

    // Read and print all counters
    for (int i = 0; i < TMA_NUM_COUNTERS; i++) {
        uint64_t val = *(volatile uint64_t *)(base + 0x008 + i * 0x008);
        printf("%s,%lu\n", tma_counter_names[i], val);
    }

    // Release snapshot
    *(volatile uint64_t *)(base + TMA_CTL_OFFSET) = TMA_CTL_RELEASE;

    munmap((void *)base, TMA_MMIO_SIZE);
    close(fd);
    return 0;
}
