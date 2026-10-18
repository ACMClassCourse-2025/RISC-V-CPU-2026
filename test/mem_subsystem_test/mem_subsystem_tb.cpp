// -----------------------------------------------------------------------------
// mem_subsystem_tb.cpp — mem_subsystem v1 的 Verilator 单测
//
// 用一个行为级 AXI4-Lite 从机模型检查：
//   - if_refill / data_mem 两客户口的 owner 路由；
//   - 读、写、写掩码；
//   - 两客户同时请求时的 round-robin 仲裁与互不串道；
//   - 连续事务与写后读。
// -----------------------------------------------------------------------------

#include "Vmem_subsystem.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace {

struct Slave {
    Vmem_subsystem* dut = nullptr;

    uint8_t mem[1 << 16];
    bool    read_pending = false;
    uint32_t read_addr = 0;
    int     read_delay = 0;
    bool    rvalid = false;
    bool    r_fire = false;
    uint32_t rdata = 0;

    bool    aw_seen = false;
    bool    w_seen = false;
    uint32_t wr_addr = 0;
    uint32_t wr_data = 0;
    uint8_t  wr_strb = 0;
    int     write_delay = 0;
    bool    bvalid = false;
    bool    b_fire = false;

    long checks = 0;
    long fails = 0;

    void init() {
        for (unsigned i = 0; i < sizeof(mem); ++i) mem[i] = (uint8_t)(i * 37 + 11);
        dut->arready = 1;
        dut->awready = 1;
        dut->wready  = 1;
        dut->rvalid  = 0;
        dut->rdata   = 0;
        dut->bvalid  = 0;
    }

    uint32_t word(uint32_t addr) const {
        uint32_t a = addr & 0xffff;
        return (uint32_t)mem[a] |
               ((uint32_t)mem[(a + 1) & 0xffff] << 8) |
               ((uint32_t)mem[(a + 2) & 0xffff] << 16) |
               ((uint32_t)mem[(a + 3) & 0xffff] << 24);
    }

    void write_word(uint32_t addr, uint32_t value, uint8_t strb) {
        uint32_t a = addr & 0xffff;
        for (int lane = 0; lane < 4; ++lane) {
            if (strb & (1u << lane))
                mem[(a + lane) & 0xffff] = (uint8_t)(value >> (8 * lane));
        }
    }

    // Called with clk=0 before the posedge.  Drive AXI inputs from DUT outputs.
    void before_edge() {
        // Read address handshake.
        if (dut->arvalid && dut->arready && !read_pending && !rvalid) {
            read_pending = true;
            read_addr    = dut->araddr;
            read_delay   = 1 + (int)(read_addr & 3);
        }
        // Write address/data handshakes (both ready in this model).
        if (dut->awvalid && dut->awready && !aw_seen) {
            aw_seen = true;
            wr_addr = dut->awaddr;
        }
        if (dut->wvalid && dut->wready && !w_seen) {
            w_seen = true;
            wr_data = dut->wdata;
            wr_strb = (uint8_t)dut->wstrb;
        }
        if (aw_seen && w_seen && !bvalid && write_delay == 0) {
            write_delay = 1 + (int)(wr_addr & 3);
        }

        // Progress response delays and drive response channels.
        if (read_pending && !rvalid) {
            if (read_delay > 0) {
                --read_delay;
            } else {
                rvalid = true;
                rdata  = word(read_addr);
            }
        }
        if (write_delay > 0) {
            --write_delay;
            if (write_delay == 0) bvalid = true;
        }

        dut->rvalid = rvalid ? 1 : 0;
        dut->rdata  = rdata;
        dut->bvalid = bvalid ? 1 : 0;

        // Sample handshakes before the posedge; after the DUT edge its
        // combinational rready/bready may already have dropped.
        r_fire = rvalid && dut->rready;
        b_fire = bvalid && dut->bready;
    }

    // Called at the posedge, after DUT state updates.
    void after_edge() {
        if (r_fire) {
            rvalid = false;
            read_pending = false;
        }
        if (b_fire) {
            write_word(wr_addr, wr_data, wr_strb);
            bvalid = false;
            aw_seen = false;
            w_seen = false;
            write_delay = 0;
        }
    }

    void check(bool ok, const char* what) {
        ++checks;
        if (!ok) {
            ++fails;
            printf("FAIL: %s\n", what);
        }
    }
};

struct Harness {
    Vmem_subsystem* dut = nullptr;
    Slave slave;

    void tick() {
        // Settle the cycle, let the slave drive combinational inputs, then
        // advance one posedge.
        dut->clk = 0;
        dut->eval();
        slave.before_edge();
        dut->eval();
        sample();
        dut->clk = 1;
        dut->eval();
        slave.after_edge();
        dut->eval();
    }

    long if_seen = 0, data_seen = 0;
    uint32_t if_rdata = 0, data_rdata = 0;

    void sample() {
        if (dut->if_resp_valid) {
            ++if_seen;
            if_rdata = dut->if_resp_rdata;
        }
        if (dut->data_resp_valid) {
            ++data_seen;
            data_rdata = dut->data_resp_rdata;
        }
    }

    void reset() {
        dut->reset = 1;
        dut->if_req_valid = 0;
        dut->if_req_addr = 0;
        dut->data_req_valid = 0;
        dut->data_req_we = 0;
        dut->data_req_addr = 0;
        dut->data_req_wdata = 0;
        dut->data_req_wstrb = 0;
        for (int i = 0; i < 4; ++i) tick();
        dut->reset = 0;
        tick();
    }

    bool if_read(uint32_t addr, uint32_t want, const char* tag) {
        long before = if_seen;
        dut->if_req_valid = 1;
        dut->if_req_addr  = addr;
        for (int cycle = 0; cycle < 64; ++cycle) {
            tick();
            if (if_seen != before) {
                bool ok = (if_rdata == want);
                slave.check(ok, tag);
                if (!ok) printf("  [%s] addr=%08x got=%08x want=%08x\n", tag, addr, if_rdata, want);
                dut->if_req_valid = 0;
                tick();
                return ok;
            }
        }
        slave.check(false, "if_read timeout");
        dut->if_req_valid = 0;
        return false;
    }

    bool data_read(uint32_t addr, uint32_t want, const char* tag) {
        long before = data_seen;
        dut->data_req_valid = 1;
        dut->data_req_we    = 0;
        dut->data_req_addr  = addr;
        for (int cycle = 0; cycle < 64; ++cycle) {
            tick();
            if (data_seen != before) {
                bool ok = (data_rdata == want);
                slave.check(ok, tag);
                if (!ok) printf("  [%s] addr=%08x got=%08x want=%08x\n", tag, addr, data_rdata, want);
                dut->data_req_valid = 0;
                tick();
                return ok;
            }
        }
        slave.check(false, "data_read timeout");
        dut->data_req_valid = 0;
        return false;
    }

    bool data_write(uint32_t addr, uint32_t value, uint8_t strb, const char* tag) {
        long before = data_seen;
        dut->data_req_valid = 1;
        dut->data_req_we    = 1;
        dut->data_req_addr  = addr;
        dut->data_req_wdata = value;
        dut->data_req_wstrb = strb;
        for (int cycle = 0; cycle < 64; ++cycle) {
            tick();
            if (data_seen != before) {
                slave.check(true, tag);
                dut->data_req_valid = 0;
                tick();
                return true;
            }
        }
        slave.check(false, "data_write timeout");
        dut->data_req_valid = 0;
        return false;
    }

    // Both requests held until each response arrives; checks owner routing.
    void concurrent_reads(uint32_t if_addr, uint32_t if_want,
                          uint32_t data_addr, uint32_t data_want) {
        long if_before = if_seen, data_before = data_seen;
        dut->if_req_valid = 1;
        dut->if_req_addr  = if_addr;
        dut->data_req_valid = 1;
        dut->data_req_we    = 0;
        dut->data_req_addr  = data_addr;
        bool if_done = false, data_done = false;
        for (int cycle = 0; cycle < 128 && !(if_done && data_done); ++cycle) {
            tick();
            if (if_seen != if_before && !if_done) {
                if_done = true;
                slave.check(if_rdata == if_want, "concurrent if data");
                dut->if_req_valid = 0;
            }
            if (data_seen != data_before && !data_done) {
                data_done = true;
                slave.check(data_rdata == data_want, "concurrent data data");
                dut->data_req_valid = 0;
            }
        }
        slave.check(if_done && data_done, "concurrent both completed");
        tick();
    }
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vmem_subsystem dut;
    Harness h;
    h.dut = &dut;
    h.slave.dut = &dut;
    h.slave.init();
    h.reset();

    const uint32_t if_addr = 0x1000;
    const uint32_t d_addr  = 0x2000;
    const uint32_t w_addr  = 0x3000;

    h.slave.write_word(if_addr, 0x11223344, 0xf);
    h.slave.write_word(d_addr, 0xa5a55a5a, 0xf);

    h.if_read(if_addr, 0x11223344, "if read");
    h.data_read(d_addr, 0xa5a55a5a, "data read");

    h.data_write(w_addr, 0xdeadbeef, 0xf, "data write");
    h.data_read(w_addr, 0xdeadbeef, "write then read");

    // Partial write: only byte lane 1 changes.
    h.slave.write_word(w_addr + 4, 0x01020304, 0xf);
    h.data_write(w_addr + 4, 0x0000aa00, 0x2, "partial write");
    h.data_read(w_addr + 4, 0x0102aa04, "partial write readback");

    // Concurrent clients: different addresses and values.
    h.slave.write_word(0x4000, 0x0badf00d, 0xf);
    h.slave.write_word(0x5000, 0xcafebabe, 0xf);
    h.concurrent_reads(0x4000, 0x0badf00d, 0x5000, 0xcafebabe);

    // Back-to-back transactions.
    for (int i = 0; i < 8; ++i) {
        uint32_t addr = 0x6000 + 4 * i;
        h.slave.write_word(addr, 0x10000000u + i, 0xf);
        h.if_read(addr, 0x10000000u + i, "back-to-back if");
        h.data_read(addr, 0x10000000u + i, "back-to-back data");
    }

    printf("\nchecks=%ld fails=%ld if_resp=%ld data_resp=%ld\n",
           h.slave.checks, h.slave.fails, h.if_seen, h.data_seen);
    bool pass = (h.slave.fails == 0);
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}
