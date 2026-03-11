// TMA counter reader for BOOM v3 via /dev/mem MMIO access
// Reads all 57 TMA performance counters (40 core + 17 L2) and prints them as CSV to stdout.
// Must be run as root.

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#define TMA_MMIO_BASE   0x10030000UL
#define TMA_MMIO_SIZE   0x1000
#define TMA_CTL_OFFSET  0x000
#define TMA_CTL_SNAPSHOT 0x1
#define TMA_CTL_RELEASE  0x2

#define TMA_NUM_COUNTERS 57

static const char *counter_names[TMA_NUM_COUNTERS] = {
    "cycles", "instret",
    "tma_retiring", "tma_bad_speculation", "tma_frontend_bound", "tma_backend_bound",
    "tma_fetch_latency", "tma_fetch_bandwidth",
    "tma_branch_mispredict", "tma_machine_clears",
    "tma_memory_bound", "tma_core_bound",
    "retired_loads", "retired_stores", "retired_branches", "retired_jals",
    "retired_jalrs", "retired_fp", "retired_amo", "retired_system",
    "rob_full_cycles", "ldq_full_cycles", "stq_full_cycles",
    "int_iq_full_cycles", "mem_iq_full_cycles",
    "branch_mask_full_cycles", "rename_stall_cycles",
    "flush_cycles", "rollback_cycles",
    "icache_miss", "dcache_miss", "dcache_release",
    "itlb_miss", "dtlb_miss", "l2tlb_miss",
    "br_mispredict", "br_resolve", "jalr_mispredict",
    "br_mispredict_bpd", "br_mispredict_btb",
    // L2 cache counters
    "l2_pf_hint_req_accepted", "l2_pf_hint_req_blocked",
    "l2_pf_alloc_dir_miss", "l2_pf_alloc_dir_hit",
    "l2_demand_alloc_dir_miss", "l2_demand_hit_prefetched",
    "l2_demand_hit_pf_brought", "l2_demand_queued_behind_pf",
    "l2_demand_hit_regular",
    "l2_secondary_misses", "l2_evict_dirty", "l2_evict_clean",
    "l2_evict_prefetched",
    "l2_mshr_occ_sum", "l2_mshr_full",
    "l2_set_conflict_stall", "l2_bank_conflict"
};

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

    // Read and print all 57 counters
    for (int i = 0; i < TMA_NUM_COUNTERS; i++) {
        uint64_t val = *(volatile uint64_t *)(base + 0x008 + i * 0x008);
        printf("%s,%lu\n", counter_names[i], val);
    }

    // Release snapshot
    *(volatile uint64_t *)(base + TMA_CTL_OFFSET) = TMA_CTL_RELEASE;

    munmap((void *)base, TMA_MMIO_SIZE);
    close(fd);
    return 0;
}
