// -----------------------------------------------------------------------------
// frontend_tb.cpp — frontend_ooo + rename + rob + stub_exec 子系统冒烟测试
//
// 指令内存由 C++ 提供：收到 refill_valid 后一拍返回 mem_word(addr)。
// 覆盖：
//   1. 直线程序：取指/译码/rename/ROB/提交顺序；
//   2. force_stall 反压后恢复；
//   3. 条件分支误预测：stub 发 br_update，ROB redirect，前端从目标继续取指。
// -----------------------------------------------------------------------------

#include "Vfrontend_subsystem.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

uint32_t rng_state = 0x20261018u;

uint32_t program[64];
int      program_words = 0;

uint32_t mem_word(uint32_t addr) {
    uint32_t idx = (addr >> 2);
    if (idx < (uint32_t)program_words) return program[idx];
    return 0x00000013u;  // NOP
}

struct Harness {
    Vfrontend_subsystem* dut = nullptr;
    bool     r_wait = false;
    uint32_t r_addr = 0;
    int      r_count = 0;
    bool     r_drive = false;
    long     cycles = 0;
    long     fails = 0;

    void report(const char* why, uint32_t got, uint32_t want) {
        ++fails;
        if (fails <= 20)
            printf("FAIL [%s] got=%08x want=%08x pc=%08x\n",
                   why, got, want, (uint32_t)dut->frontend_pc);
    }

    void tick() {
        dut->clk = 0;
        dut->eval();

        r_drive = false;
        if (!r_wait && dut->refill_valid) {
            r_wait = true;
            r_addr = (uint32_t)dut->refill_addr;
            r_count = 1;
        }
        if (r_wait) {
            if (!dut->refill_valid || (uint32_t)dut->refill_addr != r_addr) {
                report("refill unstable", (uint32_t)dut->refill_addr, r_addr);
            }
            if (r_count == 0) {
                r_drive = true;
                dut->refill_resp_valid = 1;
                dut->refill_rdata = mem_word(r_addr);
            } else {
                --r_count;
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
        ++cycles;
        if (r_drive) r_wait = false;
    }

    void reset() {
        dut->reset = 1;
        dut->force_stall = 0;
        dut->force_taken = 0;
        dut->force_target = 0;
        dut->refill_resp_valid = 0;
        dut->refill_rdata = 0;
        r_wait = false;
        for (int i = 0; i < 3; ++i) tick();
        dut->reset = 0;
        tick();
        cycles = 0;
    }

    // 返回本拍提交的 pc/inst；无提交时 pc=0xffffffff。
    bool sample_commit(uint32_t* pc, uint32_t* inst) {
        if ((uint32_t)dut->commit_valid & 1u) {
            *pc = (uint32_t)dut->commit_pc;
            *inst = (uint32_t)dut->commit_inst;
            return true;
        }
        return false;
    }
};

void setup_straight() {
    const uint32_t prog[] = {
        0x00000013u,  // nop
        0x00100093u,  // addi x1,x0,1
        0x00200113u,  // addi x2,x0,2
        0x002081b3u,  // add x3,x1,x2
        0x00302023u,  // sw x3,0(x0)
        0x00000013u,  // nop
        0x00000013u,  // nop
        0x00000013u,  // nop
    };
    program_words = (int)(sizeof(prog) / sizeof(prog[0]));
    for (int i = 0; i < program_words; ++i) program[i] = prog[i];
}

void setup_branch() {
    const uint32_t prog[] = {
        0x00000013u,  // 0x00 nop
        0x00100093u,  // 0x04 addi x1,x0,1
        0x00200113u,  // 0x08 addi x2,x0,2
        0x002081b3u,  // 0x0c add x3,x1,x2
        0x00000863u,  // 0x10 beq x0,x0,+16 -> 0x20
        0x00000013u,  // 0x14 nop
        0x00000013u,  // 0x18 nop
        0x00000013u,  // 0x1c nop
        0x00400213u,  // 0x20 addi x4,x0,4
        0x00000013u,  // 0x24 nop
        0x00000013u,  // 0x28 nop
        0x00000013u,  // 0x2c nop
    };
    program_words = (int)(sizeof(prog) / sizeof(prog[0]));
    for (int i = 0; i < program_words; ++i) program[i] = prog[i];
}

bool test_straight() {
    Vfrontend_subsystem dut;
    Harness h;
    h.dut = &dut;
    setup_straight();
    h.reset();

    // 反压一段时间，确认之后能恢复
    dut.force_stall = 1;
    for (int i = 0; i < 10; ++i) h.tick();
    dut.force_stall = 0;

    int got = 0;
    for (int cyc = 0; cyc < 500 && got < 8; ++cyc) {
        uint32_t pc = 0, inst = 0;
        if (h.sample_commit(&pc, &inst)) {
            uint32_t want_pc = (uint32_t)got * 4u;
            uint32_t want_inst = mem_word(want_pc);
            if (pc != want_pc) h.report("commit pc", pc, want_pc);
            if (inst != want_inst) h.report("commit inst", inst, want_inst);
            ++got;
        }
        if (dut.commit_halt) {
            h.report("unexpected halt", 1, 0);
            break;
        }
        h.tick();
    }
    if (got < 8) h.report("straight timeout", (uint32_t)got, 8);
    printf("straight: commits=%d cycles=%ld fails=%ld\n", got, h.cycles, h.fails);
    return h.fails == 0;
}

bool test_branch() {
    Vfrontend_subsystem dut;
    Harness h;
    h.dut = &dut;
    setup_branch();
    h.reset();

    dut.force_taken = 1;
    dut.force_target = 0x20;

    bool saw_redirect = false;
    uint32_t redirect_pc = 0;
    bool saw_target_commit = false;
    bool saw_branch_commit = false;

    for (int cyc = 0; cyc < 1000; ++cyc) {
        if ((uint32_t)dut.redirect_valid) {
            saw_redirect = true;
            redirect_pc = (uint32_t)dut.redirect_pc;
        }
        uint32_t pc = 0, inst = 0;
        if (h.sample_commit(&pc, &inst)) {
            if (pc == 0x10) saw_branch_commit = true;
            if (pc == 0x20 && inst == mem_word(0x20)) saw_target_commit = true;
        }
        if (saw_target_commit && saw_redirect) break;
        h.tick();
    }

    if (!saw_branch_commit) h.report("branch not committed", 0, 1);
    if (!saw_redirect) h.report("no redirect", 0, 1);
    if (redirect_pc != 0x20) h.report("redirect pc", redirect_pc, 0x20);
    if (!saw_target_commit) h.report("target not committed", 0, 0x20);

    printf("branch: redirect=%d pc=%08x branch_commit=%d target_commit=%d cycles=%ld fails=%ld\n",
           (int)saw_redirect, redirect_pc, (int)saw_branch_commit,
           (int)saw_target_commit, h.cycles, h.fails);
    return h.fails == 0;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    (void)rng_state;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--seed") && i + 1 < argc)
            rng_state = (uint32_t)strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--quick")) {
            // 本测试没有长随机，保留参数兼容
        } else {
            printf("usage: %s [--quick] [--seed N]\n", argv[0]);
            return 2;
        }
    }

    bool ok = test_straight();
    ok &= test_branch();

    if (!ok) {
        printf("frontend_tb: FAIL\n");
        return 1;
    }
    printf("frontend_tb: PASS\n");
    return 0;
}
