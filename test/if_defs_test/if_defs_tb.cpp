// -----------------------------------------------------------------------------
// if_defs_tb.cpp — 校验 if_defs.sv 的派生宽度与字段偏移
//
// 默认配置应与 docs/interface.md 的总览表一致：
//   dispatch=150, cdb=40, complete=8, commit=12, br_update=73,
//   squash=6, if_refill=33/33, data_mem=70/33。
// 通过环境变量（由 run.sh 透传 -D）可检查 W/PRF/CDB/ROB/LSQ 的参数化。
// -----------------------------------------------------------------------------

#include "Vif_defs_check.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>

#ifndef TB_W
#define TB_W 1
#endif
#ifndef TB_PRF
#define TB_PRF 64
#endif
#ifndef TB_CDB
#define TB_CDB 1
#endif
#ifndef TB_ROB
#define TB_ROB 32
#endif
#ifndef TB_LSQ
#define TB_LSQ 8
#endif

namespace {

constexpr uint32_t clog2(uint32_t v) {
    uint32_t n = 0;
    uint32_t x = (v <= 1) ? 0 : (v - 1);
    while (x != 0) { ++n; x >>= 1; }
    return n;
}

struct Expect {
    const char* name;
    uint32_t got;
    uint32_t want;
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vif_defs_check dut;
    dut.eval();

    constexpr uint32_t W = TB_W;
    constexpr uint32_t P = clog2(TB_PRF);
    constexpr uint32_t L = clog2(TB_LSQ);
    constexpr uint32_t R = clog2(TB_ROB);
    constexpr uint32_t dispatch_w = 124 + 3 * P + L + R;

    const Expect checks[] = {
        {"dispatch_w",             (uint32_t)dut.dispatch_w,             dispatch_w},
        {"dispatch_bus_w",         (uint32_t)dut.dispatch_bus_w,         dispatch_w * W},
        {"dispatch_lane1",         (uint32_t)dut.dispatch_lane1,         dispatch_w},
        {"dispatch_src2_tag_off",  (uint32_t)dut.dispatch_src2_tag_off,  123 + 2 * P},
        {"dispatch_lsq_id_off",    (uint32_t)dut.dispatch_lsq_id_off,    124 + 3 * P},
        {"dispatch_rob_idx_off",   (uint32_t)dut.dispatch_rob_idx_off,   124 + 3 * P + L},
        {"cdb_w",                  (uint32_t)dut.cdb_w,                  34 + P},
        {"cdb_bus_w",              (uint32_t)dut.cdb_bus_w,              (34 + P) * TB_CDB},
        {"cdb_value_off",          (uint32_t)dut.cdb_value_off,          1 + P},
        {"complete_w",             (uint32_t)dut.complete_w,             2 + P},
        {"complete_exception_off", (uint32_t)dut.complete_exception_off, 1 + P},
        {"commit_w",               (uint32_t)dut.commit_w,               3 + P + L},
        {"commit_lsq_id_off",      (uint32_t)dut.commit_lsq_id_off,      3 + P},
        {"br_update_w",            (uint32_t)dut.br_update_w,            67 + P},
        {"br_tag_off",             (uint32_t)dut.br_tag_off,             67},
        {"squash_w",               (uint32_t)dut.squash_w,               1 + R},
        {"if_req_w",               (uint32_t)dut.if_req_w,               33},
        {"if_resp_w",              (uint32_t)dut.if_resp_w,              33},
        {"data_req_w",             (uint32_t)dut.data_req_w,             70},
        {"data_resp_w",            (uint32_t)dut.data_resp_w,            33},
    };

    int fails = 0;
    for (const Expect& e : checks) {
        if (e.got != e.want) {
            printf("FAIL %s: got=%u want=%u\n", e.name, e.got, e.want);
            ++fails;
        }
    }
    printf("if_defs_tb: W=%u PRF=%u CDB=%u ROB=%u LSQ=%u checked=%zu fails=%d\n",
           W, TB_PRF, TB_CDB, TB_ROB, TB_LSQ, sizeof(checks) / sizeof(checks[0]), fails);
    if (fails != 0) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
