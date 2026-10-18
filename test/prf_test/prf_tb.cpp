// -----------------------------------------------------------------------------
// prf_tb.cpp — parameterized PRF unit test.
//
// Build with -DTB_W / -DTB_R matching -DCPU_ISSUE_WIDTH / -DCPU_CDB_NUM.
// Checks x0, reset, multi-port writes, reads, and random read/write traffic.
// -----------------------------------------------------------------------------

#include "Vprf.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>

#ifndef TB_W
#define TB_W 1
#endif
#ifndef TB_R
#define TB_R 1
#endif

namespace {

constexpr int W = TB_W;
constexpr int R = TB_R;
constexpr int RPORTS = 2 * W;
constexpr int PRF = 64;

uint32_t rng = 0x12345678u;
uint32_t next_rand() {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

struct Harness {
    Vprf* dut = nullptr;
    uint32_t model[PRF] = {};
    long checks = 0;
    long fails = 0;

    void tick() {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
    }

    void reset() {
        dut->reset = 1;
        for (int p = 0; p < RPORTS; ++p) set_raddr(p, 0);
        for (int r = 0; r < R; ++r) {
            dut->we = 0;
            set_waddr(r, 0);
            set_wdata(r, 0);
        }
        for (int i = 0; i < 3; ++i) tick();
        dut->reset = 0;
        tick();
        for (int i = 0; i < PRF; ++i) model[i] = 0;
    }

    void set_raddr(int p, uint32_t value) {
        uint64_t mask = (1ull << 6) - 1;
        uint64_t shift = 6 * p;
        uint64_t all = dut->raddr;
        all = (all & ~(mask << shift)) | ((uint64_t)(value & 0x3f) << shift);
        dut->raddr = all;
    }

    void set_waddr(int r, uint32_t value) {
        uint64_t mask = (1ull << 6) - 1;
        uint64_t shift = 6 * r;
        uint64_t all = dut->waddr;
        all = (all & ~(mask << shift)) | ((uint64_t)(value & 0x3f) << shift);
        dut->waddr = all;
    }

    void set_wdata(int r, uint32_t value) {
        uint64_t mask = 0xffffffffull;
        uint64_t shift = 32 * r;
        uint64_t all = dut->wdata;
        all = (all & ~(mask << shift)) | ((uint64_t)value << shift);
        dut->wdata = all;
    }

    uint32_t get_rdata(int p) {
#if TB_W == 1
        return (uint32_t)(dut->rdata >> (32 * p));
#else
        return (uint32_t)dut->rdata[p];
#endif
    }

    void check_read(int p, uint32_t tag, const char* tag_name) {
        set_raddr(p, tag);
        dut->eval();
        uint32_t got = get_rdata(p);
        uint32_t want = (tag == 0) ? 0 : model[tag];
        ++checks;
        if (got != want) {
            ++fails;
            printf("FAIL [%s] read port %d tag=%u got=%08x want=%08x\n",
                   tag_name, p, tag, got, want);
        }
    }

    void write_one(int r, uint32_t tag, uint32_t value) {
        set_waddr(r, tag);
        set_wdata(r, value);
        dut->we = (uint8_t)(dut->we | (1u << r));
        tick();
        dut->we = 0;
        if (tag != 0) model[tag] = value;
    }
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vprf dut;
    Harness h;
    h.dut = &dut;
    h.reset();

    // x0 must read zero before and after writes to tag 0.
    h.check_read(0, 0, "x0-reset");
    h.write_one(0, 0, 0xdeadbeefu);
    h.check_read(0, 0, "x0-write");

    // Sequential writes/reads.
    for (uint32_t tag = 1; tag <= 16; ++tag) {
        h.write_one(0, tag, 0x1000u + tag);
        h.check_read(0, tag, "seq");
        h.check_read(1 % RPORTS, tag, "seq-b");
    }

    // Multi-write-port test: distinct tags in one cycle.
    for (int r = 0; r < R; ++r) {
        h.set_waddr(r, 20 + r);
        h.set_wdata(r, 0xa0000000u + r);
        dut.we = (uint8_t)(dut.we | (1u << r));
    }
    h.tick();
    dut.we = 0;
    for (int r = 0; r < R; ++r) h.model[20 + r] = 0xa0000000u + r;
    for (int r = 0; r < R; ++r) {
        h.check_read(r % RPORTS, 20 + r, "multi-write");
        h.model[20 + r] = 0xa0000000u + r;
    }

    // Random traffic: write R tags, tick, then read 2W tags.
    for (long iter = 0; iter < 2000; ++iter) {
        for (int r = 0; r < R; ++r) {
            uint32_t tag = next_rand() % PRF;
            uint32_t value = next_rand();
            h.set_waddr(r, tag);
            h.set_wdata(r, value);
            h.model[tag] = (tag == 0) ? 0 : value;
        }
        dut.we = (uint8_t)((1u << R) - 1);
        h.tick();
        dut.we = 0;
        for (int p = 0; p < RPORTS; ++p) {
            uint32_t tag = next_rand() % PRF;
            h.check_read(p, tag, "random");
        }
    }

    // Reset clears everything except x0.
    h.dut->reset = 1;
    h.tick();
    h.dut->reset = 0;
    h.tick();
    for (int i = 0; i < PRF; ++i) h.model[i] = 0;
    h.check_read(0, 1, "reset-clear");

    printf("\nW=%d R=%d checked=%ld fails=%ld\n", W, R, h.checks, h.fails);
    bool pass = (h.fails == 0);
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}
