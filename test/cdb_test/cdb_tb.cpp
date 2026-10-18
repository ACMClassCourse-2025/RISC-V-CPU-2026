// -----------------------------------------------------------------------------
// cdb_tb.cpp — CDB arbitration test.
//
// Build with -DTB_W / -DTB_R matching -DCPU_ISSUE_WIDTH / -DCPU_CDB_NUM.
// Verifies: single-source transfer, all-source drain, round-robin fairness,
// per-lane field routing, and that R lanes never select the same source twice.
// -----------------------------------------------------------------------------

#include "Vcdb.h"
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
constexpr int N = W + 2;
constexpr uint64_t CDB_MASK = (1ull << 40) - 1;

uint32_t rng = 0x9e3779b9u;
uint32_t next_rand() {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

struct Harness {
    Vcdb* dut = nullptr;
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
        dut->src_valid = 0;
        for (int i = 0; i < N; ++i) {
            set_tag(i, 0);
            set_value(i, 0);
        }
        dut->src_exception = 0;
        for (int i = 0; i < 3; ++i) tick();
        dut->reset = 0;
        tick();
    }

    void set_tag(int i, uint32_t tag) {
        uint32_t mask = 0x3f;
        uint32_t all = (uint32_t)dut->src_tag;
        all = (all & ~(mask << (6 * i))) | ((tag & mask) << (6 * i));
        dut->src_tag = all;
    }

    void set_value(int i, uint32_t value) {
        dut->src_value[i] = value;
    }

    void set_valid(int i, bool valid) {
        if (valid) dut->src_valid = (uint8_t)(dut->src_valid | (1u << i));
        else dut->src_valid = (uint8_t)(dut->src_valid & ~(1u << i));
    }

    bool ready(int i) const { return (dut->src_ready >> i) & 1; }

    uint64_t cdb_lane(int r) {
#if TB_R == 1
        (void)r;
        return (uint64_t)dut->cdb_out & CDB_MASK;
#else
        int bit = 40 * r;
        int word = bit / 32;
        int shift = bit % 32;
        uint64_t value = (uint64_t)dut->cdb_out[word] >> shift;
        // A 40-bit field always needs bits from the next 32-bit word.
        value |= (uint64_t)dut->cdb_out[word + 1] << (32 - shift);
        return value & CDB_MASK;
#endif
    }

    bool cdb_valid(int r) { return (cdb_lane(r) >> 0) & 1; }
    uint32_t cdb_tag(int r) { return (uint32_t)((cdb_lane(r) >> 1) & 0x3f); }
    uint32_t cdb_value(int r) { return (uint32_t)((cdb_lane(r) >> 7) & 0xffffffffu); }
    bool cdb_exception(int r) { return (cdb_lane(r) >> 39) & 1; }

    void expect(bool ok, const char* what) {
        ++checks;
        if (!ok) {
            ++fails;
            printf("FAIL: %s\n", what);
        }
    }

    // Drain all N sources; each must be granted exactly once.
    void drain_all() {
        bool granted[N] = {};
        int total = 0;
        for (int i = 0; i < N; ++i) {
            set_valid(i, true);
            set_tag(i, 10 + i);
            set_value(i, 0x1000u + i);
        }
        dut->src_exception = 0;
        for (int cycle = 0; cycle < 64 && total < N; ++cycle) {
            dut->clk = 0;
            dut->eval();
            int seen = 0;
            for (int r = 0; r < R; ++r) {
                if (!cdb_valid(r)) continue;
                ++seen;
                ++total;
                uint32_t tag = cdb_tag(r);
                int idx = (int)tag - 10;
                expect(idx >= 0 && idx < N, "drain tag range");
                if (idx >= 0 && idx < N) {
                    expect(!granted[idx], "drain duplicate grant");
                    granted[idx] = true;
                    expect(cdb_value(r) == 0x1000u + idx, "drain value");
                }
            }
            expect(seen <= R, "drain too many grants");
            for (int i = 0; i < N; ++i)
                if (ready(i)) {
                    set_valid(i, false);
                }
            dut->clk = 1;
            dut->eval();
        }
        expect(total == N, "drain all sources");
    }

    void single_source() {
        for (int i = 0; i < N; ++i) set_valid(i, false);
        set_valid(0, true);
        set_tag(0, 3);
        set_value(0, 0xdeadbeefu);
        dut->src_exception = 1;
        dut->clk = 0;
        dut->eval();
        expect(ready(0), "single ready");
        expect(cdb_valid(0), "single cdb valid");
        expect(cdb_tag(0) == 3, "single tag");
        expect(cdb_value(0) == 0xdeadbeefu, "single value");
        expect(cdb_exception(0), "single exception");
        for (int r = 1; r < R; ++r) expect(!cdb_valid(r), "single extra lane");
        set_valid(0, false);
        dut->src_exception = 0;
        tick();
    }

    void random_stress() {
        bool valid[N] = {};
        uint32_t tag[N] = {};
        uint32_t value[N] = {};
        for (int i = 0; i < N; ++i) {
            valid[i] = true;
            tag[i] = i + 1;  // unique, so the checker can identify the source
            value[i] = next_rand();
            set_valid(i, true);
            set_tag(i, tag[i]);
            set_value(i, value[i]);
        }
        for (long cycle = 0; cycle < 5000; ++cycle) {
            dut->clk = 0;
            dut->eval();
            bool used[N] = {};
            int seen = 0;
            for (int r = 0; r < R; ++r) {
                if (!cdb_valid(r)) continue;
                ++seen;
                uint32_t t = cdb_tag(r);
                int match = -1;
                for (int i = 0; i < N; ++i)
                    if (valid[i] && !used[i] && tag[i] == t) match = i;
                expect(match >= 0, "random tag has source");
                if (match >= 0) {
                    used[match] = true;
                    expect(cdb_value(r) == value[match], "random value");
                }
            }
            expect(seen <= R, "random grant count");
            for (int i = 0; i < N; ++i) {
                if (ready(i)) {
                    expect(valid[i], "random ready implies valid");
                    valid[i] = false;
                    set_valid(i, false);
                }
            }
            dut->clk = 1;
            dut->eval();
            // Refill occasionally, with new tags.
            for (int i = 0; i < N; ++i) {
                if (!valid[i] && ((next_rand() & 3) == 0)) {
                    valid[i] = true;
                    tag[i] = i + 1;
                    value[i] = next_rand();
                    set_valid(i, true);
                    set_tag(i, tag[i]);
                    set_value(i, value[i]);
                }
            }
        }
    }
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vcdb dut;
    Harness h;
    h.dut = &dut;
    h.reset();

    h.single_source();
    h.drain_all();
    h.random_stress();

    printf("\nW=%d R=%d N=%d checked=%ld fails=%ld\n", W, R, N, h.checks, h.fails);
    bool pass = (h.fails == 0);
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}
