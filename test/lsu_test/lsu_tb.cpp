// -----------------------------------------------------------------------------
// lsu_tb.cpp — LSU + LSQ v1 integration test.
//
// Covers: store completion + commit drain, load word/byte/half formatting,
// load ordering behind an older store (same word blocks, different word does
// not), squash of waiting/in-flight loads, LSQ id backpressure, and reset.
// -----------------------------------------------------------------------------

#include "Vlsu.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>

namespace {

constexpr int PRF = 6;
constexpr int LSQ = 3;
constexpr int ROB = 5;
constexpr int DW = 124 + 3 * PRF + LSQ + ROB;
constexpr int IN_WORDS = (DW + 31) / 32;
constexpr uint32_t BYTE = 0, HALF = 1, WORD = 2;

enum : int {
    O_PC = 1, O_INST = 33, O_IMM = 65, O_RD = 97, O_REG_WE = 102,
    O_ALU = 103, O_A_SEL = 108, O_B_SEL = 110, O_WB = 111,
    O_BR = 113, O_JAL = 114, O_JALR = 115, O_LOAD = 116, O_STORE = 117,
    O_ILLEGAL = 118, O_MEM_SIZE = 119, O_MEM_UNS = 121,
    O_DEST = 122, O_S1 = 128, O_S1R = 134, O_S2 = 135, O_S2R = 141,
    O_LSQ = 142, O_ROB = 145,
};

struct Uop {
    uint32_t imm = 0;
    uint32_t dest = 0;
    uint32_t is_load = 0;
    uint32_t is_store = 0;
    uint32_t illegal = 0;
    uint32_t mem_size = WORD;
    uint32_t mem_uns = 0;
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

struct Harness {
    Vlsu* dut = nullptr;
    uint8_t mem[1 << 16] = {};
    bool auto_respond = true;
    long checks = 0;
    long fails = 0;

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

    void clear_inputs() {
        dut->alloc_valid = 0;
        dut->alloc_id = 0;
        dut->alloc_rob = 0;
        dut->alloc_is_store = 0;
        dut->issue_valid = 0;
        for (int i = 0; i < IN_WORDS; ++i) dut->issue_uop[i] = 0;
        dut->issue_src1 = 0;
        dut->issue_src2 = 0;
        dut->commit_valid = 0;
        dut->commit_is_store = 0;
        dut->commit_is_load = 0;
        dut->commit_id = 0;
        dut->squash_valid = 0;
        dut->squash_rob_idx = 0;
        dut->load_result_ready = 0;
        dut->data_resp_valid = 0;
        dut->data_resp_rdata = 0;
    }

    void reset() {
        dut->reset = 1;
        clear_inputs();
        for (int i = 0; i < 3; ++i) tick();
        dut->reset = 0;
        tick();
    }

    void pack(const Uop& u) {
        for (int i = 0; i < IN_WORDS; ++i) dut->issue_uop[i] = 0;
        set_field(dut->issue_uop, O_IMM, 32, u.imm);
        set_field(dut->issue_uop, O_DEST, PRF, u.dest);
        set_field(dut->issue_uop, O_LOAD, 1, u.is_load);
        set_field(dut->issue_uop, O_STORE, 1, u.is_store);
        set_field(dut->issue_uop, O_ILLEGAL, 1, u.illegal);
        set_field(dut->issue_uop, O_MEM_SIZE, 2, u.mem_size);
        set_field(dut->issue_uop, O_MEM_UNS, 1, u.mem_uns);
        set_field(dut->issue_uop, O_LSQ, LSQ, u.lsq);
        set_field(dut->issue_uop, O_ROB, ROB, u.rob);
    }

    bool alloc(uint32_t id, uint32_t rob, bool is_store) {
        clear_inputs();
        dut->alloc_valid = 1;
        dut->alloc_id = id;
        dut->alloc_rob = rob;
        dut->alloc_is_store = is_store ? 1 : 0;
        dut->eval();
        bool ok = dut->alloc_ready;
        tick();
        clear_inputs();
        return ok;
    }

    bool issue(const Uop& u, uint32_t src1, uint32_t src2) {
        clear_inputs();
        pack(u);
        dut->issue_valid = 1;
        dut->issue_src1 = src1;
        dut->issue_src2 = src2;
        dut->eval();
        if (!dut->issue_ready) return false;
        tick();
        clear_inputs();
        return true;
    }

    void commit(uint32_t id, bool is_store, bool is_load) {
        clear_inputs();
        dut->commit_valid = 1;
        dut->commit_id = id;
        dut->commit_is_store = is_store ? 1 : 0;
        dut->commit_is_load = is_load ? 1 : 0;
        tick();
        clear_inputs();
    }

    void squash(uint32_t rob) {
        clear_inputs();
        dut->squash_valid = 1;
        dut->squash_rob_idx = rob;
        tick();
        clear_inputs();
    }

    void wait_store_done() {
        for (int i = 0; i < 64; ++i) {
            tick();
            if (!dut->busy && !dut->data_req_valid) return;
        }
        expect(false, "store drain timeout");
    }

    bool wait_load_result(uint32_t want, uint32_t want_tag, const char* tag) {
        for (int i = 0; i < 64; ++i) {
            tick();
            if (dut->load_result_valid) {
                bool ok = (dut->load_result_value == want) &&
                          (dut->load_result_tag == want_tag) &&
                          !dut->load_result_exception;
                expect(ok, tag);
                if (!ok)
                    printf("  [%s] got=%08x tag=%u exc=%u want=%08x tag=%u\n",
                           tag, (uint32_t)dut->load_result_value,
                           (uint32_t)dut->load_result_tag,
                           (uint32_t)dut->load_result_exception, want, want_tag);
                clear_inputs();
                dut->load_result_ready = 1;
                tick();
                clear_inputs();
                return ok;
            }
        }
        expect(false, "load result timeout");
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
    Vlsu dut;
    Harness h;
    h.dut = &dut;
    h.reset();

    // ---- store: issue -> complete -> commit -> drain ----------------------
    h.expect(h.alloc(0, 1, true), "store alloc");
    Uop st;
    st.dest = 2; st.is_store = 1; st.lsq = 0; st.rob = 1;
    st.imm = 0x10; st.mem_size = WORD;
    h.expect(h.issue(st, 0x1000, 0xdeadbeef), "store issue");
    h.expect(dut.store_complete_valid, "store complete pulse");
    h.expect(dut.store_complete_tag == 2, "store complete tag");
    h.expect(!dut.data_req_valid, "store does not write before commit");
    h.tick();  // let the complete pulse pass
    h.commit(0, true, false);
    h.wait_store_done();
    h.expect(h.read_word(0x1010) == 0xdeadbeef, "store drain data");
    h.expect(h.alloc(0, 2, false), "store id freed");

    // ---- load word --------------------------------------------------------
    h.reset();
    h.write_word(0x2000, 0x81234567, 0xf);
    h.expect(h.alloc(0, 1, false), "load alloc");
    Uop ld;
    ld.dest = 5; ld.is_load = 1; ld.lsq = 0; ld.rob = 1;
    ld.imm = 0; ld.mem_size = WORD;
    h.expect(h.issue(ld, 0x2000, 0), "load issue");
    h.wait_load_result(0x81234567, 5, "load word");
    h.commit(0, false, true);
    h.expect(h.alloc(0, 2, false), "load id freed");

    // ---- load byte / half sign and zero extension -------------------------
    h.reset();
    h.write_word(0x3000, 0x00000180, 0xf);
    struct LoadCase { uint32_t size, uns, want; const char* name; };
    const LoadCase cases[] = {
        {BYTE, 0, 0xffffff80u, "LB"},
        {BYTE, 1, 0x00000080u, "LBU"},
        {HALF, 0, 0x00000180u, "LH"},
        {HALF, 1, 0x00000180u, "LHU"},
    };
    uint32_t rob = 1, id = 0;
    for (const LoadCase& c : cases) {
        h.expect(h.alloc(id, rob, false), c.name);
        Uop u;
        u.dest = 7; u.is_load = 1; u.lsq = id; u.rob = rob;
        u.imm = 0; u.mem_size = c.size; u.mem_uns = c.uns;
        h.expect(h.issue(u, 0x3000, 0), "load case issue");
        h.wait_load_result(c.want, 7, c.name);
        h.commit(id, false, true);
        id = (id + 1) & 7;
        rob = (rob + 1) & 31;
    }

    // ---- older same-word store blocks load until it is written -----------
    h.reset();
    h.expect(h.alloc(0, 1, true), "order store alloc");
    Uop os;
    os.dest = 2; os.is_store = 1; os.lsq = 0; os.rob = 1;
    os.imm = 0; os.mem_size = WORD;
    h.expect(h.issue(os, 0x4000, 0x11223344), "order store issue");
    h.tick();
    h.expect(h.alloc(1, 2, false), "order load alloc");
    Uop ol;
    ol.dest = 6; ol.is_load = 1; ol.lsq = 1; ol.rob = 2;
    ol.imm = 0; ol.mem_size = WORD;
    h.expect(h.issue(ol, 0x4000, 0), "order load issue");
    h.auto_respond = false;
    for (int i = 0; i < 4; ++i) {
        h.tick();
        h.expect(!dut.data_req_valid, "load blocked by older same-word store");
    }
    h.auto_respond = true;
    h.commit(0, true, false);
    h.wait_store_done();
    h.wait_load_result(0x11223344, 6, "ordered load value");
    h.commit(1, false, true);

    // ---- different-word older store does not block -----------------------
    h.reset();
    h.expect(h.alloc(0, 1, true), "diff store alloc");
    Uop ds;
    ds.dest = 2; ds.is_store = 1; ds.lsq = 0; ds.rob = 1;
    ds.imm = 0; ds.mem_size = WORD;
    h.expect(h.issue(ds, 0x5000, 0xaabbccdd), "diff store issue");
    h.tick();
    h.expect(h.alloc(1, 2, false), "diff load alloc");
    Uop dl;
    dl.dest = 6; dl.is_load = 1; dl.lsq = 1; dl.rob = 2;
    dl.imm = 0; dl.mem_size = WORD;
    h.write_word(0x6000, 0x55667788, 0xf);
    h.expect(h.issue(dl, 0x6000, 0), "diff load issue");
    h.wait_load_result(0x55667788, 6, "different word load");
    h.commit(1, false, true);
    h.commit(0, true, false);
    h.wait_store_done();

    // ---- squash waiting load ---------------------------------------------
    h.reset();
    h.expect(h.alloc(0, 1, true), "sq store alloc");
    Uop qs;
    qs.dest = 2; qs.is_store = 1; qs.lsq = 0; qs.rob = 1;
    qs.imm = 0; qs.mem_size = WORD;
    h.expect(h.issue(qs, 0x7000, 0x12345678), "sq store issue");
    h.tick();
    h.expect(h.alloc(1, 2, false), "sq load alloc");
    Uop ql;
    ql.dest = 7; ql.is_load = 1; ql.lsq = 1; ql.rob = 2;
    ql.imm = 0; ql.mem_size = WORD;
    h.expect(h.issue(ql, 0x7000, 0), "sq load issue");
    h.auto_respond = false;
    h.tick();
    h.squash(2);
    h.auto_respond = true;
    for (int i = 0; i < 4; ++i) {
        h.tick();
        h.expect(!dut.load_result_valid, "squashed waiting load no result");
    }
    h.commit(0, true, false);
    h.wait_store_done();

    // ---- squash in-flight load -------------------------------------------
    h.reset();
    h.expect(h.alloc(0, 2, false), "if load alloc");
    Uop il;
    il.dest = 8; il.is_load = 1; il.lsq = 0; il.rob = 2;
    il.imm = 0; il.mem_size = WORD;
    h.write_word(0x8000, 0x9999aaa, 0xf);
    h.expect(h.issue(il, 0x8000, 0), "if load issue");
    h.auto_respond = false;
    for (int i = 0; i < 8 && !dut.data_req_valid; ++i) h.tick();
    h.expect(dut.data_req_valid, "in-flight load request");
    h.clear_inputs();
    dut.squash_valid = 1;
    dut.squash_rob_idx = 1;
    h.auto_respond = true;
    h.tick();
    h.clear_inputs();
    for (int i = 0; i < 4; ++i) {
        h.tick();
        h.expect(!dut.load_result_valid, "squashed in-flight load no result");
    }

    // ---- LSQ id backpressure ---------------------------------------------
    h.reset();
    h.expect(h.alloc(0, 1, true), "bp alloc");
    Uop bp;
    bp.is_store = 1; bp.lsq = 0; bp.rob = 1; bp.mem_size = WORD;
    h.expect(h.issue(bp, 0x9000, 0x1), "bp issue");
    h.tick();
    h.expect(!h.alloc(0, 2, true), "duplicate lsq id rejected");

    // ---- reset ------------------------------------------------------------
    h.reset();
    h.expect(!dut.load_result_valid, "reset load result");
    h.expect(!dut.store_complete_valid, "reset store complete");

    printf("\nchecked=%ld fails=%ld\n", h.checks, h.fails);
    bool pass = (h.fails == 0);
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}
