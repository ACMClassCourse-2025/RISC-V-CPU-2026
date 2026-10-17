// -----------------------------------------------------------------------------
// bpu_gshare_tb.cpp — bpu_gshare 的 Verilator 单元测试
//
// 串行分支流：每个分支先读本拍预测，再在时钟沿更新 BPU。C++ 参考模型独立
// 实现 BTB + gshare，并同时维护一个普通 2-bit BHT 作为准确率对照。
// -----------------------------------------------------------------------------

#include "Vbpu_gshare.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#ifndef TB_BTB_BITS
#define TB_BTB_BITS 6
#endif
#ifndef TB_BHT_BITS
#define TB_BHT_BITS 8
#endif
#ifndef TB_GHIST_BITS
#define TB_GHIST_BITS 8
#endif

namespace {

constexpr int BTB_BITS = TB_BTB_BITS;
constexpr int BHT_BITS = TB_BHT_BITS;
constexpr int GH_BITS  = TB_GHIST_BITS;
constexpr uint32_t BTB_DEPTH = 1u << BTB_BITS;
constexpr uint32_t BHT_DEPTH = 1u << BHT_BITS;
constexpr uint32_t BTB_MASK  = BTB_DEPTH - 1u;
constexpr uint32_t BHT_MASK  = BHT_DEPTH - 1u;
constexpr uint32_t TAG_SHIFT = BTB_BITS + 2;

uint32_t rng_state = 0x20261018u;
uint32_t next_rand() {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

struct Entry { bool valid = false; uint32_t tag = 0, target = 0; bool uncond = false; };

struct RefBpu {
    bool gshare;
    Entry btb[BTB_DEPTH];
    uint8_t bht[BHT_DEPTH];
    uint8_t ghr = 0;
    uint8_t ghr_bits = 0;

    explicit RefBpu(bool gs) : gshare(gs) {
        for (auto& e : btb) e = Entry{};
        for (auto& c : bht) c = 1;
    }

    uint32_t btb_index(uint32_t pc) const { return (pc >> 2) & BTB_MASK; }
    uint32_t btb_tag(uint32_t pc) const { return pc >> TAG_SHIFT; }
    uint32_t bht_index(uint32_t pc) const {
        uint32_t idx = (pc >> 2) & BHT_MASK;
        if (gshare) {
            uint32_t gmask = (GH_BITS >= 32) ? 0xffffffffu : ((1u << GH_BITS) - 1u);
            idx ^= (ghr & gmask & BHT_MASK);
        }
        return idx;
    }

    bool predict(uint32_t pc, uint32_t* target) const {
        uint32_t bi = btb_index(pc);
        uint32_t bh = bht_index(pc);
        bool hit = btb[bi].valid && btb[bi].tag == btb_tag(pc);
        *target = hit ? btb[bi].target : 0;
        return hit && (btb[bi].uncond || (bht[bh] >= 2));
    }

    void update(uint32_t pc, bool taken, uint32_t target, bool uncond) {
        uint32_t bi = btb_index(pc);
        uint32_t bh = bht_index(pc);
        bool hit = btb[bi].valid && btb[bi].tag == btb_tag(pc);

        if (uncond) {
            btb[bi] = Entry{true, btb_tag(pc), target, true};
            bht[bh] = 3;
        } else if (taken) {
            btb[bi] = Entry{true, btb_tag(pc), target, false};
            bht[bh] = hit ? (bht[bh] == 3 ? 3 : (uint8_t)(bht[bh] + 1)) : 2;
        } else if (hit) {
            btb[bi].uncond = false;
            bht[bh] = bht[bh] == 0 ? 0 : (uint8_t)(bht[bh] - 1);
        }
        if (gshare) {
            uint32_t gmask = (GH_BITS >= 32) ? 0xffffffffu : ((1u << GH_BITS) - 1u);
            ghr = (uint8_t)(((ghr << 1) | (taken ? 1u : 0u)) & gmask);
        }
    }
};

struct Harness {
    Vbpu_gshare* dut = nullptr;
    long checked = 0, fails = 0;
    long step_no = 0;

    void fail(const char* tag, uint32_t pc, uint32_t got_t, uint32_t got_pc,
              uint32_t want_t, uint32_t want_pc) {
        ++fails;
        if (fails <= 15)
            printf("FAIL [%s] step=%ld pc=%08x got taken=%u target=%08x want taken=%u target=%08x\n",
                   tag, step_no, pc, got_t, got_pc, want_t, want_pc);
    }

    void tick() {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    }

    void reset() {
        dut->reset = 1;
        dut->upd_valid = 0;
        dut->fetch_pc = 0;
        for (int i = 0; i < 3; ++i) tick();
        dut->reset = 0;
        dut->clk = 0; dut->eval();
    }

    // 串行一步：先比较预测，再更新。
    void step(RefBpu& ref, uint32_t pc, bool taken, uint32_t target,
              bool uncond, const char* tag) {
        ++step_no;
        dut->reset = 0;
        dut->upd_valid = 0;
        dut->fetch_pc = pc;
        dut->clk = 0;
        dut->eval();

        uint32_t want_target = 0;
        bool want_taken = ref.predict(pc, &want_target);
        ++checked;
        if ((bool)dut->predict_taken != want_taken ||
            (uint32_t)dut->predict_target != want_target) {
            fail(tag, pc, dut->predict_taken, dut->predict_target,
                 want_taken, want_target);
        }

        dut->upd_valid = 1;
        dut->upd_pc = pc;
        dut->upd_taken = taken;
        dut->upd_target = target;
        dut->upd_is_uncond = uncond;
        dut->clk = 1;
        dut->eval();
        ref.update(pc, taken, target, uncond);
        dut->upd_valid = 0;
        dut->clk = 0;
        dut->eval();
    }
};

void run_loop(Harness& h) {
    RefBpu gs(true), bht(false);
    h.reset();
    long correct_gs = 0, correct_bht = 0, total = 0;
    const uint32_t pc = 0x00001000u;
    const uint32_t target = 0x00000f00u;

    for (int rep = 0; rep < 2000; ++rep) {
        for (int k = 0; k < 10; ++k) {
            bool taken = (k != 9);
            uint32_t tgt = 0;
            bool pgs = gs.predict(pc, &tgt);
            bool pb  = bht.predict(pc, &tgt);
            if (pgs == taken) ++correct_gs;
            if (pb == taken) ++correct_bht;
            ++total;
            h.step(gs, pc, taken, target, false, "loop");
            bht.update(pc, taken, target, false);
        }
    }
    printf("loop 9T/1N: gshare %ld/%ld = %.2f%%, bht %ld/%ld = %.2f%%\n",
           correct_gs, total, 100.0 * correct_gs / total,
           correct_bht, total, 100.0 * correct_bht / total);
}

void run_correlated(Harness& h) {
    RefBpu gs(true), bht(false);
    h.reset();
    long correct_gs = 0, correct_bht = 0, total = 0;
    const uint32_t a = 0x00002000u, b = 0x00002040u;

    // A 每次 taken；B 跟随 A 的历史，A 上次 taken 则 B taken，否则 B 不跳。
    bool a_taken = true;
    for (int i = 0; i < 5000; ++i) {
        uint32_t tgt = 0;
        bool pa = gs.predict(a, &tgt);
        bool pba = bht.predict(a, &tgt);
        if (pa == a_taken) ++correct_gs;
        if (pba == a_taken) ++correct_bht;
        ++total;
        h.step(gs, a, a_taken, 0x2100, false, "corr-a");
        bht.update(a, a_taken, 0x2100, false);

        bool b_taken = a_taken;
        bool pb = gs.predict(b, &tgt);
        bool pbb = bht.predict(b, &tgt);
        if (pb == b_taken) ++correct_gs;
        if (pbb == b_taken) ++correct_bht;
        ++total;
        h.step(gs, b, b_taken, 0x2080, false, "corr-b");
        bht.update(b, b_taken, 0x2080, false);
        a_taken = !a_taken;
    }
    printf("correlated: gshare %ld/%ld = %.2f%%, bht %ld/%ld = %.2f%%\n",
           correct_gs, total, 100.0 * correct_gs / total,
           correct_bht, total, 100.0 * correct_bht / total);
}

void run_random(Harness& h, long iters) {
    RefBpu gs(true), bht(false);
    h.reset();
    uint32_t pool[8];
    for (uint32_t& p : pool) p = next_rand() & ~3u;

    long correct_gs = 0, total = 0;
    for (long i = 0; i < iters; ++i) {
        uint32_t pc = pool[next_rand() & 7u];
        bool taken = (next_rand() & 1u) != 0;
        bool uncond = (next_rand() & 31u) == 0;
        if (uncond) taken = true;
        uint32_t target = next_rand() & ~3u;
        uint32_t tgt = 0;
        bool pgs = gs.predict(pc, &tgt);
        if (pgs == taken) ++correct_gs;
        ++total;
        h.step(gs, pc, taken, target, uncond, "random");
        bht.update(pc, taken, target, uncond);
    }
    printf("random: gshare accuracy %ld/%ld = %.2f%%\n",
           correct_gs, total, 100.0 * correct_gs / total);
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    long iters = 50000;
    uint32_t seed = 0x20261018u;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--quick")) iters = 10000;
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc)
            seed = (uint32_t)strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--cycles") && i + 1 < argc)
            iters = strtol(argv[++i], nullptr, 0);
        else {
            printf("usage: %s [--quick] [--seed N] [--cycles N]\n", argv[0]);
            return 2;
        }
    }
    rng_state = seed ? seed : 0x20261018u;

    Vbpu_gshare dut;
    Harness h;
    h.dut = &dut;

    h.reset();
    run_loop(h);
    run_correlated(h);
    run_random(h, iters);

    printf("bpu_gshare_tb: btb=%d bht=%d ghr=%d checked=%ld fails=%ld\n",
           BTB_BITS, BHT_BITS, GH_BITS, h.checked, h.fails);
    if (h.fails != 0) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
