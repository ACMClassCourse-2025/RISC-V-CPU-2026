// -----------------------------------------------------------------------------
// issue_queue_tb.cpp — issue queue behavior test.
//
// Build with -DTB_W / -DTB_R matching -DCPU_ISSUE_WIDTH / -DCPU_CDB_NUM.
// IW is fixed at 1 for P1.  Covers dispatch, age order, CDB wake, dispatch/
// wake same-cycle bypass, squash, full backpressure, and reset.
// -----------------------------------------------------------------------------

#include "Vissue_queue.h"
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
constexpr int IW = 1;
constexpr int D = 8;                 // CPU_RS_DEPTH
constexpr int PRF = 6;               // CPU_PRF_IDX_W
constexpr int LSQ = 3;               // CPU_LSQ_IDX_W
constexpr int ROB = 5;               // CPU_ROB_TAG_W
constexpr int DW = 124 + 3 * PRF + LSQ + ROB;
constexpr int IN_WORDS = (W * DW + 31) / 32;
constexpr int OUT_WORDS = (IW * DW + 31) / 32;

// Field offsets from verilog/if_defs.sv.
enum : int {
    O_PC = 1, O_INST = 33, O_IMM = 65, O_RD = 97, O_REG_WE = 102,
    O_ALU = 103, O_A_SEL = 108, O_B_SEL = 110, O_WB = 111,
    O_BR = 113, O_JAL = 114, O_JALR = 115, O_LOAD = 116, O_STORE = 117,
    O_ILLEGAL = 118, O_MEM_SIZE = 119, O_MEM_UNS = 121,
    O_DEST = 122, O_S1 = 128, O_S1R = 134, O_S2 = 135, O_S2R = 141,
    O_LSQ = 142, O_ROB = 145,
};

struct Uop {
    uint32_t pc = 0;
    uint32_t inst = 0;
    uint32_t imm = 0;
    uint32_t rd = 0;
    uint32_t reg_we = 0;
    uint32_t alu = 0;
    uint32_t a_sel = 0;
    uint32_t b_sel = 0;
    uint32_t wb = 0;
    uint32_t is_branch = 0;
    uint32_t is_jal = 0;
    uint32_t is_jalr = 0;
    uint32_t is_load = 0;
    uint32_t is_store = 0;
    uint32_t illegal = 0;
    uint32_t mem_size = 0;
    uint32_t mem_uns = 0;
    uint32_t dest = 0;
    uint32_t src1 = 0;
    uint32_t src1_ready = 1;
    uint32_t src2 = 0;
    uint32_t src2_ready = 1;
    uint32_t lsq = 0;
    uint32_t rob = 0;
};

template <typename Vec>
void set_field(Vec& vec, int offset, int width, uint32_t value) {
    for (int b = 0; b < width; ++b) {
        int bit = offset + b;
        int word = bit / 32;
        int shift = bit % 32;
        if ((value >> b) & 1u) vec[word] |= (1u << shift);
        else vec[word] &= ~(1u << shift);
    }
}

template <typename Vec>
uint32_t get_field(const Vec& vec, int offset, int width) {
    uint32_t value = 0;
    for (int b = 0; b < width; ++b) {
        int bit = offset + b;
        int word = bit / 32;
        int shift = bit % 32;
        value |= ((vec[word] >> shift) & 1u) << b;
    }
    return value;
}

struct Harness {
    Vissue_queue* dut = nullptr;
    long checks = 0;
    long fails = 0;

    void tick() {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
    }

    void clear_inputs() {
        dut->in_valid = 0;
        for (int i = 0; i < IN_WORDS; ++i) dut->in_uop[i] = 0;
        dut->wake_valid = 0;
        dut->wake_tag = 0;
        dut->squash_valid = 0;
        dut->squash_rob_idx = 0;
        dut->out_ready = 0;
    }

    void reset() {
        dut->reset = 1;
        clear_inputs();
        for (int i = 0; i < 3; ++i) tick();
        dut->reset = 0;
        tick();
    }

    void pack(int lane, const Uop& u) {
        int base = lane * DW;
        set_field(dut->in_uop, base + O_PC, 32, u.pc);
        set_field(dut->in_uop, base + O_INST, 32, u.inst);
        set_field(dut->in_uop, base + O_IMM, 32, u.imm);
        set_field(dut->in_uop, base + O_RD, 5, u.rd);
        set_field(dut->in_uop, base + O_REG_WE, 1, u.reg_we);
        set_field(dut->in_uop, base + O_ALU, 5, u.alu);
        set_field(dut->in_uop, base + O_A_SEL, 2, u.a_sel);
        set_field(dut->in_uop, base + O_B_SEL, 1, u.b_sel);
        set_field(dut->in_uop, base + O_WB, 2, u.wb);
        set_field(dut->in_uop, base + O_BR, 1, u.is_branch);
        set_field(dut->in_uop, base + O_JAL, 1, u.is_jal);
        set_field(dut->in_uop, base + O_JALR, 1, u.is_jalr);
        set_field(dut->in_uop, base + O_LOAD, 1, u.is_load);
        set_field(dut->in_uop, base + O_STORE, 1, u.is_store);
        set_field(dut->in_uop, base + O_ILLEGAL, 1, u.illegal);
        set_field(dut->in_uop, base + O_MEM_SIZE, 2, u.mem_size);
        set_field(dut->in_uop, base + O_MEM_UNS, 1, u.mem_uns);
        set_field(dut->in_uop, base + O_DEST, PRF, u.dest);
        set_field(dut->in_uop, base + O_S1, PRF, u.src1);
        set_field(dut->in_uop, base + O_S1R, 1, u.src1_ready);
        set_field(dut->in_uop, base + O_S2, PRF, u.src2);
        set_field(dut->in_uop, base + O_S2R, 1, u.src2_ready);
        set_field(dut->in_uop, base + O_LSQ, LSQ, u.lsq);
        set_field(dut->in_uop, base + O_ROB, ROB, u.rob);
    }

    // Dispatch one uop through lane 0 and wait until it is accepted.
    bool dispatch_one(const Uop& u) {
        clear_inputs();
        pack(0, u);
        dut->in_valid = 1;
        dut->eval();
        if (!dut->in_ready) return false;
        tick();
        clear_inputs();
        return true;
    }

    // Dispatch W uops in one cycle; all lanes must be accepted.
    bool dispatch_group(const Uop* uops) {
        clear_inputs();
        uint32_t mask = 0;
        for (int lane = 0; lane < W; ++lane) {
            pack(lane, uops[lane]);
            mask |= 1u << lane;
        }
        dut->in_valid = mask;
        dut->eval();
        if (!dut->in_ready) return false;
        tick();
        clear_inputs();
        return true;
    }

    bool out_valid() const { return (dut->out_valid >> 0) & 1; }
    uint32_t out_field(int off, int width) {
        return get_field(dut->out_uop, off, width);
    }

    void expect(bool ok, const char* what) {
        ++checks;
        if (!ok) {
            ++fails;
            printf("FAIL: %s\n", what);
        }
    }

    void issue_one() {
        clear_inputs();
        dut->out_ready = 1;
        dut->eval();
        tick();
        clear_inputs();
    }
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vissue_queue dut;
    Harness h;
    h.dut = &dut;
    h.reset();

    h.expect(dut.count == 0, "reset count");
    h.expect(dut.free_count == D, "reset free count");

    // ---- single dispatch / issue -----------------------------------------
    Uop a;
    a.pc = 0x100; a.inst = 0x12345678; a.dest = 5; a.rob = 1;
    h.expect(h.dispatch_one(a), "single dispatch accepted");
    h.expect(dut.count == 1, "single count");
    dut.eval();
    h.expect(h.out_valid(), "single issue valid");
    h.expect(h.out_field(O_PC, 32) == 0x100, "single pc");
    h.expect(h.out_field(O_INST, 32) == 0x12345678, "single inst");
    h.expect(h.out_field(O_DEST, 6) == 5, "single dest");
    h.expect(h.out_field(O_ROB, 5) == 1, "single rob");
    h.issue_one();
    h.expect(dut.count == 0, "single issued");

    // ---- wakeup -----------------------------------------------------------
    Uop b;
    b.pc = 0x200; b.dest = 6; b.rob = 2;
    b.src1 = 7; b.src1_ready = 0;
    h.expect(h.dispatch_one(b), "wake dispatch");
    dut.eval();
    h.expect(!h.out_valid(), "not ready before wake");
    h.clear_inputs();
    dut.wake_valid = 1;
    dut.wake_tag = 7;
    h.tick();
    h.clear_inputs();
    dut.eval();
    h.expect(h.out_valid(), "woken after CDB");
    h.issue_one();

    // ---- dispatch + CDB same-cycle bypass --------------------------------
    Uop c;
    c.pc = 0x300; c.dest = 7; c.rob = 3;
    c.src1 = 9; c.src1_ready = 0;
    h.clear_inputs();
    h.pack(0, c);
    dut.in_valid = 1;
    dut.wake_valid = 1;
    dut.wake_tag = 9;
    dut.eval();
    h.expect(dut.in_ready, "bypass dispatch accepted");
    h.tick();
    h.clear_inputs();
    dut.eval();
    h.expect(h.out_valid(), "dispatch bypass wake");
    h.issue_one();

    // ---- age order --------------------------------------------------------
    h.reset();
    Uop old_u; old_u.pc = 0x400; old_u.rob = 1; old_u.dest = 8;
    Uop new_u; new_u.pc = 0x404; new_u.rob = 2; new_u.dest = 9;
    if (W == 1) {
        h.expect(h.dispatch_one(old_u), "age old dispatch");
        h.expect(h.dispatch_one(new_u), "age new dispatch");
    } else {
        Uop pair[2] = {old_u, new_u};
        h.expect(h.dispatch_group(pair), "age pair dispatch");
    }
    dut.eval();
    h.expect(h.out_valid(), "age issue valid");
    h.expect(h.out_field(O_PC, 32) == 0x400, "oldest first");
    h.issue_one();
    dut.eval();
    h.expect(h.out_field(O_PC, 32) == 0x404, "second after oldest");
    h.issue_one();

    // ---- squash -----------------------------------------------------------
    h.reset();
    for (int i = 0; i < 4; ++i) {
        Uop u;
        u.pc = 0x500 + 4 * i;
        u.rob = i + 1;
        u.dest = 10 + i;
        h.expect(h.dispatch_one(u), "squash dispatch");
    }
    h.expect(dut.count == 4, "squash filled");
    h.clear_inputs();
    dut.squash_valid = 1;
    dut.squash_rob_idx = 2;
    h.tick();
    h.clear_inputs();
    h.expect(dut.count == 2, "squash keeps boundary and older");
    dut.eval();
    h.expect(h.out_field(O_PC, 32) == 0x500, "squash oldest");
    h.issue_one();
    dut.eval();
    h.expect(h.out_field(O_PC, 32) == 0x504, "squash boundary retained");
    h.issue_one();
    h.expect(dut.count == 0, "squash drained");

    // ---- full backpressure ------------------------------------------------
    h.reset();
    for (int i = 0; i < D; ++i) {
        Uop u;
        u.pc = 0x600 + 4 * i;
        u.rob = i + 1;
        u.dest = 12;
        h.expect(h.dispatch_one(u), "fill dispatch");
    }
    h.expect(dut.count == D, "filled");
    h.expect(dut.free_count == 0, "no free slots");
    h.clear_inputs();
    h.pack(0, a);
    dut.in_valid = 1;
    dut.eval();
    h.expect(!dut.in_ready, "full rejects dispatch");
    h.issue_one();
    h.expect(dut.count == D - 1, "issue makes room");

    // ---- same-cycle squash + dispatch ------------------------------------
    h.reset();
    Uop s1; s1.pc = 0x700; s1.rob = 1; s1.dest = 13;
    Uop s2; s2.pc = 0x704; s2.rob = 2; s2.dest = 14;
    h.expect(h.dispatch_one(s1), "squash+dispatch first");
    h.expect(h.dispatch_one(s2), "squash+dispatch second");
    Uop s3; s3.pc = 0x708; s3.rob = 5; s3.dest = 15;
    h.clear_inputs();
    h.pack(0, s3);
    dut.in_valid = 1;
    dut.squash_valid = 1;
    dut.squash_rob_idx = 1;
    dut.eval();
    h.expect(dut.in_ready, "squash frees slot for dispatch");
    h.tick();
    h.clear_inputs();
    h.expect(dut.count == 2, "squash+dispatch count");

    // ---- reset ------------------------------------------------------------
    h.reset();
    h.expect(dut.count == 0, "reset clears");
    h.expect(dut.free_count == D, "reset free");

    printf("\nW=%d R=%d D=%d checked=%ld fails=%ld\n", W, R, D, h.checks, h.fails);
    bool pass = (h.fails == 0);
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}
