// -----------------------------------------------------------------------------
// backend_tb.cpp — full backend smoke/integration test.
//
// Drives the frozen dispatch/commit/squash buses and observes cdb/complete/
// br_update.  Covers ALU chain, load/store, branch/JAL, squash, IQ full
// backpressure, and W=2 dispatch absorption (IW stays 1 in P1).
// -----------------------------------------------------------------------------

#include "Vbackend_ooo.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>

#ifndef TB_W
#define TB_W 1
#endif

namespace {

constexpr int W = TB_W;
constexpr int IW = 1;
constexpr int PRF = 6;
constexpr int LSQ = 3;
constexpr int ROB = 5;
constexpr int DW = 124 + 3 * PRF + LSQ + ROB;
constexpr int DISP_WORDS = (W * DW + 31) / 32;
constexpr int BR_WORDS = (73 + 31) / 32;

constexpr uint32_t A_REG = 0, A_PC = 1, A_ZERO = 2;
constexpr uint32_t B_REG = 0, B_IMM = 1;
constexpr uint32_t WB_ALU = 0, WB_MEM = 1, WB_PC4 = 2;
constexpr uint32_t ALU_ADD = 0, ALU_SUB = 1;

constexpr int C_VALID = 0, C_TAG = 1, C_STORE = 1 + PRF,
              C_LOAD = 2 + PRF, C_LSQ = 3 + PRF;
constexpr int S_VALID = 0, S_ROB = 1;
constexpr int B_VALID = 0, B_PC = 1, B_TAKEN = 33, B_TARGET = 34,
              B_JALR = 66, B_TAG = 67;

enum : int {
    O_VALID = 0, O_PC = 1, O_INST = 33, O_IMM = 65, O_RD = 97,
    O_REG_WE = 102, O_ALU = 103, O_A_SEL = 108, O_B_SEL = 110,
    O_WB = 111, O_BR = 113, O_JAL = 114, O_JALR = 115, O_LOAD = 116,
    O_STORE = 117, O_ILLEGAL = 118, O_MEM_SIZE = 119, O_MEM_UNS = 121,
    O_DEST = 122, O_S1 = 128, O_S1R = 134, O_S2 = 135, O_S2R = 141,
    O_LSQ = 142, O_ROB = 145,
};

struct Uop {
    uint32_t pc = 0;
    uint32_t inst = 0;
    uint32_t imm = 0;
    uint32_t rd = 0;
    uint32_t reg_we = 0;
    uint32_t alu = ALU_ADD;
    uint32_t a_sel = A_REG;
    uint32_t b_sel = B_REG;
    uint32_t wb_sel = WB_ALU;
    uint32_t is_branch = 0;
    uint32_t is_jal = 0;
    uint32_t is_jalr = 0;
    uint32_t is_load = 0;
    uint32_t is_store = 0;
    uint32_t illegal = 0;
    uint32_t mem_size = 2;
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

template <typename T>
void set_int(T& vec, int offset, int width, uint32_t value) {
    uint32_t mask = (width >= 32) ? 0xffffffffu : ((1u << width) - 1u);
    uint32_t all = (uint32_t)vec;
    all = (all & ~(mask << offset)) | ((value & mask) << offset);
    vec = (T)all;
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
    Vbackend_ooo* dut = nullptr;
    uint8_t mem[1 << 16] = {};
    bool auto_respond = true;
    long checks = 0;
    long fails = 0;
    bool br_seen = false;
    uint32_t br_tag_seen = 0, br_taken_seen = 0, br_target_seen = 0;

    void tick() {
        dut->clk = 0;
        dut->eval();
        if (auto_respond && dut->data_req_valid) {
            if (dut->data_req_we)
                write_word(dut->data_req_addr, dut->data_req_wdata, (uint8_t)dut->data_req_wstrb);
            uint32_t value = dut->data_req_we ? 0 : read_word(dut->data_req_addr);
            dut->data_resp_valid = 1;
            dut->data_resp_rdata = value;
        } else {
            dut->data_resp_valid = 0;
        }
        dut->eval();
        dut->clk = 1;
        dut->eval();
        dut->data_resp_valid = 0;
        dut->eval();
    }

    uint32_t read_word(uint32_t addr) {
        uint32_t a = addr & 0xffff;
        return (uint32_t)mem[a] | ((uint32_t)mem[(a + 1) & 0xffff] << 8) |
               ((uint32_t)mem[(a + 2) & 0xffff] << 16) |
               ((uint32_t)mem[(a + 3) & 0xffff] << 24);
    }

    void write_word(uint32_t addr, uint32_t value, uint8_t strb) {
        uint32_t a = addr & 0xffff;
        for (int lane = 0; lane < 4; ++lane)
            if (strb & (1u << lane))
                mem[(a + lane) & 0xffff] = (uint8_t)(value >> (8 * lane));
    }

    void clear_dispatch() {
        for (int i = 0; i < DISP_WORDS; ++i) dut->dispatch[i] = 0;
    }

    void clear_commit() { dut->commit = 0; }
    void clear_squash() { dut->squash = 0; }

    void reset() {
        dut->reset = 1;
        clear_dispatch();
        clear_commit();
        clear_squash();
        dut->data_resp_valid = 0;
        for (int i = 0; i < 4; ++i) tick();
        dut->reset = 0;
        tick();
    }

    void pack(int lane, const Uop& u) {
        int base = lane * DW;
        set_field(dut->dispatch, base + O_VALID, 1, 1);
        set_field(dut->dispatch, base + O_PC, 32, u.pc);
        set_field(dut->dispatch, base + O_INST, 32, u.inst);
        set_field(dut->dispatch, base + O_IMM, 32, u.imm);
        set_field(dut->dispatch, base + O_RD, 5, u.rd);
        set_field(dut->dispatch, base + O_REG_WE, 1, u.reg_we);
        set_field(dut->dispatch, base + O_ALU, 5, u.alu);
        set_field(dut->dispatch, base + O_A_SEL, 2, u.a_sel);
        set_field(dut->dispatch, base + O_B_SEL, 1, u.b_sel);
        set_field(dut->dispatch, base + O_WB, 2, u.wb_sel);
        set_field(dut->dispatch, base + O_BR, 1, u.is_branch);
        set_field(dut->dispatch, base + O_JAL, 1, u.is_jal);
        set_field(dut->dispatch, base + O_JALR, 1, u.is_jalr);
        set_field(dut->dispatch, base + O_LOAD, 1, u.is_load);
        set_field(dut->dispatch, base + O_STORE, 1, u.is_store);
        set_field(dut->dispatch, base + O_ILLEGAL, 1, u.illegal);
        set_field(dut->dispatch, base + O_MEM_SIZE, 2, u.mem_size);
        set_field(dut->dispatch, base + O_MEM_UNS, 1, u.mem_uns);
        set_field(dut->dispatch, base + O_DEST, PRF, u.dest);
        set_field(dut->dispatch, base + O_S1, PRF, u.src1);
        set_field(dut->dispatch, base + O_S1R, 1, u.src1_ready);
        set_field(dut->dispatch, base + O_S2, PRF, u.src2);
        set_field(dut->dispatch, base + O_S2R, 1, u.src2_ready);
        set_field(dut->dispatch, base + O_LSQ, LSQ, u.lsq);
        set_field(dut->dispatch, base + O_ROB, ROB, u.rob);
    }

    bool dispatch_one(const Uop& u) {
        clear_dispatch();
        pack(0, u);
        dut->eval();
        if (!dut->backend_ready) return false;
        tick();
        clear_dispatch();
        return true;
    }

    bool dispatch_group(const Uop* u) {
        clear_dispatch();
        for (int lane = 0; lane < W; ++lane) pack(lane, u[lane]);
        dut->eval();
        if (!dut->backend_ready) return false;
        tick();
        clear_dispatch();
        return true;
    }

    void commit_one(uint32_t lsq, bool is_store, bool is_load) {
        clear_commit();
        set_int(dut->commit, C_VALID, 1, 1);
        set_int(dut->commit, C_TAG, PRF, 0);
        set_int(dut->commit, C_STORE, 1, is_store);
        set_int(dut->commit, C_LOAD, 1, is_load);
        set_int(dut->commit, C_LSQ, LSQ, lsq);
        tick();
        clear_commit();
    }

    void squash_one(uint32_t rob) {
        set_int(dut->squash, S_VALID, 1, 1);
        set_int(dut->squash, S_ROB, ROB, rob);
        tick();
        clear_squash();
    }

    bool wait_cdb(uint32_t& tag, uint32_t& value, int limit = 128) {
        for (int n = 0; n < limit; ++n) {
            tick();
            uint64_t lane = (uint64_t)dut->cdb;
            if (get_field(dut->br_update, B_VALID, 1)) {
                br_seen = true;
                br_tag_seen = get_field(dut->br_update, B_TAG, PRF);
                br_taken_seen = get_field(dut->br_update, B_TAKEN, 1);
                br_target_seen = get_field(dut->br_update, B_TARGET, 32);
            }
            if (lane & 1) {
                tag = (uint32_t)((lane >> 1) & 0x3f);
                value = (uint32_t)((lane >> 7) & 0xffffffffu);
                return true;
            }
        }
        return false;
    }

    bool wait_complete_and_branch(uint32_t& ctag, uint32_t& btag,
                                  uint32_t& taken, uint32_t& target,
                                  int limit = 128) {
        for (int n = 0; n < limit; ++n) {
            tick();
            uint32_t comp = (uint32_t)dut->complete;
            if (comp & 1) ctag = (comp >> 1) & 0x3f;
            if (get_field(dut->br_update, B_VALID, 1)) {
                btag = get_field(dut->br_update, B_TAG, PRF);
                taken = get_field(dut->br_update, B_TAKEN, 1);
                target = get_field(dut->br_update, B_TARGET, 32);
                return true;
            }
        }
        return false;
    }

    void expect(bool ok, const char* what) {
        ++checks;
        if (!ok) {
            ++fails;
            printf("FAIL: %s\n", what);
        }
    }
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vbackend_ooo dut;
    Harness h;
    h.dut = &dut;
    h.reset();
    h.expect(dut.backend_ready, "reset backend_ready");

    // ---- ALU: addi x1, x0, 5 ---------------------------------------------
    Uop addi;
    addi.pc = 0x100;
    addi.inst = 0x00500093;  // addi x1, x0, 5
    addi.imm = 5;
    addi.rd = 1; addi.reg_we = 1; addi.dest = 1;
    addi.a_sel = A_REG; addi.b_sel = B_IMM; addi.wb_sel = WB_ALU;
    addi.rob = 1;
    h.expect(h.dispatch_one(addi), "addi dispatch");
    uint32_t tag = 0, value = 0;
    h.expect(h.wait_cdb(tag, value), "addi cdb");
    h.expect(tag == 1 && value == 5, "addi result");

    // ---- dependent add x2, x1, x1 ----------------------------------------
    Uop add;
    add.pc = 0x104;
    add.inst = 0x00108133;  // add x2, x1, x1
    add.rd = 2; add.reg_we = 1; add.dest = 2;
    add.src1 = 1; add.src1_ready = 1;
    add.src2 = 1; add.src2_ready = 1;
    add.a_sel = A_REG; add.b_sel = B_REG; add.wb_sel = WB_ALU;
    add.rob = 2;
    h.expect(h.dispatch_one(add), "add dispatch");
    h.expect(h.wait_cdb(tag, value), "add cdb");
    h.expect(tag == 2 && value == 10, "add result");

    // ---- divider: div x4, x2, x1 = 10 / 5 = 2 ----------------------------
    Uop divu;
    divu.pc = 0x106;
    divu.inst = 0x02114233;  // div x4, x2, x1
    divu.rd = 4; divu.reg_we = 1; divu.dest = 4;
    divu.alu = 14;  // ALU_DIV
    divu.src1 = 2; divu.src1_ready = 1;
    divu.src2 = 1; divu.src2_ready = 1;
    divu.a_sel = A_REG; divu.b_sel = B_REG; divu.wb_sel = WB_ALU;
    divu.rob = 3;
    h.expect(h.dispatch_one(divu), "div dispatch");
    h.expect(h.wait_cdb(tag, value), "div cdb");
    h.expect(tag == 4 && value == 2, "div result");

    // ---- load word --------------------------------------------------------
    h.write_word(0x2000, 0xdeadbeef, 0xf);
    Uop ld;
    ld.pc = 0x108;
    ld.inst = 0x00002083;  // lw x1, 0(x0)
    ld.imm = 0x2000; ld.rd = 3; ld.reg_we = 1; ld.dest = 3;
    ld.is_load = 1; ld.wb_sel = WB_MEM; ld.mem_size = 2;
    ld.a_sel = A_REG; ld.b_sel = B_IMM; ld.lsq = 0; ld.rob = 3;
    h.expect(h.dispatch_one(ld), "load dispatch");
    h.expect(h.wait_cdb(tag, value), "load cdb");
    h.expect(tag == 3 && value == 0xdeadbeef, "load result");
    h.commit_one(0, false, true);

    // ---- store x1 (value 5) to 0x3000 ------------------------------------
    Uop st;
    st.pc = 0x10c;
    st.inst = 0x00102023;  // sw x1, 0(x0)
    st.imm = 0x3000; st.is_store = 1; st.mem_size = 2;
    st.src1 = 0; st.src1_ready = 1;
    st.src2 = 1; st.src2_ready = 1;
    st.a_sel = A_REG; st.b_sel = B_IMM; st.lsq = 1; st.rob = 4;
    h.expect(h.dispatch_one(st), "store dispatch");
    // Wait for store complete (complete bus lane 0).
    bool saw_complete = false;
    for (int n = 0; n < 8 && !saw_complete; ++n) {
        h.tick();
        if ((uint32_t)dut.complete & 1) saw_complete = true;
    }
    h.expect(saw_complete, "store complete");
    h.commit_one(1, true, false);
    for (int n = 0; n < 16; ++n) h.tick();
    h.expect(h.read_word(0x3000) == 5, "store write data");

    // ---- taken branch: beq x0, x0, +0x20 ---------------------------------
    Uop br;
    br.pc = 0x400;
    br.inst = 0x00000063;  // beq x0, x0, 0x20
    br.imm = 0x20; br.is_branch = 1; br.dest = 7; br.rob = 5;
    br.src1 = 0; br.src1_ready = 1; br.src2 = 0; br.src2_ready = 1;
    h.expect(h.dispatch_one(br), "branch dispatch");
    uint32_t ctag = 0, btag = 0, taken = 0, target = 0;
    h.expect(h.wait_complete_and_branch(ctag, btag, taken, target), "branch event");
    h.expect(ctag == 7, "branch complete tag");
    h.expect(btag == 7 && taken == 1 && target == 0x420, "branch update");

    // ---- JAL x8, +0x40 ---------------------------------------------------
    Uop jal;
    jal.pc = 0x500;
    jal.inst = 0x0400046f;  // jal x8, 0x40
    jal.imm = 0x40; jal.is_jal = 1; jal.reg_we = 1; jal.dest = 8;
    jal.wb_sel = WB_PC4; jal.rob = 6;
    h.expect(h.dispatch_one(jal), "jal dispatch");
    h.br_seen = false;
    h.expect(h.wait_cdb(tag, value), "jal cdb");
    h.expect(tag == 8 && value == 0x504, "jal link value");
    h.expect(h.br_seen && h.br_tag_seen == 8 && h.br_taken_seen == 1 &&
             h.br_target_seen == 0x540, "jal target");

    // ---- squash younger entry --------------------------------------------
    h.reset();
    Uop sq1; sq1.pc = 0x600; sq1.dest = 9; sq1.rob = 1; sq1.reg_we = 1;
    Uop sq2; sq2.pc = 0x604; sq2.dest = 10; sq2.rob = 2; sq2.reg_we = 1;
    if (W == 1) {
        h.expect(h.dispatch_one(sq1), "squash first dispatch");
        h.expect(h.dispatch_one(sq2), "squash second dispatch");
    } else {
        Uop pair[2] = {sq1, sq2};
        h.expect(h.dispatch_group(pair), "squash pair dispatch");
    }
    h.squash_one(1);
    bool saw_q2 = false;
    for (int n = 0; n < 16; ++n) {
        h.tick();
        if ((uint64_t)dut.cdb & 1) {
            uint32_t t = (uint32_t)(((uint64_t)dut.cdb >> 1) & 0x3f);
            if (t == 10) saw_q2 = true;
        }
    }
    h.expect(!saw_q2, "squash drops younger result");

    // ---- IQ full backpressure --------------------------------------------
    h.reset();
    Uop block;
    block.pc = 0x700; block.dest = 11; block.rob = 1; block.reg_we = 1;
    block.src1 = 20; block.src1_ready = 0;  // never woken
    int accepted = 0;
    for (int n = 0; n < 16 && accepted < 8; ++n) {
        if (h.dispatch_one(block)) ++accepted;
        else h.tick();
        block.rob = (block.rob + 1) & 31;
    }
    h.expect(accepted == 8, "filled issue queue");
    h.expect(!dut.backend_ready, "backend_ready low when IQ full");

    // ---- W=2 dispatch absorption -----------------------------------------
    if (W == 2) {
        h.reset();
        Uop w2[2];
        w2[0].pc = 0x800; w2[0].dest = 12; w2[0].rob = 1; w2[0].reg_we = 1;
        w2[1].pc = 0x804; w2[1].dest = 13; w2[1].rob = 2; w2[1].reg_we = 1;
        w2[1].imm = 7; w2[1].b_sel = B_IMM;
        h.expect(h.dispatch_group(w2), "W=2 dispatch");
        h.expect(h.wait_cdb(tag, value), "W=2 first cdb");
        h.expect(tag == 12, "W=2 first tag");
        h.expect(h.wait_cdb(tag, value), "W=2 second cdb");
        h.expect(tag == 13 && value == 7, "W=2 second value");
    }

    printf("\nW=%d checked=%ld fails=%ld\n", W, h.checks, h.fails);
    bool pass = (h.fails == 0);
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}
