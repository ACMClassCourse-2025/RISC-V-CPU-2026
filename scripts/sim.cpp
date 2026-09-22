// Simulation-only RAM and AXI4-Lite slave. The DUT needs no debug ports.
#include "Vstudent_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdint>
#include <deque>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

constexpr uint32_t EXIT_ADDRESS = 0x80000000;
constexpr size_t DEPTH = 16;
constexpr unsigned BUS_BYTES = 4;
constexpr size_t RAM_BYTES = 256 * 1024 * 1024;

struct Memory {
    struct Data { uint32_t data; uint32_t strobe; };
    struct Read { uint32_t data; uint32_t response; uint64_t due; };
    struct Write { uint32_t response, result; uint64_t due; bool exit; };
    std::vector<uint8_t> bytes = std::vector<uint8_t>(RAM_BYTES);
    std::deque<uint32_t> ar, aw;
    std::deque<Data> w;
    std::deque<Read> r;
    std::deque<Write> b;
    uint64_t cycle = 0;
    uint32_t random = 1, result = 0;
    bool done = false;

    void load(const std::string &path) {
        std::ifstream file(path, std::ios::binary);
        if (!file) throw std::runtime_error("cannot open image: " + path);
        if (path.size() >= 4 && path.substr(path.size() - 4) == ".bin") {
            file.read(reinterpret_cast<char *>(bytes.data()), bytes.size());
            if (file.peek() != std::char_traits<char>::eof())
                throw std::runtime_error("image exceeds 256 MiB RAM");
            return;
        }
        load_text(file);
    }

    void load_text(std::istream &file) {
        uint64_t address = 0;
        std::string line, token;
        while (std::getline(file, line)) {
            auto comment = line.find("//");
            if (comment != std::string::npos) line.resize(comment);
            comment = line.find('#');
            if (comment != std::string::npos) line.resize(comment);
            std::istringstream words(line);
            while (words >> token) {
                bool location = token[0] == '@';
                std::string digits = location ? token.substr(1) : token;
                if (digits.empty() || digits.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos)
                    throw std::runtime_error("invalid image token: " + token);
                uint64_t value = std::stoull(digits, nullptr, 16);
                if (location) {
                    if (value >= bytes.size()) throw std::runtime_error("image address out of range");
                    address = value;
                } else {
                    if (value > 255 || address >= bytes.size())
                        throw std::runtime_error("image byte/address out of range");
                    bytes[address++] = uint8_t(value);
                }
            }
        }
    }

    uint32_t response(uint32_t address) const {
        if (address & (BUS_BYTES - 1)) return 2; // SLVERR
        return uint64_t(address) + BUS_BYTES > bytes.size() ? 3 : 0; // DECERR / OKAY
    }

    void read(unsigned latency) {
        uint32_t address = ar.front(), status = response(address);
        uint32_t data = 0;
        ar.pop_front();
        if (!status)
            for (unsigned i = 0; i < BUS_BYTES; ++i) data |= uint32_t(bytes[address + i]) << (8 * i);
        r.push_back({data, status, cycle + latency});
    }

    void write(unsigned latency) {
        uint32_t address = aw.front();
        Data data = w.front();
        aw.pop_front();
        w.pop_front();
        // RV32 exits with a word store covering all four byte lanes.
        bool exit = address == EXIT_ADDRESS && data.strobe == 0x0f;
        uint32_t status = address == EXIT_ADDRESS ? (exit ? 0 : 2) : response(address);
        if (!status && !exit)
            for (unsigned i = 0; i < BUS_BYTES; ++i)
                if (data.strobe & (1u << i)) bytes[address + i] = uint8_t(data.data >> (8 * i));
        b.push_back({status, uint32_t(data.data), cycle + latency, exit});
    }

    void drive(Vstudent_top &top) const {
        top.arready = !top.reset && ar.size() < DEPTH;
        top.awready = !top.reset && aw.size() < DEPTH;
        top.wready = !top.reset && w.size() < DEPTH;
        top.rvalid = !top.reset && !r.empty() && r.front().due <= cycle;
        top.rdata = r.empty() ? 0 : r.front().data;
        top.rresp = r.empty() ? 0 : r.front().response;
        top.bvalid = !top.reset && !b.empty() && b.front().due <= cycle;
        top.bresp = b.empty() ? 0 : b.front().response;
    }

    // Called once per rising edge with settled, pre-edge pin values.
    void step(const Vstudent_top &top, unsigned latency) {
        if (top.reset) {
            ar.clear(); aw.clear(); w.clear(); r.clear(); b.clear();
            cycle = 0; random = 1; done = false; result = 0;
            return;
        }
        ++cycle;
        if (top.rvalid && top.rready) r.pop_front();
        if (top.bvalid && top.bready) {
            if (b.front().exit) { done = true; result = b.front().result; }
            b.pop_front();
        }
        bool do_read = !ar.empty() && r.size() < DEPTH;
        bool do_write = !aw.empty() && !w.empty() && b.size() < DEPTH;
        bool write_first = false;
        if (do_read && do_write) {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5;
            write_first = random & 1;
        }
        if (do_write && write_first) write(latency);
        if (do_read) read(latency);
        if (do_write && !write_first) write(latency);
        // Newly accepted requests become eligible on the following edge.
        if (top.arvalid && top.arready) ar.push_back(top.araddr);
        if (top.awvalid && top.awready) aw.push_back(top.awaddr);
        if (top.wvalid && top.wready) w.push_back({top.wdata, top.wstrb});
    }
};

uint64_t decimal(const std::string &text, const char *name, uint64_t maximum) {
    if (text.empty() || text.find_first_not_of("0123456789") != std::string::npos)
        throw std::runtime_error(std::string("invalid ") + name);
    uint64_t value = std::stoull(text);
    if (value > maximum) throw std::runtime_error(std::string(name) + " out of range");
    return value;
}

int main(int argc, char **argv) {
    const bool oj = argc == 1;
    if (!oj && argc != 5 && argc != 6) {
        std::cerr << "usage: sim IMAGE EXPECTED MAX_CYCLES LATENCY [WAVE]\n"
                  << "       code < TEST.in  (OJ mode, no arguments)\n";
        return 2;
    }
    try {
        uint32_t expected = 0;
        std::string limit_text, latency_text;
        if (oj) {
            std::string magic, version;
            if (!(std::cin >> magic >> version >> limit_text >> latency_text)
                || magic != "CPU2026-OJ" || version != "1")
                throw std::runtime_error("expected CPU2026-OJ 1 header, cycle limit and latency");
        } else {
            expected = uint32_t(decimal(argv[2], "expected result", 0xffffffff));
            limit_text = argv[3];
            latency_text = argv[4];
        }
        uint64_t limit = decimal(limit_text, "cycle limit", (uint64_t(1) << 63) - 1);
        unsigned latency = unsigned(decimal(latency_text, "latency", 1000000));
        if (!limit || !latency) throw std::runtime_error("cycle limit and latency must be positive");
        Memory memory;
        if (oj) memory.load_text(std::cin);
        else memory.load(argv[1]);
        VerilatedContext context;
        context.commandArgs(argc, argv);
        context.traceEverOn(argc == 6);
        Vstudent_top top{&context};
        VerilatedVcdC trace;
        if (argc == 6) {
            top.trace(&trace, 99);
            trace.open(argv[5]);
            if (!trace.isOpen()) throw std::runtime_error("cannot open waveform");
        }
        auto tick = [&]() {
            top.clock = 0;
            memory.drive(top);
            top.eval();
            if (argc == 6) trace.dump(context.time());
            context.timeInc(1);
            memory.step(top, latency);
            top.clock = 1;
            top.eval();
            if (argc == 6) trace.dump(context.time());
            context.timeInc(1);
        };
        top.reset = 1;
        for (unsigned i = 0; i < 5; ++i) tick();
        top.reset = 0;
        while (!memory.done && memory.cycle < limit && !context.gotFinish()) tick();
        top.final();
        if (argc == 6) trace.close();
        if (oj) {
            if (!memory.done) {
                std::cerr << "FAIL: timeout or finish before exit write response; cycles="
                          << memory.cycle << '\n';
                return 1;
            }
            std::cout << memory.result << '\n';
            std::cerr << "CPU2026 cycles=" << memory.cycle << '\n';
            return 0;
        }
        bool pass = memory.done && memory.result == expected;
        std::cout << (pass ? "PASS" : "FAIL") << " cycles=" << memory.cycle;
        if (memory.done) std::cout << " result=" << memory.result << " expected=" << expected;
        else std::cout << " (timeout or finish before exit write response)";
        std::cout << '\n';
        return pass ? 0 : 1;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
