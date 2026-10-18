// -----------------------------------------------------------------------------
// rename_tb.cpp — verilog/rename.sv 的 Verilator 单元测试
//
// 参考模型独立维护 RAT/commit RAT/free/busy/LSQ 指针，逐拍与 RTL 比较：
//   - dest_tag / src tag / src_ready / old_tag / lsq_id；
//   - in_ready 的空闲表压力；
//   - commit 释放、wake 唤醒、W 路组内依赖；
//   - recover 掩码恢复。
//
// W 由 run.sh 的 -DCPU_ISSUE_WIDTH 与 -DTB_W 同步；默认 W=1，可跑 W=2。
// -----------------------------------------------------------------------------

#include "Vrename.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#ifndef TB_W
#define TB_W 1
#endif

namespace {

constexpr int W       = TB_W;
constexpr int PRF     = 64;
constexpr int PW      = 6;
constexpr int LSQ     = 8;
constexpr int LW      = 3;
constexpr int ROBW    = 5;
constexpr int DISPATCH_W = 124 + 3 * PW + LW + ROBW;
constexpr int RENAME_W   = 124 + 3 * PW + LW;
constexpr int DECODE_W   = 132;

// dispatch/rename 字段偏移
constexpr int PC_OFF = 1, INST_OFF = 33, IMM_OFF = 65, RD_OFF = 97;
constexpr int REG_WE_OFF = 102, ALU_OP_OFF = 103, A_SEL_OFF = 108;
constexpr int B_SEL_OFF = 110, WB_SEL_OFF = 111;
constexpr int IS_BRANCH_OFF = 113, IS_JAL_OFF = 114, IS_JALR_OFF = 115;
constexpr int IS_LOAD_OFF = 116, IS_STORE_OFF = 117, ILLEGAL_OFF = 118;
constexpr int MEM_SIZE_OFF = 119, MEM_UNSIGNED_OFF = 121;
constexpr int DEST_OFF = 122;
constexpr int SRC1_OFF = 122 + PW;
constexpr int SRC1_RDY_OFF = 122 + 2 * PW;
constexpr int SRC2_OFF = 123 + 2 * PW;
constexpr int SRC2_RDY_OFF = 123 + 3 * PW;
constexpr int LSQ_OFF = 124 + 3 * PW;
constexpr int D_RS1_OFF = 122;
constexpr int D_RS2_OFF = 127;

uint32_t rng_state = 0x20261018u;
uint32_t next_rand() {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

template <typename Sig>
void put_bits(Sig& sig, int off, uint32_t value, int bits) {
    for (int i = 0; i < bits; ++i) {
        int b = off + i;
        int w = b / 32;
        int s = b % 32;
        if ((value >> i) & 1u) sig[w] |= (1u << s);
        else                   sig[w] &= ~(1u << s);
    }
}

template <typename Sig>
uint32_t get_bits(const Sig& sig, int off, int bits) {
    uint32_t value = 0;
    for (int i = 0; i < bits; ++i) {
        int b = off + i;
        int w = b / 32;
        int s = b % 32;
        if ((sig[w] >> s) & 1u) value |= (1u << i);
    }
    return value;
}

struct Uop {
    bool     valid = false;
    uint32_t pc = 0, inst = 0, imm = 0;
    uint8_t rs1 = 0, rs2 = 0, rd = 0;
    bool reg_we = false;
    uint8_t alu_op = 0, a_sel = 0, b_sel = 0, wb_sel = 0;
    bool is_branch = false, is_jal = false, is_jalr = false;
    bool is_load = false, is_store = false, illegal = false;
    uint8_t mem_size = 2, mem_unsigned = 0;
};

struct Inputs {
    Uop      u[W];
    bool     commit_valid[W] = {};
    uint8_t  commit_rd[W] = {};
    uint32_t commit_dest[W] = {};
    bool     commit_reg_we[W] = {};
    bool     commit_free_valid[W] = {};
    uint32_t commit_free[W] = {};
    bool     wake_valid[W] = {};
    uint32_t wake_tag[W] = {};
    bool     recover = false;
    uint64_t recover_free = 0;
    uint64_t recover_busy = 0;
    uint8_t  recover_lsq = 0;
    uint32_t recover_rat[32] = {};
    bool     out_ready = true;
};

struct ExpLane {
    bool     valid = false;
    uint32_t dest = 0, src1 = 0, src2 = 0, old_tag = 0;
    bool     src1_ready = false, src2_ready = false;
    uint8_t  lsq = 0;
};

struct Exp {
    bool    in_ready = false;
    ExpLane lane[W];
};

struct Ref {
    uint32_t rat[32];
    uint32_t crat[32];
    bool     free[PRF];
    bool     busy[PRF];
    uint8_t  lsq = 0;

    Ref() {
        for (int i = 0; i < 32; ++i) rat[i] = crat[i] = 0;
        free[0] = false;
        busy[0] = false;
        for (int i = 1; i < PRF; ++i) { free[i] = true; busy[i] = false; }
    }

    int count_free() const {
        int n = 0;
        for (int i = 1; i < PRF; ++i) if (free[i]) ++n;
        return n;
    }

    void apply(const Inputs& in, bool in_ready, const Exp& exp) {
        if (in.recover) {
            for (int i = 0; i < 32; ++i) rat[i] = in.recover_rat[i];
            for (int i = 0; i < PRF; ++i) {
                free[i] = ((in.recover_free >> i) & 1u) != 0;
                busy[i] = ((in.recover_busy >> i) & 1u) != 0;
            }
            free[0] = false;
            busy[0] = false;
            lsq = in.recover_lsq;
            return;
        }

        for (int l = 0; l < W; ++l)
            if (in.wake_valid[l]) busy[in.wake_tag[l]] = false;

        for (int l = 0; l < W; ++l) {
            if (!in.commit_valid[l]) continue;
            if (in.commit_free_valid[l]) {
                free[in.commit_free[l]] = true;
                busy[in.commit_free[l]] = false;
            }
            if (in.commit_reg_we[l]) crat[in.commit_rd[l]] = in.commit_dest[l];
        }

        if (!in_ready) return;

        uint8_t l = lsq;
        for (int lane = 0; lane < W; ++lane) {
            if (!in.u[lane].valid) continue;
            // 分配结果必须用本拍输出时已经算好的 dest_tag；不能在 commit
            // 释放之后重新找最低空闲位（那会选到刚释放的 tag，与 RTL 不符）。
            uint32_t tag = exp.lane[lane].dest;
            if (tag == 0 || tag >= (uint32_t)PRF) continue;
            free[tag] = false;
            busy[tag] = true;
            if (in.u[lane].reg_we) rat[in.u[lane].rd] = tag;
            if (in.u[lane].is_load || in.u[lane].is_store)
                l = (l == LSQ - 1) ? 0 : (uint8_t)(l + 1);
        }
        lsq = l;
    }
};

struct Harness {
    Vrename* dut = nullptr;
    Ref      ref;
    long     checked = 0;
    long     fails = 0;
    long     reported = 0;
    long     iter = -1;
    Exp      last;

    void report(const char* tag, const char* field, int lane, uint32_t got, uint32_t want) {
        ++fails;
        if (reported >= 20) return;
        ++reported;
        printf("FAIL [%s] iter=%ld lane%d %s got=%u want=%u\n", tag, iter, lane, field, got, want);
    }

    void apply(const Inputs& in) {
        dut->reset = 0;
        uint32_t vmask = 0;
        for (int l = 0; l < W; ++l) if (in.u[l].valid) vmask |= (1u << l);
        dut->in_valid = vmask;
        for (int l = 0; l < W; ++l) {
            const Uop& u = in.u[l];
            int base = l * DECODE_W;
            put_bits(dut->in_uop, base + PC_OFF, u.pc, 32);
            put_bits(dut->in_uop, base + INST_OFF, u.inst, 32);
            put_bits(dut->in_uop, base + IMM_OFF, u.imm, 32);
            put_bits(dut->in_uop, base + RD_OFF, u.rd, 5);
            put_bits(dut->in_uop, base + REG_WE_OFF, u.reg_we, 1);
            put_bits(dut->in_uop, base + ALU_OP_OFF, u.alu_op, 5);
            put_bits(dut->in_uop, base + A_SEL_OFF, u.a_sel, 2);
            put_bits(dut->in_uop, base + B_SEL_OFF, u.b_sel, 1);
            put_bits(dut->in_uop, base + WB_SEL_OFF, u.wb_sel, 2);
            put_bits(dut->in_uop, base + IS_BRANCH_OFF, u.is_branch, 1);
            put_bits(dut->in_uop, base + IS_JAL_OFF, u.is_jal, 1);
            put_bits(dut->in_uop, base + IS_JALR_OFF, u.is_jalr, 1);
            put_bits(dut->in_uop, base + IS_LOAD_OFF, u.is_load, 1);
            put_bits(dut->in_uop, base + IS_STORE_OFF, u.is_store, 1);
            put_bits(dut->in_uop, base + ILLEGAL_OFF, u.illegal, 1);
            put_bits(dut->in_uop, base + MEM_SIZE_OFF, u.mem_size, 2);
            put_bits(dut->in_uop, base + MEM_UNSIGNED_OFF, u.mem_unsigned, 1);
            put_bits(dut->in_uop, base + D_RS1_OFF, u.rs1, 5);
            put_bits(dut->in_uop, base + D_RS2_OFF, u.rs2, 5);
        }

        uint32_t cv = 0, rd = 0, cd = 0, crw = 0, cfv = 0, cf = 0;
        uint32_t wv = 0, wt = 0;
        for (int l = 0; l < W; ++l) {
            if (in.commit_valid[l]) cv |= (1u << l);
            rd  |= (uint32_t)in.commit_rd[l] << (l * 5);
            cd  |= in.commit_dest[l] << (l * PW);
            if (in.commit_reg_we[l]) crw |= (1u << l);
            if (in.commit_free_valid[l]) {
                cfv |= (1u << l);
                cf  |= in.commit_free[l] << (l * PW);
            }
            if (in.wake_valid[l]) {
                wv |= (1u << l);
                wt |= in.wake_tag[l] << (l * PW);
            }
        }
        dut->commit_valid = cv;
        dut->commit_rd = rd;
        dut->commit_dest_tag = cd;
        dut->commit_reg_we = crw;
        dut->commit_free_valid = cfv;
        dut->commit_free_tag = cf;
        dut->wake_valid = wv;
        dut->wake_tag = wt;
        dut->recover_valid = in.recover;
        dut->recover_free_mask = in.recover_free;
        dut->recover_busy_mask = in.recover_busy;
        dut->recover_lsq_ptr = in.recover_lsq;
        for (int i = 0; i < 32; ++i)
            put_bits(dut->recover_rat, i * PW, in.recover_rat[i], PW);
        dut->out_ready = in.out_ready;
        dut->clk = 0;
        dut->eval();
    }

    Exp compute(const Inputs& in) const {
        Exp e;
        int nv = 0;
        for (int l = 0; l < W; ++l) {
            if (in.u[l].valid) ++nv;
            e.lane[l].valid = in.u[l].valid;
        }
        e.in_ready = !in.recover && in.out_ready && (ref.count_free() >= nv);
        if (!e.in_ready) return e;

        bool f[PRF];
        bool be[PRF];
        uint32_t r[32];
        bool wake[PRF] = {};
        for (int i = 0; i < PRF; ++i) { f[i] = ref.free[i]; be[i] = ref.busy[i]; }
        for (int i = 0; i < 32; ++i) r[i] = ref.rat[i];
        for (int l = 0; l < W; ++l)
            if (in.wake_valid[l]) wake[in.wake_tag[l]] = true;
        for (int i = 0; i < PRF; ++i) be[i] = be[i] && !wake[i];

        uint8_t lsq = ref.lsq;
        uint32_t dest[W] = {};
        for (int l = 0; l < W; ++l) {
            if (!in.u[l].valid) continue;
            int tag = -1;
            for (int i = 1; i < PRF; ++i) if (f[i]) { tag = i; break; }
            if (tag < 0) { e.in_ready = false; return e; }
            f[tag] = false;
            dest[l] = (uint32_t)tag;
        }

        for (int l = 0; l < W; ++l) {
            ExpLane& x = e.lane[l];
            x.valid = in.u[l].valid;
            if (!x.valid) continue;
            const Uop& u = in.u[l];
            x.dest = dest[l];
            x.src1 = (u.rs1 == 0) ? 0 : r[u.rs1];
            x.src2 = (u.rs2 == 0) ? 0 : r[u.rs2];
            x.src1_ready = (u.rs1 == 0) || !be[x.src1];
            x.src2_ready = (u.rs2 == 0) || !be[x.src2];
            x.old_tag = u.reg_we ? r[u.rd] : 0;

            for (int j = 0; j < l; ++j) {
                if (!in.u[j].valid || !in.u[j].reg_we) continue;
                if (in.u[j].rd == u.rs1) { x.src1 = dest[j]; x.src1_ready = false; }
                if (in.u[j].rd == u.rs2) { x.src2 = dest[j]; x.src2_ready = false; }
                if (in.u[j].rd == u.rd)  { x.old_tag = dest[j]; }
            }

            if (u.is_load || u.is_store) {
                x.lsq = lsq;
                lsq = (lsq == LSQ - 1) ? 0 : (uint8_t)(lsq + 1);
            }
        }
        return e;
    }

    bool check_exp(const Exp& e, const char* tag) {
        ++checked;
        bool ok = true;
        uint32_t got_ready = (uint32_t)dut->in_ready;
        if (got_ready != (uint32_t)e.in_ready) {
            report(tag, "in_ready", -1, got_ready, (uint32_t)e.in_ready);
            return false;
        }
        uint32_t ov = (uint32_t)dut->out_valid;
        for (int l = 0; l < W; ++l) {
            bool want_valid = e.lane[l].valid;
            if (((ov >> l) & 1u) != (uint32_t)want_valid) {
                report(tag, "out_valid", l, (ov >> l) & 1u, (uint32_t)want_valid);
                ok = false;
                continue;
            }
            if (!want_valid) continue;
            if (!e.in_ready) continue;
            int base = l * RENAME_W;
            struct { const char* n; uint32_t got; uint32_t want; } fields[] = {
                {"dest", get_bits(dut->out_uop, base + DEST_OFF, PW), e.lane[l].dest},
                {"src1", get_bits(dut->out_uop, base + SRC1_OFF, PW), e.lane[l].src1},
                {"src1_ready", get_bits(dut->out_uop, base + SRC1_RDY_OFF, 1), (uint32_t)e.lane[l].src1_ready},
                {"src2", get_bits(dut->out_uop, base + SRC2_OFF, PW), e.lane[l].src2},
                {"src2_ready", get_bits(dut->out_uop, base + SRC2_RDY_OFF, 1), (uint32_t)e.lane[l].src2_ready},
                {"lsq", get_bits(dut->out_uop, base + LSQ_OFF, LW), (uint32_t)e.lane[l].lsq},
                {"old_tag", ((uint32_t)dut->out_old_tag >> (l * PW)) & ((1u << PW) - 1), e.lane[l].old_tag},
            };
            for (auto& fld : fields) {
                if (fld.got != fld.want) {
                    report(tag, fld.n, l, fld.got, fld.want);
                    ok = false;
                }
            }
        }
        return ok;
    }

    Exp step(const Inputs& in, const char* tag) {
        apply(in);
        Exp e = compute(in);
        check_exp(e, tag);
        ref.apply(in, e.in_ready, e);
        dut->clk = 1;
        dut->eval();
        last = e;
        return e;
    }

    void reset() {
        dut->reset = 1;
        dut->in_valid = 0;
        dut->out_ready = 1;
        dut->commit_valid = 0;
        dut->commit_free_valid = 0;
        dut->wake_valid = 0;
        dut->recover_valid = 0;
        dut->clk = 0;
        dut->eval();
        for (int i = 0; i < 3; ++i) {
            dut->clk = 1; dut->eval();
            dut->clk = 0; dut->eval();
        }
        ref = Ref();
        dut->reset = 0;
        dut->eval();
    }
};

Inputs idle_inputs() {
    Inputs in;
    in.out_ready = true;
    return in;
}

Uop make_uop(uint32_t pc, uint8_t rd, uint8_t rs1, uint8_t rs2,
             bool reg_we, bool is_store = false, bool is_load = false) {
    Uop u;
    u.valid = true;
    u.pc = pc;
    u.rd = rd;
    u.rs1 = rs1;
    u.rs2 = rs2;
    u.reg_we = reg_we;
    u.is_store = is_store;
    u.is_load = is_load;
    return u;
}

bool run_directed(Harness& h) {
    bool ok = true;
    h.reset();

    // 1. 普通写 x1，分配最低空闲 tag 1
    Inputs in = idle_inputs();
    in.u[0] = make_uop(0x100, 1, 0, 0, true);
    h.step(in, "rename-x1");
    if (!h.last.in_ready || h.last.lane[0].dest != 1 || h.last.lane[0].old_tag != 0) {
        h.report("directed", "first dest", 0, h.last.lane[0].dest, 1);
        ok = false;
    }

    // 2. 读 x1 应指向 tag1 且 busy
    in = idle_inputs();
    in.u[0] = make_uop(0x104, 2, 1, 1, true);
    h.step(in, "read-x1");
    if (h.last.lane[0].src1 != 1 || h.last.lane[0].src1_ready ||
        h.last.lane[0].src2 != 1 || h.last.lane[0].src2_ready) {
        h.report("directed", "src busy", 0, h.last.lane[0].src1_ready, 0);
        ok = false;
    }

    // 3. wake tag1 后 x1 ready
    in = idle_inputs();
    in.wake_valid[0] = true;
    in.wake_tag[0] = 1;
    in.u[0] = make_uop(0x108, 3, 1, 0, true);
    h.step(in, "wake-x1");
    if (!h.last.lane[0].src1_ready || h.last.lane[0].src1 != 1) {
        h.report("directed", "wake ready", 0, h.last.lane[0].src1_ready, 1);
        ok = false;
    }

    // 4. commit x1（crat[1]=1），不释放 tag0
    in = idle_inputs();
    in.commit_valid[0] = true;
    in.commit_rd[0] = 1;
    in.commit_dest[0] = 1;
    in.commit_reg_we[0] = true;
    h.step(in, "commit-x1");

    // 5. 再写 x1 -> dest 4（1/2/3 已分配，4 最低）
    in = idle_inputs();
    in.u[0] = make_uop(0x10c, 1, 0, 0, true);
    h.step(in, "rename-x1-again");
    if (h.last.lane[0].dest != 4 || h.last.lane[0].old_tag != 1) {
        h.report("directed", "old tag after commit", 0, h.last.lane[0].old_tag, 1);
        ok = false;
    }

    // 6. 提交写 x2（在步骤 2 分配 tag2），释放 old_tag1
    in = idle_inputs();
    in.commit_valid[0] = true;
    in.commit_rd[0] = 2;
    in.commit_dest[0] = 2;
    in.commit_reg_we[0] = true;
    in.commit_free_valid[0] = true;
    in.commit_free[0] = 1;
    h.step(in, "commit-x2-free1");

    // 7. 非架构写：store x0,0(x0)，dest 5，lsq=0；提交时释放 dest
    in = idle_inputs();
    in.u[0] = make_uop(0x110, 0, 0, 0, false, true, false);
    h.step(in, "store-x0");
    if (h.last.lane[0].dest != 1 || h.last.lane[0].lsq != 0) {
        h.report("directed", "store dest/lsq", 0, h.last.lane[0].dest, 1);
        ok = false;
    }
    in = idle_inputs();
    in.commit_valid[0] = true;
    in.commit_free_valid[0] = true;
    in.commit_free[0] = 1;
    h.step(in, "commit-store");

    // 8. 空闲表压力：连续 store 直到 in_ready=0
    int accepted = 0;
    for (int i = 0; i < PRF + 5; ++i) {
        in = idle_inputs();
        in.u[0] = make_uop(0x200 + 4 * i, 0, 0, 0, false, true, false);
        h.step(in, "fill-free");
        if (!h.last.in_ready) break;
        ++accepted;
    }
    if (h.last.in_ready) {
        h.report("directed", "free list never full", 0, 1, 0);
        ok = false;
    }

    // 9. 恢复：先让 x1 的提交映射为 tag4（crat），然后恢复
    in = idle_inputs();
    in.commit_valid[0] = true;
    in.commit_rd[0] = 1;
    in.commit_dest[0] = 4;
    in.commit_reg_we[0] = true;
    in.commit_free_valid[0] = true;
    in.commit_free[0] = 1;
    h.step(in, "commit-x1-tag4");

    uint64_t free_mask = 0;
    for (int i = 1; i < PRF; ++i) free_mask |= (1ull << i);
    free_mask &= ~(1ull << 4);   // tag4 被 crat 使用
    in = idle_inputs();
    in.recover = true;
    in.recover_free = free_mask;
    in.recover_busy = 0;
    in.recover_lsq = 0;
    for (int i = 0; i < 32; ++i) in.recover_rat[i] = h.ref.rat[i];
    h.step(in, "recover");
    if (h.last.in_ready) {
        h.report("directed", "recover should stall input", 0, 1, 0);
        ok = false;
    }

    // 恢复后 x1 -> tag4 且 ready，下一个 dest 应复用最低空闲 tag1
    in = idle_inputs();
    in.u[0] = make_uop(0x300, 6, 1, 0, true);
    h.step(in, "after-recover");
    if (h.last.lane[0].src1 != 4 || !h.last.lane[0].src1_ready ||
        h.last.lane[0].dest != 1) {
        h.report("directed", "recover mapping", 0, h.last.lane[0].src1, 4);
        h.report("directed", "recover dest", 0, h.last.lane[0].dest, 1);
        ok = false;
    }

    return ok;
}

void run_w_dependency(Harness& h) {
    if (W < 2) return;
    h.reset();
    Inputs in = idle_inputs();
    in.u[0] = make_uop(0x400, 5, 0, 0, true);           // x5 <- dest1
    in.u[1] = make_uop(0x404, 6, 5, 5, true);           // x6 <- f(x5,x5), dest2
    h.step(in, "w2-dependency");
    if (h.last.lane[1].src1 != 1 || h.last.lane[1].src1_ready ||
        h.last.lane[1].src2 != 1 || h.last.lane[1].src2_ready) {
        h.report("w2", "intra-group src", 1, h.last.lane[1].src1, 1);
    }

    // 两条都写 x5：lane1 的 old_tag 应是 lane0 的 dest
    Inputs in2 = idle_inputs();
    in2.u[0] = make_uop(0x408, 5, 0, 0, true);
    in2.u[1] = make_uop(0x40c, 5, 0, 0, true);
    h.step(in2, "w2-same-rd");
    if (h.last.lane[1].old_tag != h.last.lane[0].dest) {
        h.report("w2", "same-rd old", 1, h.last.lane[1].old_tag, h.last.lane[0].dest);
    }
}

void run_random(Harness& h, long iters) {
    h.reset();
    std::vector<uint32_t> live;

    for (long n = 0; n < iters; ++n) {
        Inputs in = idle_inputs();
        uint32_t r = next_rand();
        int nv = (int)(r % (W + 1));
        for (int l = 0; l < W; ++l) {
            if (l >= nv) break;
            Uop& u = in.u[l];
            u.valid = true;
            u.pc = next_rand();
            u.rd = (uint8_t)(next_rand() % 32);
            u.rs1 = (uint8_t)(next_rand() % 32);
            u.rs2 = (uint8_t)(next_rand() % 32);
            u.reg_we = (next_rand() & 1u) != 0;
            u.is_load = (next_rand() & 7u) == 1;
            u.is_store = (next_rand() & 7u) == 2;
            u.is_branch = (next_rand() & 15u) == 3;
        }
        in.out_ready = ((r >> 8) & 3u) != 0;

        // commit：从 live 中挑 tag 释放
        for (int l = 0; l < W; ++l) {
            if (((r >> (10 + l)) & 3u) == 0) {
                in.commit_valid[l] = true;
                in.commit_rd[l] = (uint8_t)(next_rand() % 32);
                in.commit_reg_we[l] = (next_rand() & 1u) != 0;
                in.commit_dest[l] = (next_rand() % PRF);
                if (!live.empty() && (next_rand() & 1u)) {
                    size_t idx = next_rand() % live.size();
                    in.commit_free_valid[l] = true;
                    in.commit_free[l] = live[idx];
                    live.erase(live.begin() + (long)idx);
                }
            }
        }

        // wake
        for (int l = 0; l < W; ++l) {
            if (((r >> (20 + l)) & 3u) == 0) {
                in.wake_valid[l] = true;
                in.wake_tag[l] = (next_rand() % PRF);
            }
        }

        h.iter = n;
        h.step(in, "random");

        if (h.last.in_ready) {
            for (int l = 0; l < W; ++l)
                if (h.last.lane[l].valid) live.push_back(h.last.lane[l].dest);
        }
        // 保持 live 与实际 free 表大致一致，避免随机 commit 复用已释放 tag。
        if (live.size() > (size_t)(PRF - 1)) live.resize(PRF - 1);
    }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    long random_iters = 200000;
    uint32_t seed = 0x20261018u;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--quick")) {
            random_iters = 20000;
        } else if (!strcmp(argv[i], "--seed") && i + 1 < argc) {
            seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
        } else if (!strcmp(argv[i], "--cycles") && i + 1 < argc) {
            random_iters = strtol(argv[++i], nullptr, 0);
            if (random_iters < 0) random_iters = 0;
        } else {
            printf("usage: %s [--quick] [--seed N] [--cycles N]\n", argv[0]);
            return 2;
        }
    }
    rng_state = seed ? seed : 0x20261018u;

    Vrename dut;
    Harness h;
    h.dut = &dut;

    run_directed(h);
    run_w_dependency(h);
    run_random(h, random_iters);

    printf("rename_tb: W=%d checked=%ld fails=%ld\n", W, h.checked, h.fails);
    if (h.fails != 0) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
