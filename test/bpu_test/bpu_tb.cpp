// -----------------------------------------------------------------------------
// bpu_tb.cpp — verilog/bpu.sv 的 Verilator 单元测试
//
// 参考模型与 RTL 独立实现 BTB + 2-bit BHT：
//   - BTB 直接映射，跳转（无条件/条件 taken）才分配；
//   - BHT 饱和计数，复位 2'b01；
//   - 同拍更新与 fetch 索引冲突时，预测使用更新后的值（写旁路）。
//
// 测试分层：
//   1. 复位与冷启动；
//   2. 定向：无条件跳转、条件分支 2-bit 状态迁移/饱和、BTB tag 别名、
//      目标更新、同拍读写旁路；
//   3. 随机 10 万拍：随机 fetch/update 组合，逐拍与模型对拍；
//   4. 分支流准确率：9-taken/1-not-taken 循环、交替模式、冷启动。
//
// 参数可用环境变量 BPU_BTB_INDEX_BITS / BPU_BHT_INDEX_BITS 覆盖，
// 参考模型通过 -DTB_BTB_INDEX_BITS/-DTB_BHT_INDEX_BITS 同步。
// -----------------------------------------------------------------------------

#include "Vbpu.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#ifndef TB_BTB_INDEX_BITS
#define TB_BTB_INDEX_BITS 6
#endif
#ifndef TB_BHT_INDEX_BITS
#define TB_BHT_INDEX_BITS 8
#endif

namespace {

constexpr int      BTB_INDEX_BITS = TB_BTB_INDEX_BITS;
constexpr int      BHT_INDEX_BITS = TB_BHT_INDEX_BITS;
constexpr uint32_t BTB_DEPTH      = 1u << BTB_INDEX_BITS;
constexpr uint32_t BHT_DEPTH      = 1u << BHT_INDEX_BITS;
constexpr uint32_t BTB_TAG_SHIFT  = BTB_INDEX_BITS + 2;
constexpr uint32_t BHT_INDEX_MASK = BHT_DEPTH - 1u;
constexpr uint32_t BTB_INDEX_MASK = BTB_DEPTH - 1u;

static_assert(BTB_INDEX_BITS >= 2 && BTB_INDEX_BITS <= 16, "BTB index bits out of range");
static_assert(BHT_INDEX_BITS >= 2 && BHT_INDEX_BITS <= 16, "BHT index bits out of range");

uint32_t rng_state = 0x20261018u;

uint32_t next_rand() {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

uint32_t btb_index(uint32_t pc) { return (pc >> 2) & BTB_INDEX_MASK; }
uint32_t btb_tag(uint32_t pc)   { return pc >> BTB_TAG_SHIFT; }
uint32_t bht_index(uint32_t pc) { return (pc >> 2) & BHT_INDEX_MASK; }

struct Inputs {
    uint32_t fetch_pc = 0;
    bool     upd_valid = false;
    uint32_t upd_pc = 0;
    bool     upd_taken = false;
    uint32_t upd_target = 0;
    bool     upd_uncond = false;
};

struct Prediction {
    bool     taken = false;
    uint32_t target = 0;
};

struct BtbEntry {
    bool     valid = false;
    uint32_t tag = 0;
    uint32_t target = 0;
    bool     uncond = false;
};

struct RefBpu {
    std::vector<BtbEntry> btb;
    std::vector<uint8_t>  bht;

    RefBpu() : btb(BTB_DEPTH), bht(BHT_DEPTH, 1) {}

    void reset() {
        for (auto& e : btb) e = BtbEntry{};
        for (auto& c : bht) c = 1;
    }

    uint8_t next_counter(uint32_t pc, bool taken, bool uncond) const {
        uint8_t cur = bht[bht_index(pc)];
        if (uncond) return 3;
        if (taken) return (cur == 3) ? 3 : (uint8_t)(cur + 1);
        return (cur == 0) ? 0 : (uint8_t)(cur - 1);
    }

    Prediction predict(const Inputs& in) const {
        uint32_t fi = btb_index(in.fetch_pc);
        uint32_t bi = bht_index(in.fetch_pc);
        BtbEntry e = btb[fi];
        uint8_t ctr = bht[bi];
        bool upd_hit = btb[btb_index(in.upd_pc)].valid &&
                       btb[btb_index(in.upd_pc)].tag == btb_tag(in.upd_pc);

        if (in.upd_valid && btb_index(in.upd_pc) == fi) {
            if (in.upd_uncond) {
                e = BtbEntry{true, btb_tag(in.upd_pc), in.upd_target, true};
            } else if (in.upd_taken) {
                e = BtbEntry{true, btb_tag(in.upd_pc), in.upd_target, false};
            } else if (e.valid && e.tag == btb_tag(in.upd_pc)) {
                e.uncond = false;
            }
        }
        if (in.upd_valid && bht_index(in.upd_pc) == bi) {
            if (in.upd_uncond) {
                ctr = 3;
            } else if (in.upd_taken) {
                ctr = upd_hit ? next_counter(in.upd_pc, in.upd_taken, false) : 2;
            } else if (upd_hit) {
                ctr = next_counter(in.upd_pc, false, false);
            }
        }

        bool hit = e.valid && (e.tag == btb_tag(in.fetch_pc));
        Prediction p;
        p.taken  = hit && (e.uncond || ((ctr >> 1) & 1u));
        p.target = hit ? e.target : 0;
        return p;
    }

    void update(const Inputs& in) {
        if (!in.upd_valid) return;
        uint32_t fi = btb_index(in.upd_pc);
        uint32_t bi = bht_index(in.upd_pc);
        bool upd_hit = btb[fi].valid && btb[fi].tag == btb_tag(in.upd_pc);

        if (in.upd_uncond) {
            btb[fi] = BtbEntry{true, btb_tag(in.upd_pc), in.upd_target, true};
            bht[bi] = 3;
        } else if (in.upd_taken) {
            btb[fi] = BtbEntry{true, btb_tag(in.upd_pc), in.upd_target, false};
            bht[bi] = upd_hit ? next_counter(in.upd_pc, true, false) : 2;
        } else if (upd_hit) {
            btb[fi].uncond = false;
            bht[bi] = next_counter(in.upd_pc, false, false);
        }
    }
};

struct Harness {
    Vbpu*  dut = nullptr;
    RefBpu ref;
    long   checked = 0;
    long   fails = 0;
    long   reported = 0;
    Prediction last_pre;

    void apply(const Inputs& in) {
        dut->reset          = 0;
        dut->fetch_pc       = in.fetch_pc;
        dut->upd_valid      = in.upd_valid;
        dut->upd_pc         = in.upd_pc;
        dut->upd_taken      = in.upd_taken;
        dut->upd_target     = in.upd_target;
        dut->upd_is_uncond  = in.upd_uncond;
        dut->clk            = 0;
        dut->eval();
    }

    void report(const char* tag, long idx, const char* phase, const Inputs& in,
                bool got_taken, uint32_t got_target, bool want_taken, uint32_t want_target) {
        ++fails;
        if (reported >= 15) return;
        ++reported;
        printf("FAIL [%s] idx=%ld %s fetch=%08x upd=%d pc=%08x taken=%d "
               "target=%08x uncond=%d | got taken=%d target=%08x, want taken=%d target=%08x\n",
               tag, idx, phase, in.fetch_pc, in.upd_valid, in.upd_pc, in.upd_taken,
               in.upd_target, in.upd_uncond, got_taken, got_target, want_taken, want_target);
    }

    bool compare_prediction(const Inputs& in, const Prediction& want, const char* tag,
                            long idx, const char* phase) {
        ++checked;
        bool got_taken = dut->predict_taken != 0;
        uint32_t got_target = (uint32_t)dut->predict_target;
        if (got_taken != want.taken || got_target != want.target) {
            report(tag, idx, phase, in, got_taken, got_target, want.taken, want.target);
            return false;
        }
        return true;
    }

    // 无更新的显式期望（定向用例）。
    bool expect(uint32_t pc, bool want_taken, uint32_t want_target, const char* tag) {
        Inputs in;
        in.fetch_pc = pc;
        apply(in);
        ++checked;
        bool got_taken = dut->predict_taken != 0;
        uint32_t got_target = (uint32_t)dut->predict_target;
        if (got_taken != want_taken || got_target != want_target) {
            report(tag, -1, "expect", in, got_taken, got_target, want_taken, want_target);
            return false;
        }
        return true;
    }

    // 完整一拍：组合预测对拍模型 -> 时钟沿更新 -> 更新后预测再对拍。
    bool cycle(const Inputs& in, const char* tag, long idx = -1) {
        apply(in);
        last_pre = ref.predict(in);
        bool ok = compare_prediction(in, last_pre, tag, idx, "pre");
        dut->clk = 1;
        dut->eval();
        ref.update(in);
        // 下一拍更新脉冲已撤销，再检查寄存器更新后的组合预测。
        dut->upd_valid = 0;
        dut->eval();
        Prediction post = ref.predict(Inputs{in.fetch_pc, false, 0, false, 0, false});
        ok &= compare_prediction(in, post, tag, idx, "post");
        return ok;
    }

    // 带显式 pre 期望的一拍，用于同拍旁路等关键属性。
    bool cycle_expect(const Inputs& in, bool want_taken, uint32_t want_target,
                      const char* tag, long idx = -1) {
        apply(in);
        ++checked;
        bool got_taken = dut->predict_taken != 0;
        uint32_t got_target = (uint32_t)dut->predict_target;
        bool ok = true;
        if (got_taken != want_taken || got_target != want_target) {
            report(tag, idx, "pre(explicit)", in, got_taken, got_target, want_taken, want_target);
            ok = false;
        }
        dut->clk = 1;
        dut->eval();
        ref.update(in);
        dut->upd_valid = 0;
        dut->eval();
        Prediction post = ref.predict(Inputs{in.fetch_pc, false, 0, false, 0, false});
        ok &= compare_prediction(in, post, tag, idx, "post");
        return ok;
    }

    void hard_reset() {
        dut->reset = 1;
        dut->fetch_pc = 0;
        dut->upd_valid = 0;
        dut->upd_pc = 0;
        dut->upd_taken = 0;
        dut->upd_target = 0;
        dut->upd_is_uncond = 0;
        for (int i = 0; i < 3; ++i) {
            dut->clk = 0;
            dut->eval();
            dut->clk = 1;
            dut->eval();
            ref.reset();
        }
        dut->reset = 0;
        dut->clk = 0;
        dut->eval();
    }
};

bool run_directed(Harness& h) {
    bool ok = true;
    const uint32_t uncond_pc   = 0x00001000u;
    const uint32_t uncond_target = 0x00002000u;
    const uint32_t same_index_pc = uncond_pc + (1u << BTB_TAG_SHIFT);

    h.hard_reset();
    ok &= h.expect(0x0u, false, 0x0u, "post-reset");
    ok &= h.expect(uncond_pc, false, 0x0u, "cold-miss");
    ok &= h.expect(0x0000ff00u, false, 0x0u, "cold-miss-2");

    // ---- 无条件跳转：跳转当拍旁路分配，次拍命中 ---------------------------
    Inputs u;
    u.fetch_pc = uncond_pc;
    u.upd_valid = true;
    u.upd_pc = uncond_pc;
    u.upd_taken = true;
    u.upd_target = uncond_target;
    u.upd_uncond = true;
    ok &= h.cycle_expect(u, true, uncond_target, "uncond-bypass");
    ok &= h.expect(uncond_pc, true, uncond_target, "uncond-predict");
    ok &= h.expect(same_index_pc, false, 0x0u, "uncond-tag-miss");

    // ---- 条件分支：BHT 2-bit 状态迁移与饱和 -------------------------------
    const uint32_t cond_pc = 0x00002000u;
    const uint32_t cond_target = 0x00002100u;

    ok &= h.expect(cond_pc, false, 0x0u, "cond-cold");
    Inputs c;
    c.fetch_pc = cond_pc;
    c.upd_valid = true;
    c.upd_pc = cond_pc;
    c.upd_taken = true;
    c.upd_target = cond_target;
    c.upd_uncond = false;
    // 01 -> 10：更新当拍旁路后应预测 taken
    ok &= h.cycle_expect(c, true, cond_target, "cond-taken-bypass");
    ok &= h.expect(cond_pc, true, cond_target, "cond-weak-taken");

    c.upd_taken = true;
    ok &= h.cycle_expect(c, true, cond_target, "cond-strong-taken");
    ok &= h.expect(cond_pc, true, cond_target, "cond-strong-taken-predict");
    ok &= h.cycle(c, "cond-saturate-11");

    c.upd_taken = false;
    ok &= h.cycle_expect(c, true, cond_target, "cond-nt-1");
    ok &= h.expect(cond_pc, true, cond_target, "cond-strong-taken-after-nt");
    ok &= h.cycle(c, "cond-nt-2");
    ok &= h.expect(cond_pc, false, cond_target, "cond-weak-nt");
    ok &= h.cycle(c, "cond-nt-saturate");
    ok &= h.expect(cond_pc, false, cond_target, "cond-strong-nt");

    c.upd_taken = true;
    ok &= h.cycle(c, "cond-retrain-1");
    ok &= h.expect(cond_pc, false, cond_target, "cond-retrain-still-nt");
    ok &= h.cycle(c, "cond-retrain-2");
    ok &= h.expect(cond_pc, true, cond_target, "cond-retrain-taken");

    // ---- 目标更新 ----------------------------------------------------------
    const uint32_t new_target = 0x00002200u;
    c.upd_taken = true;
    c.upd_target = new_target;
    ok &= h.cycle(c, "cond-target-update");
    ok &= h.expect(cond_pc, true, new_target, "cond-new-target");

    // ---- BTB tag 别名：同索引不同 tag 覆盖 ---------------------------------
    const uint32_t alias_pc = cond_pc + (1u << BTB_TAG_SHIFT);
    Inputs a;
    a.fetch_pc = alias_pc;
    a.upd_valid = true;
    a.upd_pc = alias_pc;
    a.upd_taken = true;
    a.upd_target = 0x00003000u;
    a.upd_uncond = false;
    ok &= h.cycle(a, "alias-alloc");
    ok &= h.expect(alias_pc, true, 0x00003000u, "alias-predict");
    ok &= h.expect(cond_pc, false, 0x0u, "alias-evicted");

    // ---- 同拍读写旁路：条件 taken 在 fetch 同一 PC 当拍可见 ----------------
    // 先把 cond_pc 重新训练到 10，再用同 PC 的 taken 更新触发 10->11 旁路。
    ok &= h.cycle(c, "realloc-cond");
    ok &= h.cycle(c, "realloc-cond-2");
    c.upd_taken = false;
    ok &= h.cycle(c, "prep-nt");
    c.upd_taken = true;
    c.upd_target = 0x00002300u;
    c.fetch_pc = cond_pc;
    ok &= h.cycle_expect(c, true, 0x00002300u, "same-cycle-cond-bypass");

    // ---- 复位清空 BTB/BHT ------------------------------------------------
    h.hard_reset();
    ok &= h.expect(cond_pc, false, 0x0u, "reset-clears-cond");
    ok &= h.expect(uncond_pc, false, 0x0u, "reset-clears-uncond");

    return ok;
}

void run_random(Harness& h, long iters) {
    uint32_t pool[16];
    for (uint32_t& pc : pool) pc = next_rand() & ~3u;

    for (long i = 0; i < iters; ++i) {
        Inputs in;
        in.fetch_pc = (next_rand() & 7u) == 0 ? (next_rand() & ~3u) : pool[next_rand() & 15u];
        in.upd_valid = (next_rand() & 3u) != 0;
        in.upd_pc = ((next_rand() & 3u) == 0) ? in.fetch_pc : pool[next_rand() & 15u];
        in.upd_uncond = (next_rand() & 7u) == 0;
        in.upd_taken = in.upd_uncond || ((next_rand() & 1u) != 0);
        in.upd_target = next_rand() & ~3u;
        h.cycle(in, "random", i);
    }
}

void run_accuracy(Harness& h) {
    h.hard_reset();

    // 9 taken / 1 not-taken 的循环分支。
    const uint32_t loop_pc = 0x00008000u;
    const uint32_t loop_target = 0x00007f00u;
    long correct = 0;
    long total = 0;
    for (int rep = 0; rep < 1000; ++rep) {
        for (int k = 0; k < 10; ++k) {
            bool actual_taken = (k != 9);
            Inputs in;
            in.fetch_pc = loop_pc;
            in.upd_valid = true;
            in.upd_pc = loop_pc;
            in.upd_taken = actual_taken;
            in.upd_target = loop_target;
            in.upd_uncond = false;
            Prediction pred = h.ref.predict(Inputs{loop_pc, false, 0, false, 0, false});
            if (pred.taken == actual_taken) ++correct;
            ++total;
            h.cycle(in, "accuracy-loop");
        }
    }
    printf("loop 9T/1N accuracy: %ld/%ld = %.2f%%\n", correct, total,
           100.0 * (double)correct / (double)total);

    // 交替 taken/not-taken：2-bit 计数器会持续错一半左右，仅记录基线。
    h.hard_reset();
    correct = 0;
    total = 0;
    for (int rep = 0; rep < 1000; ++rep) {
        for (int k = 0; k < 10; ++k) {
            bool actual_taken = (k & 1) == 0;
            Inputs in;
            in.fetch_pc = loop_pc;
            in.upd_valid = true;
            in.upd_pc = loop_pc;
            in.upd_taken = actual_taken;
            in.upd_target = loop_target;
            in.upd_uncond = false;
            Prediction pred = h.ref.predict(Inputs{loop_pc, false, 0, false, 0, false});
            if (pred.taken == actual_taken) ++correct;
            ++total;
            h.cycle(in, "accuracy-alt");
        }
    }
    printf("alternating accuracy: %ld/%ld = %.2f%%\n", correct, total,
           100.0 * (double)correct / (double)total);
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    long random_iters = 100000;
    uint32_t seed = 0x20261018u;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--quick")) {
            random_iters = 10000;
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

    Vbpu dut;
    Harness h;
    h.dut = &dut;

    run_directed(h);
    run_random(h, random_iters);
    run_accuracy(h);

    printf("bpu_tb: btb=%d bits bht=%d bits checked=%ld fails=%ld\n",
           BTB_INDEX_BITS, BHT_INDEX_BITS, h.checked, h.fails);
    if (h.fails != 0) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
