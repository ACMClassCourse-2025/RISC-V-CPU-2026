// -----------------------------------------------------------------------------
// pc_unit_tb.cpp — verilog/pc_unit.sv 的 Verilator 单元测试
//
// 参考模型（每个时钟沿更新一次）：
//   reset        -> pc = 0
//   redirect     -> pc = redirect_pc
//   stall        -> pc 保持
//   advance      -> pc = pc + 4（32 位自然回绕）
// 优先级：reset > redirect > stall > advance。
//
// 测试分层：
//   1. 复位（包括复位与 redirect/stall/advance 同拍冲突）；
//   2. 定向用例：空闲、连续推进、stall、advance+stall、
//      redirect 单独/同拍 advance/同拍 stall/三者同拍、连续 redirect、
//      redirect 次拍生效、pc+4 回绕；
//   3. 10 万拍随机对拍（默认；--quick 为 1 万拍）。
//
// 编译与运行见 test/pc_unit_test/run.sh。
// -----------------------------------------------------------------------------

#include "Vpc_unit.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

constexpr uint32_t RESET_PC = 0x00000000u;

uint32_t rng_state = 0x20261018u;

uint32_t next_rand() {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

struct Harness {
    Vpc_unit* dut = nullptr;
    uint32_t model_pc = RESET_PC;
    long checked = 0;
    long fails = 0;
    long reported = 0;

    void tick() {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
    }

    void report_fail(const char* tag, long cycle, uint32_t prev_pc, uint32_t target,
                     bool reset, bool advance, bool stall, bool redirect,
                     uint32_t got, uint32_t want) {
        ++fails;
        if (reported >= 12) return;
        ++reported;
        printf("FAIL [%s] cycle=%ld prev=%08x reset=%d advance=%d stall=%d "
               "redirect=%d target=%08x | pc=%08x want=%08x\n",
               tag, cycle, prev_pc, reset, advance, stall, redirect, target, got, want);
    }

    // 施加一拍输入并更新参考模型；返回本拍是否通过。
    bool step(bool reset, bool advance, bool stall, bool redirect, uint32_t target,
              const char* tag, long cycle = -1) {
        dut->reset = reset;
        dut->advance = advance;
        dut->stall = stall;
        dut->redirect_valid = redirect;
        dut->redirect_pc = target;
        tick();

        uint32_t prev_pc = model_pc;
        if (reset) {
            model_pc = RESET_PC;
        } else if (redirect) {
            model_pc = target;
        } else if (stall) {
            model_pc = prev_pc;
        } else if (advance) {
            model_pc = prev_pc + 4u;
        }

        ++checked;
        uint32_t got = (uint32_t)dut->pc;
        if (got != model_pc) {
            report_fail(tag, cycle, prev_pc, target, reset, advance, stall, redirect,
                        got, model_pc);
            return false;
        }
        return true;
    }
};

bool run_directed(Harness& h) {
    bool ok = true;

    // ---- 复位：制造冲突输入，验证 reset 最高优先级 -------------------------
    ok &= h.step(true, true, true, true, 0xdeadbeefu, "reset priority");
    ok &= h.step(true, true, false, true, 0x12345678u, "reset priority");
    ok &= h.step(true, false, true, false, 0x0u, "reset priority");
    ok &= h.step(false, false, false, false, 0x0u, "post-reset idle");

    // ---- 空闲保持 ----------------------------------------------------------
    for (int i = 0; i < 4; ++i) {
        ok &= h.step(false, false, false, false, 0x0u, "idle");
    }

    // ---- 连续推进 ----------------------------------------------------------
    for (int i = 0; i < 32; ++i) {
        ok &= h.step(false, true, false, false, 0x0u, "advance");
    }

    // ---- stall 优先于 advance，释放后继续推进 ------------------------------
    for (int i = 0; i < 5; ++i) {
        ok &= h.step(false, true, true, false, 0x0u, "stall+advance");
    }
    for (int i = 0; i < 3; ++i) {
        ok &= h.step(false, false, true, false, 0x0u, "stall");
    }
    ok &= h.step(false, true, false, false, 0x0u, "advance after stall");

    // ---- redirect 单独有效 -------------------------------------------------
    const uint32_t targets[] = {
        0x00000000u, 0x00000004u, 0x80000000u, 0x12345678u,
        0xffffff8cu, 0xfffffffeu, 0xffffffffu,
    };
    for (uint32_t target : targets) {
        ok &= h.step(false, false, false, true, target, "redirect");
    }

    // ---- redirect 优先级高于 advance / stall -------------------------------
    ok &= h.step(false, true, false, true, 0x20000000u, "advance+redirect");
    ok &= h.step(false, false, true, true, 0x20000004u, "stall+redirect");
    ok &= h.step(false, true, true, true, 0x20000008u, "all+redirect");

    // redirect 到当前 PC：有效但值不变
    ok &= h.step(false, false, false, true, h.model_pc, "redirect self");

    // ---- redirect 当拍接受、次拍已切换，随后可继续推进 ---------------------
    ok &= h.step(false, false, false, true, 0x00001000u, "redirect next-pc");
    ok &= h.step(false, true, false, false, 0x0u, "redirect then advance");

    // ---- 连续 redirect：后一拍的目标生效 -----------------------------------
    ok &= h.step(false, false, false, true, 0x00003000u, "redirect 1");
    ok &= h.step(false, false, false, true, 0x00004000u, "redirect 2");

    // ---- pc+4 回绕 ---------------------------------------------------------
    ok &= h.step(false, false, false, true, 0xfffffffcu, "wrap setup fc");
    ok &= h.step(false, true, false, false, 0x0u, "pc+4 wrap fc");
    ok &= h.step(false, true, false, false, 0x0u, "wrap continue");

    ok &= h.step(false, false, false, true, 0xfffffffeu, "wrap setup fe");
    ok &= h.step(false, true, false, false, 0x0u, "wrap fe+4");
    ok &= h.step(false, true, false, false, 0x0u, "wrap fe+8");

    ok &= h.step(false, false, false, true, 0xfffffff8u, "wrap setup f8");
    ok &= h.step(false, true, false, false, 0x0u, "wrap f8+4");
    ok &= h.step(false, true, false, false, 0x0u, "wrap f8+8");

    return ok;
}

void run_random(Harness& h, long iters) {
    for (long i = 0; i < iters; ++i) {
        uint32_t r = next_rand();
        bool reset = ((r & 0xffu) == 0x5au);          // 约 1/256
        bool redirect = !reset && ((r & 0x7u) == 0);  // 约 1/8
        bool stall = ((r >> 4) & 1u) != 0;            // 1/2
        bool advance = ((r >> 5) & 1u) != 0;          // 1/2
        uint32_t target = next_rand();

        // 偶尔把重定向目标放到回绕边界附近。
        if ((next_rand() & 0x1fu) == 0) {
            target = ((target & 1u) != 0) ? 0xfffffffcu : 0xfffffff8u;
        }

        h.step(reset, advance, stall, redirect, target, "random", i);
    }
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

    Vpc_unit dut;
    Harness h;
    h.dut = &dut;

    run_directed(h);
    run_random(h, random_iters);

    printf("pc_unit_tb: checked=%ld fails=%ld\n", h.checked, h.fails);
    if (h.fails != 0) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
