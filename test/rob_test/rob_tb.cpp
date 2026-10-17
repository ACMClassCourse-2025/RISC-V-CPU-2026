// -----------------------------------------------------------------------------
// rob_tb.cpp — verilog/rob.sv + commit.sv 的 Verilator 单元测试
//
// 参考模型按程序序维护一个 deque：分配、随机完成、分支解析、按序提交、
// 误预测冲刷与恢复掩码。逐拍比较：
//   - 组合输出：in_ready、commit_valid/字段、commit_halt；
//   - 时钟沿后的脉冲：redirect/squash、recover masks/lsq_ptr。
//
// W 由 run.sh 的 -DCPU_ISSUE_WIDTH / -DTB_W 控制，默认 W=1。
// -----------------------------------------------------------------------------

#include "Vrob.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <type_traits>
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
constexpr int DEPTH   = 32;
constexpr int RW      = 5;
constexpr int RENAME_W = 124 + 3 * PW + LW;

constexpr int PC_OFF = 1, INST_OFF = 33, RD_OFF = 97, REG_WE_OFF = 102;
constexpr int IS_BRANCH_OFF = 113, IS_JAL_OFF = 114, IS_JALR_OFF = 115;
constexpr int IS_LOAD_OFF = 116, IS_STORE_OFF = 117, ILLEGAL_OFF = 118;
constexpr int LSQ_OFF = 124 + 3 * PW;
constexpr int DEST_OFF = 122;

uint32_t rng_state = 0x20261018u;
uint32_t next_rand() {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

template <typename Sig>
void put_bits(Sig& sig, int off, uint32_t value, int bits) {
    if constexpr (std::is_integral<Sig>::value) {
        uint64_t mask = (bits >= 64) ? ~0ull : ((1ull << bits) - 1ull);
        uint64_t cur  = (uint64_t)sig;
        cur = (cur & ~(mask << off)) | (((uint64_t)value & mask) << off);
        sig = (Sig)cur;
    } else {
        for (int i = 0; i < bits; ++i) {
            int b = off + i, w = b / 32, s = b % 32;
            if ((value >> i) & 1u) sig[w] |= (1u << s);
            else                   sig[w] &= ~(1u << s);
        }
    }
}

template <typename Sig>
uint32_t get_bits(const Sig& sig, int off, int bits) {
    uint32_t v = 0;
    for (int i = 0; i < bits; ++i) {
        int b = off + i, w = b / 32, s = b % 32;
        if ((sig[w] >> s) & 1u) v |= (1u << i);
    }
    return v;
}

struct Uop {
    uint32_t pc = 0, inst = 0;
    uint8_t  rd = 0;
    bool     reg_we = false;
    uint32_t dest = 0, old_tag = 0;
    bool     is_store = false, is_load = false;
    uint8_t  lsq_id = 0;
    bool     is_branch = false, is_jal = false, is_jalr = false;
    bool     illegal = false;
    bool     pred_taken = false;
    uint32_t pred_target = 0;
};

struct Inputs {
    Uop      u[W];
    uint32_t nv = 0;
    bool     cdb_valid = false;
    uint32_t cdb_tag = 0;
    bool     cdb_exc = false;
    bool     comp_valid[W] = {};
    uint32_t comp_tag[W] = {};
    bool     comp_exc[W] = {};
    bool     br_valid = false;
    uint32_t br_pc = 0, br_target = 0, br_tag = 0;
    bool     br_taken = false, br_jalr = false;
};

struct Entry {
    uint32_t idx = 0, pc = 0, inst = 0, dest = 0, old_tag = 0;
    uint8_t  rd = 0, lsq_id = 0;
    bool     reg_we = false, is_store = false, is_load = false;
    bool     control = false, illegal = false;
    bool     pred_taken = false;
    uint32_t pred_target = 0;
    bool     done = false, exception = false, resolved = false;
};

struct ExpComb {
    bool in_ready = false;
    bool commit_valid[W] = {};
    uint32_t commit_tag[W] = {}, commit_lsq[W] = {};
    bool commit_store[W] = {}, commit_load[W] = {}, commit_reg_we[W] = {};
    uint32_t commit_rd[W] = {}, commit_dest[W] = {}, commit_free[W] = {};
    bool commit_free_valid[W] = {};
    bool halt = false, flush = false;
    int  br_pos = -1;
    bool br_mispredict = false;
    int  n_commit = 0;
    uint32_t squash_idx = 0, redirect_pc = 0;
};

struct ExpReg {
    bool redirect_valid = false, squash_valid = false, recover_valid = false;
    uint32_t redirect_pc = 0, squash_idx = 0;
    uint64_t free_mask = 0, busy_mask = 0;
    uint8_t lsq_ptr = 0;
};

struct RefRob {
    std::deque<Entry> q;
    uint32_t head = 0;
    uint32_t crat[32] = {};
    bool cur_recover = false, cur_redirect = false;

    int count_free() const {
        int n = 0;
        bool used[PRF] = {};
        used[0] = true;
        for (int r = 0; r < 32; ++r) used[crat[r]] = true;
        for (const Entry& e : q) used[e.dest] = true;
        for (int i = 0; i < PRF; ++i) if (!used[i]) ++n;
        return n;
    }

    ExpComb eval_comb(const Inputs& in) const {
        ExpComb e;
        int nv = 0;
        for (int l = 0; l < W; ++l) if (in.u[l].pc || in.u[l].dest) ++nv;
        // nv 由输入 valid 单独给出；这里用 dest!=0 表示有效 lane
        nv = 0;
        for (int l = 0; l < W; ++l) if (in.u[l].dest != 0) ++nv;

        e.br_pos = -1;
        if (in.br_valid) {
            for (size_t i = 0; i < q.size(); ++i) {
                if (q[i].control && q[i].dest == in.br_tag) {
                    e.br_pos = (int)i;
                    break;
                }
            }
            if (e.br_pos >= 0) {
                const Entry& b = q[(size_t)e.br_pos];
                e.br_mispredict = (in.br_taken != b.pred_taken) ||
                                  (in.br_taken && in.br_target != b.pred_target);
            }
        }
        e.flush = e.br_pos >= 0 && e.br_mispredict;

        e.in_ready = !e.flush && !cur_recover && !cur_redirect &&
                     (q.size() + (size_t)W <= (size_t)DEPTH);

        e.n_commit = 0;
        if (!e.flush) {
            for (int i = 0; i < W && i < (int)q.size(); ++i) {
                const Entry& x = q[(size_t)i];
                if (x.done && (!x.control || x.resolved)) {
                    e.commit_valid[i] = true;
                    e.commit_tag[i] = x.dest;
                    e.commit_store[i] = x.is_store;
                    e.commit_load[i] = x.is_load;
                    e.commit_lsq[i] = x.lsq_id;
                    e.commit_reg_we[i] = x.reg_we;
                    e.commit_rd[i] = x.rd;
                    e.commit_dest[i] = x.dest;
                    if (x.reg_we) {
                        e.commit_free[i] = x.old_tag;
                        e.commit_free_valid[i] = x.old_tag != 0;
                    } else {
                        e.commit_free[i] = x.dest;
                        e.commit_free_valid[i] = x.dest != 0;
                    }
                    ++e.n_commit;
                    if (x.exception || x.illegal) {
                        e.halt = true;
                        break;
                    }
                } else {
                    break;
                }
            }
        }
        return e;
    }

    ExpReg apply(const Inputs& in, const ExpComb& e) {
        ExpReg r;
        uint32_t old_head = head;
        size_t old_size = q.size();

        // 分支解析 / 冲刷（完成广播在时钟沿后处理，恢复掩码用本拍前的 done）
        if (e.br_pos >= 0) {
            Entry& b = q[(size_t)e.br_pos];
            b.resolved = true;
            if (e.br_mispredict) {
                r.redirect_valid = true;
                r.redirect_pc = in.br_taken ? in.br_target : (b.pc + 4);
                r.squash_valid = true;
                r.squash_idx = b.idx;
                r.recover_valid = true;

                r.free_mask = ~0ull;
                r.free_mask &= ~1ull;
                for (int rg = 0; rg < 32; ++rg)
                    if (crat[rg] != 0) r.free_mask &= ~(1ull << crat[rg]);
                r.busy_mask = 0;
                r.lsq_ptr = 0;
                for (int i = 0; i <= e.br_pos; ++i) {
                    Entry& x = q[(size_t)i];
                    r.free_mask &= ~(1ull << x.dest);
                    if (!x.done) r.busy_mask |= (1ull << x.dest);
                    if (x.is_store || x.is_load)
                        r.lsq_ptr = (x.lsq_id == LSQ - 1) ? 0 : (uint8_t)(x.lsq_id + 1);
                }
                q.erase(q.begin() + e.br_pos + 1, q.end());
            }
        }

        // 提交
        if (e.n_commit > 0) {
            for (int i = 0; i < e.n_commit; ++i) {
                const Entry& x = q[(size_t)i];
                if (x.reg_we) crat[x.rd] = x.dest;
            }
            q.erase(q.begin(), q.begin() + e.n_commit);
            head = (head + (uint32_t)e.n_commit) & (DEPTH - 1);
        }

        // 分配（索引用提交前的 head/size）
        if (e.in_ready) {
            uint32_t base = (old_head + (uint32_t)old_size) & (DEPTH - 1);
            for (int l = 0; l < W; ++l) {
                if (in.u[l].dest == 0) continue;
                Entry x;
                x.idx = (base + (uint32_t)l) & (DEPTH - 1);
                x.pc = in.u[l].pc;
                x.inst = in.u[l].inst;
                x.rd = in.u[l].rd;
                x.reg_we = in.u[l].reg_we;
                x.dest = in.u[l].dest;
                x.old_tag = in.u[l].old_tag;
                x.is_store = in.u[l].is_store;
                x.is_load = in.u[l].is_load;
                x.lsq_id = in.u[l].lsq_id;
                x.control = in.u[l].is_branch || in.u[l].is_jal || in.u[l].is_jalr;
                x.illegal = in.u[l].illegal;
                x.pred_taken = in.u[l].pred_taken;
                x.pred_target = in.u[l].pred_target;
                q.push_back(x);
            }
        }

        // 完成广播（在本拍恢复掩码/提交判断之后更新，符合寄存器时序）
        if (in.cdb_valid) {
            for (Entry& x : q)
                if (x.dest == in.cdb_tag) {
                    x.done = true;
                    if (in.cdb_exc) x.exception = true;
                }
        }
        for (int l = 0; l < W; ++l) {
            if (!in.comp_valid[l]) continue;
            for (Entry& x : q)
                if (x.dest == in.comp_tag[l]) {
                    x.done = true;
                    if (in.comp_exc[l]) x.exception = true;
                }
        }

        cur_recover = r.recover_valid;
        cur_redirect = r.redirect_valid;
        return r;
    }
};

struct Harness {
    Vrob* dut = nullptr;
    RefRob ref;
    long checked = 0, fails = 0, reported = 0;
    long iter = -1;
    ExpComb last_comb;
    ExpReg  last_reg;

    void report(const char* tag, const char* field, int lane, uint32_t got, uint32_t want) {
        ++fails;
        if (reported >= 20) return;
        ++reported;
        printf("FAIL [%s] iter=%ld lane%d %s got=%u want=%u\n",
               tag, iter, lane, field, got, want);
    }

    void apply(const Inputs& in) {
        uint32_t vmask = 0;
        dut->in_valid = 0;
        for (int l = 0; l < W; ++l) {
            const Uop& u = in.u[l];
            int base = l * RENAME_W;
            if (u.dest != 0) vmask |= (1u << l);
            put_bits(dut->in_uop, base + PC_OFF, u.pc, 32);
            put_bits(dut->in_uop, base + INST_OFF, u.inst, 32);
            put_bits(dut->in_uop, base + RD_OFF, u.rd, 5);
            put_bits(dut->in_uop, base + REG_WE_OFF, u.reg_we, 1);
            put_bits(dut->in_uop, base + IS_BRANCH_OFF, u.is_branch, 1);
            put_bits(dut->in_uop, base + IS_JAL_OFF, u.is_jal, 1);
            put_bits(dut->in_uop, base + IS_JALR_OFF, u.is_jalr, 1);
            put_bits(dut->in_uop, base + IS_LOAD_OFF, u.is_load, 1);
            put_bits(dut->in_uop, base + IS_STORE_OFF, u.is_store, 1);
            put_bits(dut->in_uop, base + ILLEGAL_OFF, u.illegal, 1);
            put_bits(dut->in_uop, base + LSQ_OFF, u.lsq_id, LW);
            put_bits(dut->in_uop, base + DEST_OFF, u.dest, PW);
            put_bits(dut->in_old_tag, l * PW, u.old_tag, PW);
            put_bits(dut->in_pred_taken, l, u.pred_taken, 1);
            put_bits(dut->in_pred_target, l * 32, u.pred_target, 32);
        }
        dut->in_valid = vmask;
        dut->cdb_valid = in.cdb_valid;
        dut->cdb_tag = in.cdb_tag;
        dut->cdb_exception = in.cdb_exc;
        uint32_t cv = 0, ct = 0, ce = 0;
        for (int l = 0; l < W; ++l) {
            if (in.comp_valid[l]) cv |= (1u << l);
            ct |= in.comp_tag[l] << (l * PW);
            if (in.comp_exc[l]) ce |= (1u << l);
        }
        dut->complete_valid = cv;
        dut->complete_tag = ct;
        dut->complete_exception = ce;
        dut->br_update_valid = in.br_valid;
        dut->br_update_pc = in.br_pc;
        dut->br_update_taken = in.br_taken;
        dut->br_update_target = in.br_target;
        dut->br_update_is_jalr = in.br_jalr;
        dut->br_update_tag = in.br_tag;
        dut->reset = 0;
        dut->clk = 0;
        dut->eval();
    }

    void check_comb(const ExpComb& e, const char* tag) {
        ++checked;
        if ((bool)dut->in_ready != e.in_ready) {
            report(tag, "in_ready", -1, dut->in_ready, e.in_ready);
        }
        if ((bool)dut->commit_halt != e.halt) {
            report(tag, "commit_halt", -1, dut->commit_halt, e.halt);
        }
        uint32_t cv = (uint32_t)dut->commit_valid;
        for (int l = 0; l < W; ++l) {
            bool want = e.commit_valid[l];
            if (((cv >> l) & 1u) != (uint32_t)want) {
                report(tag, "commit_valid", l, (cv >> l) & 1u, want);
                continue;
            }
            if (!want) continue;
            struct F { const char* n; uint32_t got, want; } f[] = {
                {"tag", (uint32_t)((dut->commit_tag >> (l*PW)) & ((1u<<PW)-1)), e.commit_tag[l]},
                {"store", (uint32_t)((dut->commit_is_store >> l) & 1u), e.commit_store[l]},
                {"load", (uint32_t)((dut->commit_is_load >> l) & 1u), e.commit_load[l]},
                {"lsq", (uint32_t)((dut->commit_lsq_id >> (l*LW)) & ((1u<<LW)-1)), e.commit_lsq[l]},
                {"reg_we", (uint32_t)((dut->commit_reg_we >> l) & 1u), e.commit_reg_we[l]},
                {"rd", (uint32_t)((dut->commit_rd >> (l*5)) & 31u), e.commit_rd[l]},
                {"dest", (uint32_t)((dut->commit_dest_tag >> (l*PW)) & ((1u<<PW)-1)), e.commit_dest[l]},
                {"free_valid", (uint32_t)((dut->commit_free_valid >> l) & 1u), e.commit_free_valid[l]},
                {"free_tag", (uint32_t)((dut->commit_free_tag >> (l*PW)) & ((1u<<PW)-1)), e.commit_free[l]},
            };
            for (auto& x : f)
                if (x.got != x.want) report(tag, x.n, l, x.got, x.want);
        }
    }

    void check_reg(const ExpReg& r, const char* tag) {
        ++checked;
        if ((bool)dut->redirect_valid != r.redirect_valid)
            report(tag, "redirect_valid", -1, dut->redirect_valid, r.redirect_valid);
        if (r.redirect_valid && (uint32_t)dut->redirect_pc != r.redirect_pc)
            report(tag, "redirect_pc", -1, dut->redirect_pc, r.redirect_pc);
        if ((bool)dut->squash_valid != r.squash_valid)
            report(tag, "squash_valid", -1, dut->squash_valid, r.squash_valid);
        if (r.squash_valid && (uint32_t)dut->squash_rob_idx != r.squash_idx)
            report(tag, "squash_idx", -1, dut->squash_rob_idx, r.squash_idx);
        if ((bool)dut->recover_valid != r.recover_valid)
            report(tag, "recover_valid", -1, dut->recover_valid, r.recover_valid);
        if (r.recover_valid) {
            uint64_t fm = (uint64_t)dut->recover_free_mask;
            uint64_t bm = (uint64_t)dut->recover_busy_mask;
            if (fm != r.free_mask) {
                report(tag, "free_mask_lo", -1, (uint32_t)fm, (uint32_t)r.free_mask);
                report(tag, "free_mask_hi", -1, (uint32_t)(fm >> 32), (uint32_t)(r.free_mask >> 32));
            }
            if (bm != r.busy_mask)
                report(tag, "busy_mask_lo", -1, (uint32_t)bm, (uint32_t)r.busy_mask);
            if ((uint32_t)dut->recover_lsq_ptr != r.lsq_ptr)
                report(tag, "recover_lsq", -1, dut->recover_lsq_ptr, r.lsq_ptr);
        }
    }

    void step(const Inputs& in, const char* tag) {
        apply(in);
        ExpComb c = ref.eval_comb(in);
        check_comb(c, tag);
        last_comb = c;
        ExpReg r = ref.apply(in, c);
        dut->clk = 1;
        dut->eval();
        check_reg(r, tag);
        last_reg = r;
        dut->clk = 0;
        dut->eval();
    }

    void reset() {
        dut->reset = 1;
        dut->in_valid = 0;
        dut->cdb_valid = 0;
        dut->complete_valid = 0;
        dut->br_update_valid = 0;
        dut->clk = 0;
        dut->eval();
        for (int i = 0; i < 3; ++i) {
            dut->clk = 1; dut->eval();
            dut->clk = 0; dut->eval();
        }
        ref = RefRob();
        dut->reset = 0;
        dut->eval();
    }
};

Uop make_uop(uint32_t pc, uint32_t dest, uint8_t rd, bool reg_we,
             uint32_t old_tag = 0, bool is_store = false, bool is_load = false,
             uint8_t lsq = 0, bool branch = false, bool jal = false,
             bool jalr = false, bool illegal = false,
             bool pred_taken = false, uint32_t pred_target = 0) {
    Uop u;
    u.pc = pc;
    u.dest = dest;
    u.rd = rd;
    u.reg_we = reg_we;
    u.old_tag = old_tag;
    u.is_store = is_store;
    u.is_load = is_load;
    u.lsq_id = lsq;
    u.is_branch = branch;
    u.is_jal = jal;
    u.is_jalr = jalr;
    u.illegal = illegal;
    u.pred_taken = pred_taken;
    u.pred_target = pred_target;
    return u;
}

bool run_directed(Harness& h) {
    bool ok = true;
    h.reset();

    // 1. 非控制 uop：完成后才能提交
    Inputs in;
    in.u[0] = make_uop(0x100, 1, 1, true);
    h.step(in, "alloc-a");
    if (!h.ref.q.empty()) { /* model */ }
    in = Inputs{};
    h.step(in, "no-complete");
    if ((bool)h.dut->commit_valid) {
        h.report("directed", "committed before done", 0, 1, 0);
        ok = false;
    }

    in = Inputs{};
    in.cdb_valid = true;
    in.cdb_tag = 1;
    h.step(in, "complete-a");
    in = Inputs{};
    h.step(in, "commit-a");
    if (!h.last_comb.commit_valid[0]) {
        h.report("directed", "commit-a missing", 0, 0, 1);
        ok = false;
    }
    h.step(Inputs{}, "pop-a");

    // 2. 写 x2，old_tag=1，提交应释放 tag1
    in = Inputs{};
    in.u[0] = make_uop(0x104, 2, 2, true, 1);
    h.step(in, "alloc-b");
    in = Inputs{};
    in.cdb_valid = true;
    in.cdb_tag = 2;
    h.step(in, "complete-b");
    in = Inputs{};
    h.step(in, "commit-b");
    if (!h.last_comb.commit_free_valid[0] ||
        h.last_comb.commit_free[0] != 1) {
        h.report("directed", "free old tag", 0, h.last_comb.commit_free[0], 1);
        ok = false;
    }
    h.step(Inputs{}, "pop-b");

    // 3. store：非架构写，提交释放 dest tag
    in = Inputs{};
    in.u[0] = make_uop(0x108, 3, 0, false, 0, true, false, 2);
    h.step(in, "alloc-store");
    in = Inputs{};
    in.comp_valid[0] = true;
    in.comp_tag[0] = 3;
    h.step(in, "complete-store");
    in = Inputs{};
    h.step(in, "commit-store");
    if (!h.last_comb.commit_store[0] ||
        h.last_comb.commit_lsq[0] != 2 ||
        h.last_comb.commit_free[0] != 3) {
        h.report("directed", "store commit", 0, h.last_comb.commit_lsq[0], 2);
        ok = false;
    }
    h.step(Inputs{}, "pop-store");

    // 4. 分支：done 但未收到 br_update 时不能提交
    in = Inputs{};
    in.u[0] = make_uop(0x200, 4, 0, false, 0, false, false, 0, true,
                       false, false, false, false, 0);
    h.step(in, "alloc-branch");
    in = Inputs{};
    in.comp_valid[0] = true;
    in.comp_tag[0] = 4;
    h.step(in, "complete-branch");
    in = Inputs{};
    h.step(in, "branch-unresolved");
    if ((uint32_t)h.dut->commit_valid & 1u) {
        h.report("directed", "branch committed before resolve", 0, 1, 0);
        ok = false;
    }
    in = Inputs{};
    in.br_valid = true;
    in.br_tag = 4;
    in.br_taken = false;
    h.step(in, "resolve-branch");
    in = Inputs{};
    h.step(in, "commit-branch");
    if (!h.last_comb.commit_valid[0] || h.last_reg.redirect_valid) {
        h.report("directed", "branch commit", 0, (uint32_t)h.last_comb.commit_valid[0], 1);
        ok = false;
    }
    h.step(Inputs{}, "pop-branch");

    // 5. 误预测：分支 + 年轻 uop，br_update 应冲刷年轻项
    in = Inputs{};
    in.u[0] = make_uop(0x300, 5, 0, false, 0, false, false, 0, true, false, false,
                       false, false, 0);
    in.u[1] = make_uop(0x304, 6, 0, false);
    h.step(in, "alloc-mispred");
    in = Inputs{};
    in.comp_valid[0] = true;
    in.comp_tag[0] = 5;
    in.comp_valid[1] = true;
    in.comp_tag[1] = 6;
    h.step(in, "complete-mispred");
    in = Inputs{};
    in.br_valid = true;
    in.br_tag = 5;
    in.br_taken = true;
    in.br_target = 0x400;
    h.step(in, "mispredict");
    if (!h.last_reg.redirect_valid ||
        h.last_reg.redirect_pc != 0x400 ||
        !h.last_reg.recover_valid) {
        h.report("directed", "redirect pulse", 0, (uint32_t)h.last_reg.redirect_valid, 1);
        ok = false;
    }
    h.step(Inputs{}, "after-mispredict");

    return ok;
}

void run_random(Harness& h, long iters) {
    h.reset();
    uint32_t next_tag = 1;

    for (long n = 0; n < iters; ++n) {
        Inputs in;
        int nv = (int)(next_rand() % (W + 1));
        for (int l = 0; l < W; ++l) {
            if (l >= nv) break;
            // 找一个当前不在 ROB 中的 dest tag；若找不到则截断到前缀。
            uint32_t tag = ((next_tag++) % (PRF - 1)) + 1;
            bool used = false;
            for (const Entry& x : h.ref.q) if (x.dest == tag) used = true;
            if (used) { nv = l; break; }
            bool branch = (next_rand() & 7u) == 0;
            bool jal = (next_rand() & 31u) == 0;
            bool load = (next_rand() & 15u) == 3;
            bool store = (next_rand() & 15u) == 5;
            in.u[l] = make_uop(next_rand() & ~3u, tag, (uint8_t)(next_rand() % 32),
                               (next_rand() & 1u) != 0,
                               (next_rand() % PRF),
                               store, load, (uint8_t)(next_rand() % LSQ),
                               branch, jal, false, false,
                               (next_rand() & 1u) != 0, next_rand() & ~3u);
        }

        // 随机完成
        if (!h.ref.q.empty() && (next_rand() & 1u)) {
            int idx = (int)(next_rand() % h.ref.q.size());
            in.cdb_valid = true;
            in.cdb_tag = h.ref.q[(size_t)idx].dest;
            in.cdb_exc = (next_rand() & 31u) == 0;
        }
        for (int l = 0; l < W; ++l) {
            if (!h.ref.q.empty() && (next_rand() & 3u) == 0) {
                int idx = (int)(next_rand() % h.ref.q.size());
                in.comp_valid[l] = true;
                in.comp_tag[l] = h.ref.q[(size_t)idx].dest;
                in.comp_exc[l] = (next_rand() & 31u) == 0;
            }
        }

        // 随机分支解析
        std::vector<size_t> ctrls;
        for (size_t i = 0; i < h.ref.q.size(); ++i)
            if (h.ref.q[i].control && !h.ref.q[i].resolved) ctrls.push_back(i);
        if (!ctrls.empty() && (next_rand() & 1u)) {
            size_t i = ctrls[next_rand() % ctrls.size()];
            const Entry& b = h.ref.q[i];
            in.br_valid = true;
            in.br_tag = b.dest;
            in.br_taken = (next_rand() & 1u) != 0;
            in.br_target = (next_rand() & 3u) ? (next_rand() & ~3u) : b.pred_target;
            if (in.br_taken == b.pred_taken && (next_rand() & 1u))
                in.br_target = b.pred_target;
        }

        h.iter = n;
        h.step(in, "random");
    }

    // 排空：完成剩余项并等待提交
    for (int n = 0; n < 2000 && !h.ref.q.empty(); ++n) {
        Inputs in;
        for (size_t i = 0; i < h.ref.q.size() && i < (size_t)W; ++i) {
            in.comp_valid[i] = true;
            in.comp_tag[i] = h.ref.q[i].dest;
        }
        h.step(in, "drain");
    }
    if (!h.ref.q.empty()) {
        h.report("random", "drain timeout", -1, (uint32_t)h.ref.q.size(), 0);
    }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    long random_iters = 50000;
    uint32_t seed = 0x20261018u;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--quick")) random_iters = 10000;
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc)
            seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--cycles") && i + 1 < argc)
            random_iters = strtol(argv[++i], nullptr, 0);
        else {
            printf("usage: %s [--quick] [--seed N] [--cycles N]\n", argv[0]);
            return 2;
        }
    }
    rng_state = seed ? seed : 0x20261018u;

    Vrob dut;
    Harness h;
    h.dut = &dut;

    run_directed(h);
    run_random(h, random_iters);

    printf("rob_tb: W=%d checked=%ld fails=%ld\n", W, h.checked, h.fails);
    if (h.fails != 0) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
