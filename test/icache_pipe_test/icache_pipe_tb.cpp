// -----------------------------------------------------------------------------
// icache_pipe_tb.cpp — verilog/icache_pipe.sv 的 Verilator 单元测试
//
// 覆盖：
//   1. 复位、冷缺失/回填、重复访问命中；
//   2. 连续命中吞吐（每拍一条）；
//   3. fetch_resp_ready 反压时输出保持；
//   4. flush 冲刷 lookup / 回填中的旧响应 / 输出缓冲；
//   5. 随机 fetch/ready/flush + 随机回填延迟，输出顺序与数据对拍。
//
// 回填内存用确定性函数 mem_word(addr)；测试台在 refill_valid 期间保持地址
// 稳定，并检查 DUT 没有中途换地址。
// -----------------------------------------------------------------------------

#include "Vicache_pipe.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <vector>

namespace {

uint32_t rng_state = 0x20261018u;

uint32_t next_rand() {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

uint32_t mem_word(uint32_t addr) {
    return (addr & 0xfffffffcu) ^ 0x5a5a0000u;
}

struct Harness {
    Vicache_pipe* dut = nullptr;
    std::deque<uint32_t> expected;
    long checked = 0;
    long fails = 0;
    long reported = 0;
    long accepts = 0;
    long responses = 0;
    long refills = 0;
    bool random_refill_latency = false;
    int  fixed_refill_latency = 0;

    // 回填驱动状态
    bool     r_wait = false;
    uint32_t r_addr = 0;
    int      r_countdown = 0;
    bool     r_drive = false;

    void report(const char* tag, const char* why, uint32_t pc, uint32_t got, uint32_t want) {
        ++fails;
        if (reported >= 15) return;
        ++reported;
        printf("FAIL [%s] %s pc=%08x got=%08x want=%08x\n", tag, why, pc, got, want);
    }

    void eval_inputs() {
        dut->clk = 0;
        dut->eval();
    }

    // 一次时钟沿；期间维护回填响应驱动。
    void tick() {
        eval_inputs();

        r_drive = false;
        if (!r_wait && dut->refill_valid) {
            r_wait = true;
            r_addr = (uint32_t)dut->refill_addr;
            r_countdown = random_refill_latency
                              ? (int)(next_rand() % 5u)
                              : fixed_refill_latency;
            if ((r_addr & 3u) != 0) {
                report("refill", "unaligned refill address", r_addr, r_addr, 0);
            }
        }
        if (r_wait) {
            if (!dut->refill_valid) {
                report("refill", "refill_valid dropped before response", r_addr,
                       (uint32_t)dut->refill_valid, 1);
            } else if ((uint32_t)dut->refill_addr != r_addr) {
                report("refill", "refill address changed while waiting", r_addr,
                       (uint32_t)dut->refill_addr, r_addr);
            }
            if (r_countdown == 0) {
                r_drive = true;
                dut->refill_resp_valid = 1;
                dut->refill_rdata = mem_word(r_addr);
            } else {
                --r_countdown;
                dut->refill_resp_valid = 0;
                dut->refill_rdata = 0;
            }
        } else {
            dut->refill_resp_valid = 0;
            dut->refill_rdata = 0;
        }

        dut->eval();
        dut->clk = 1;
        dut->eval();
        dut->refill_resp_valid = 0;
        dut->refill_rdata = 0;
        dut->eval();

        if (r_drive) {
            ++refills;
            r_wait = false;
        }
    }

    void reset() {
        dut->reset = 1;
        dut->flush = 0;
        dut->fetch_valid = 0;
        dut->fetch_pc = 0;
        dut->fetch_resp_ready = 0;
        dut->refill_resp_valid = 0;
        dut->refill_rdata = 0;
        expected.clear();
        r_wait = false;
        for (int i = 0; i < 3; ++i) tick();
        dut->reset = 0;
        tick();
        expected.clear();
        r_wait = false;
    }

    // 驱动一拍；返回本拍是否接收了 fetch，以及是否消费了响应。
    struct StepResult { bool accepted; bool responded; uint32_t inst; };

    StepResult step(bool fetch_valid, uint32_t pc, bool resp_ready, bool flush = false) {
        dut->fetch_valid = fetch_valid;
        dut->fetch_pc = pc;
        dut->fetch_resp_ready = resp_ready;
        dut->flush = flush;
        eval_inputs();

        StepResult r{false, false, 0};

        if (flush) {
            expected.clear();
        } else if (dut->fetch_resp_valid) {
            uint32_t got_pc = (uint32_t)dut->fetch_resp_pc;
            uint32_t got_inst = (uint32_t)dut->fetch_inst;
            ++checked;
            if (expected.empty()) {
                report("response", "unexpected response", got_pc, got_pc, 0);
            } else {
                uint32_t want_pc = expected.front();
                uint32_t want_inst = mem_word(want_pc);
                if (got_pc != want_pc || got_inst != want_inst) {
                    report("response", "pc/inst mismatch", want_pc, got_pc, want_pc);
                    if (got_inst != want_inst) {
                        report("response", "inst mismatch", want_pc, got_inst, want_inst);
                    }
                }
                if (resp_ready) {
                    expected.pop_front();
                    r.responded = true;
                    r.inst = got_inst;
                    ++responses;
                }
            }
        }

        bool will_accept = !flush && fetch_valid && dut->fetch_ready;
        tick();
        if (will_accept) {
            expected.push_back(pc);
            ++accepts;
            r.accepted = true;
        }
        return r;
    }

    // 取一条指令：保持 fetch 直到接收，然后等待响应被消费。
    bool fetch_one(uint32_t pc, uint32_t* inst_out, int max_cycles = 1000) {
        bool accepted = false;
        for (int i = 0; i < max_cycles; ++i) {
            StepResult r = step(!accepted, pc, true);
            if (r.accepted) accepted = true;
            if (r.responded) {
                if (inst_out) *inst_out = r.inst;
                return true;
            }
        }
        report("fetch_one", "timeout", pc, 0, 0);
        return false;
    }

    // 发一个请求直到被接收；ready 决定是否同时消费响应。
    bool issue(uint32_t pc, bool resp_ready, int max_cycles = 100) {
        for (int i = 0; i < max_cycles; ++i) {
            StepResult r = step(true, pc, resp_ready);
            if (r.accepted) return true;
        }
        report("issue", "timeout", pc, 0, 1);
        return false;
    }

    // 把 expected 中剩余响应排空（ready=1，不再发新请求）。
    bool drain(int max_cycles = 1000) {
        for (int i = 0; i < max_cycles; ++i) {
            if (expected.empty() && !dut->fetch_resp_valid) {
                // 还要让可能在等回填的请求完成
                step(false, 0, true);
                if (expected.empty() && !dut->fetch_resp_valid) return true;
            } else {
                step(false, 0, true);
            }
        }
        return expected.empty();
    }
};

bool run_directed(Harness& h) {
    bool ok = true;
    h.reset();
    h.fixed_refill_latency = 1;

    const uint32_t a = 0x00001000u;
    const uint32_t b = 0x00001004u;
    const uint32_t c = 0x00002000u;

    // 冷缺失 + 回填 + 命中
    uint32_t inst = 0;
    ok &= h.fetch_one(a, &inst);
    if (inst != mem_word(a)) {
        h.report("directed", "cold refill data", a, inst, mem_word(a));
        ok = false;
    }
    long refills0 = h.refills;
    ok &= h.fetch_one(a, &inst);
    if (inst != mem_word(a)) {
        h.report("directed", "hit data", a, inst, mem_word(a));
        ok = false;
    }
    if (h.refills != refills0) {
        h.report("directed", "unexpected refill on hit", a, (uint32_t)h.refills, (uint32_t)refills0);
        ok = false;
    }

    // 同索引不同 tag：B 与 A 同 4B 行索引；先填 B，再访问 A 应缺失。
    ok &= h.fetch_one(b, &inst);
    ok &= h.fetch_one(c, &inst);
    long refills1 = h.refills;
    ok &= h.fetch_one(a, &inst);
    if (h.refills == refills1) {
        h.report("directed", "expected miss after alias eviction", a, (uint32_t)h.refills, (uint32_t)(refills1 + 1));
        ok = false;
    }

    // 反压：命中响应必须保持
    ok &= h.fetch_one(a, &inst);
    if (!h.issue(a, false)) {
        ok = false;
    }
    bool held = false;
    uint32_t held_pc = 0, held_inst = 0;
    for (int i = 0; i < 8; ++i) {
        h.step(false, a, false);
        h.eval_inputs();
        if (h.dut->fetch_resp_valid) {
            held = true;
            held_pc = (uint32_t)h.dut->fetch_resp_pc;
            held_inst = (uint32_t)h.dut->fetch_inst;
            break;
        }
    }
    if (!held) {
        h.report("backpressure", "no response to hold", a, 0, 1);
        ok = false;
    } else {
        for (int i = 0; i < 3; ++i) {
            h.step(false, a, false);
            h.eval_inputs();
            if (!h.dut->fetch_resp_valid ||
                (uint32_t)h.dut->fetch_resp_pc != held_pc ||
                (uint32_t)h.dut->fetch_inst != held_inst) {
                h.report("backpressure", "response not stable", held_pc,
                         (uint32_t)h.dut->fetch_inst, held_inst);
                ok = false;
            }
        }
        Harness::StepResult r = h.step(false, a, true);
        if (!r.responded) {
            h.report("backpressure", "response lost after ready", held_pc, 0, 1);
            ok = false;
        }
    }

    // 连续命中吞吐：预填 8 条连续 PC，然后每拍发一条。
    std::vector<uint32_t> seq;
    for (uint32_t i = 0; i < 8; ++i) seq.push_back(0x00003000u + 4u * i);
    for (uint32_t pc : seq) {
        ok &= h.fetch_one(pc, &inst);
    }
    long resp0 = h.responses;
    long cycles = 0;
    size_t next_pc = 0;
    while (h.responses - resp0 < (long)seq.size() && cycles < 500) {
        bool fv = next_pc < seq.size();
        Harness::StepResult r = h.step(fv, fv ? seq[next_pc] : 0, true, false);
        if (r.accepted) ++next_pc;
        ++cycles;
    }
    if (h.responses - resp0 != (long)seq.size()) {
        h.report("throughput", "not all responses returned", 0,
                 (uint32_t)(h.responses - resp0), (uint32_t)seq.size());
        ok = false;
    }
    if (cycles > (long)seq.size() + 4) {
        h.report("throughput", "hit throughput too low", 0, (uint32_t)cycles,
                 (uint32_t)(seq.size() + 4));
        ok = false;
    }
    printf("hit throughput: %zu instructions in %ld cycles\n", seq.size(), cycles);

    // flush 冲刷 lookup：先发 A，下一拍 flush，之后不应有 A 的响应。
    bool lookup_acc = h.issue(a, true);
    h.step(false, a, true, true);   // flush 当拍
    h.step(false, 0, true, false);
    h.eval_inputs();
    if (h.dut->fetch_resp_valid) {
        h.report("flush", "stale response after lookup flush", a,
                 (uint32_t)h.dut->fetch_resp_pc, 0);
        ok = false;
    }
    if (!lookup_acc) {
        h.report("flush", "lookup was not accepted", a, 0, 1);
        ok = false;
    }

    // flush 冲刷回填：未命中后 flush，旧响应必须丢弃；再次访问应重新 refill。
    const uint32_t d = 0x00004000u;
    if (!h.issue(d, true)) ok = false;
    long refills2 = h.refills;
    // 等到 refill_valid（最多 10 拍）
    bool saw_refill = false;
    for (int i = 0; i < 10 && !saw_refill; ++i) {
        h.eval_inputs();
        if (h.dut->refill_valid) saw_refill = true;
        else h.step(false, d, true);
    }
    if (!saw_refill) {
        h.report("flush", "no refill for uncached PC", d, 0, 1);
        ok = false;
    } else {
        h.step(false, d, true, true);   // flush 进入 DRAIN
        // 回填驱动会继续等待并最终响应；DUT 应丢弃。
        for (int i = 0; i < 10; ++i) h.step(false, d, true);
        h.eval_inputs();
        if (h.dut->fetch_resp_valid) {
            h.report("flush", "stale response after refill flush", d,
                     (uint32_t)h.dut->fetch_resp_pc, 0);
            ok = false;
        }
        ok &= h.fetch_one(d, &inst);
        if (inst != mem_word(d)) {
            h.report("flush", "data after refill flush", d, inst, mem_word(d));
            ok = false;
        }
        if (h.refills <= refills2) {
            h.report("flush", "no second refill after flush", d,
                     (uint32_t)h.refills, (uint32_t)(refills2 + 1));
            ok = false;
        }
    }

    // flush 输出缓冲：命中响应 ready=0 时 flush，之后再取应重新命中。
    ok &= h.fetch_one(a, &inst);
    if (!h.issue(a, false)) ok = false;
    for (int i = 0; i < 8; ++i) {
        h.step(false, a, false);
        h.eval_inputs();
        if (h.dut->fetch_resp_valid) break;
    }
    h.step(false, a, true, true);   // flush 输出缓冲
    h.step(false, 0, true, false);
    h.eval_inputs();
    if (h.dut->fetch_resp_valid) {
        h.report("flush", "stale response after buffer flush", a,
                 (uint32_t)h.dut->fetch_resp_pc, 0);
        ok = false;
    }
    ok &= h.fetch_one(a, &inst);
    if (inst != mem_word(a)) {
        h.report("flush", "hit data after buffer flush", a, inst, mem_word(a));
        ok = false;
    }

    return ok;
}

void run_random(Harness& h, long iters) {
    h.reset();
    h.random_refill_latency = true;

    uint32_t pool[24];
    for (uint32_t& pc : pool) pc = (next_rand() & 0x3ffu) << 2;  // 1 KiB 范围

    for (long i = 0; i < iters; ++i) {
        uint32_t r = next_rand();
        bool fv = (r & 3u) != 0;
        bool ready = ((r >> 3) & 7u) != 0;
        bool flush = ((r >> 6) & 127u) == 0;
        uint32_t pc = ((r & 8u) != 0) ? (next_rand() & 0xffcu) : pool[next_rand() % 24];
        h.step(fv, pc, ready, flush);
    }

    // 排空随机测试留下的请求。
    for (int i = 0; i < 2000 && !h.expected.empty(); ++i) {
        h.step(false, 0, true, false);
    }
    if (!h.expected.empty()) {
        h.report("random", "drain timeout", 0, (uint32_t)h.expected.size(), 0);
    }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    long random_iters = 100000;
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

    Vicache_pipe dut;
    Harness h;
    h.dut = &dut;

    run_directed(h);
    run_random(h, random_iters);

    printf("icache_pipe_tb: checked=%ld fails=%ld accepts=%ld responses=%ld refills=%ld\n",
           h.checked, h.fails, h.accepts, h.responses, h.refills);
    if (h.fails != 0) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
