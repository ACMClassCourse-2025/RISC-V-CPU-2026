// -----------------------------------------------------------------------------
// stub_front_tb.cpp — scripted frontend stub test.
// Build with -DTB_W matching -DCPU_ISSUE_WIDTH.
// -----------------------------------------------------------------------------

#include "Vstub_front_ooo.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>

#ifndef TB_W
#define TB_W 1
#endif

namespace {
constexpr int W = TB_W;
constexpr int PRF = 6, LSQ = 3, ROB = 5;
constexpr int DW = 124 + 3 * PRF + LSQ + ROB;
constexpr int GW = W * DW;
constexpr int WORDS = (GW + 31) / 32;

template <typename V>
void set_field(V& v, int off, int width, uint32_t value) {
    for (int i = 0; i < width; ++i) {
        int b = off + i, w = b / 32, s = b % 32;
        if ((value >> i) & 1u) v[w] |= (1u << s);
        else v[w] &= ~(1u << s);
    }
}
template <typename V>
uint32_t get_field(const V& v, int off, int width) {
    uint32_t x = 0;
    for (int i = 0; i < width; ++i) {
        int b = off + i, w = b / 32, s = b % 32;
        x |= ((v[w] >> s) & 1u) << i;
    }
    return x;
}

struct H {
    Vstub_front_ooo* dut = nullptr;
    long checks = 0, fails = 0;

    void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }
    void reset() {
        dut->reset = 1;
        dut->push_valid = 0;
        for (int i = 0; i < WORDS; ++i) dut->push_uop[i] = 0;
        dut->commit_in = 0;
        dut->squash_in = 0;
        dut->backend_ready = 0;
        for (int i = 0; i < 3; ++i) tick();
        dut->reset = 0;
        tick();
    }
    void push(int lane, uint32_t pc, uint32_t inst, uint32_t dest, uint32_t rob) {
        int base = lane * DW;
        set_field(dut->push_uop, base + 0, 1, 1);
        set_field(dut->push_uop, base + 1, 32, pc);
        set_field(dut->push_uop, base + 33, 32, inst);
        set_field(dut->push_uop, base + 122, PRF, dest);
        set_field(dut->push_uop, base + 128, 1, 1);
        set_field(dut->push_uop, base + 134, 1, 1);
        set_field(dut->push_uop, base + 145, ROB, rob);
    }
    void expect(bool ok, const char* what) {
        ++checks;
        if (!ok) { ++fails; printf("FAIL: %s\n", what); }
    }
};
}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vstub_front_ooo dut;
    H h; h.dut = &dut;
    h.reset();
    h.expect(dut.push_ready, "reset push_ready");
    h.expect(dut.count == 0, "reset count");
    h.expect(get_field(dut.dispatch, 0, 1) == 0, "empty dispatch");

    // Push one W-lane group.
    for (int l = 0; l < W; ++l) h.push(l, 0x100 + 4 * l, 0x12340000u + l, 1 + l, l);
    dut.push_valid = 1;
    h.tick();
    dut.push_valid = 0;
    h.expect(dut.count == 1, "push count");
    h.expect(get_field(dut.dispatch, 0, 1) == 1, "dispatch lane0 valid");
    h.expect(get_field(dut.dispatch, 1, 32) == 0x100, "dispatch lane0 pc");
    h.expect(get_field(dut.dispatch, 122, PRF) == 1, "dispatch lane0 dest");
    if (W > 1) {
        h.expect(get_field(dut.dispatch, DW + 1, 32) == 0x104, "dispatch lane1 pc");
        h.expect(get_field(dut.dispatch, DW + 122, PRF) == 2, "dispatch lane1 dest");
    }

    // backend_ready pops one group.
    dut.backend_ready = 1;
    h.tick();
    dut.backend_ready = 0;
    h.expect(dut.count == 0, "pop count");
    h.expect(get_field(dut.dispatch, 0, 1) == 0, "pop dispatch empty");

    // Fill queue to DEPTH, then push_ready=0.
    for (int g = 0; g < 8; ++g) {
        for (int l = 0; l < W; ++l) h.push(l, 0x200 + 4 * g + l, 0x55, g, g);
        dut.push_valid = 1;
        h.tick();
        dut.push_valid = 0;
    }
    h.expect(dut.count == 8, "full count");
    h.expect(!dut.push_ready, "full push_ready low");

    // commit/squash pass-through.
    dut.commit_in = 0x5a5;
    dut.squash_in = 0x2a;
    dut.eval();
    h.expect((uint32_t)dut.commit_out == 0x5a5, "commit pass-through");
    h.expect((uint32_t)dut.squash_out == 0x2a, "squash pass-through");

    h.reset();
    h.expect(dut.count == 0 && dut.push_ready, "reset again");

    printf("\nW=%d checked=%ld fails=%ld\n", W, h.checks, h.fails);
    bool pass = h.fails == 0;
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}
