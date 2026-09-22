# RISC-V CPU Template

[![Target: RV32IM](https://img.shields.io/badge/target-RV32IM-283272)](https://msyksphinz-self.github.io/riscv-isadoc/)
[![Simulator: Verilator](https://img.shields.io/badge/simulator-Verilator-4B7BE5)](https://www.veripool.org/verilator/)
[![Synthesis: Yosys + ASAP7](https://img.shields.io/badge/synthesis-Yosys%20%2B%20ASAP7-f39c12)](https://yosyshq.net/yosys/)
[![Bus: AXI4--Lite](https://img.shields.io/badge/bus-AXI4--Lite-green)](docs/axi4-lite.md)

[English](README-EN.md) | [简体中文](README-ZH.md)

> Replace this with your own README when you start working on your CPU.

## Getting Started

Welcome to the RISC-V CPU Course (CPU 2026)! This repository provides the official framework and template for designing and evaluating an out-of-order execution (OoO) RISC-V processor. It includes a Verilator-based simulation harness with an AXI4-Lite memory slave, official correctness and performance testcases, Yosys + ASAP7 synthesis with OpenSTA timing analysis, and a unified test runner.

We strongly recommend that you **fork this repository** instead of downloading ZIP archives, so that you can easily synchronize updates to official testcases and framework tools. After forking, clone your copy to your local machine.

### 1. Initialize Submodules

Initialize the official testcase submodule:

```sh
git submodule update --init --recursive
```

### 2. Hardware Toolchain Setup

You have the following primary options for running Verilator simulation and Yosys/ASAP7 synthesis with OpenSTA timing analysis:

#### Option A: Course Hardware-Tool AppImage (Recommended for Linux x86-64 & WSL2)

We provide a self-contained Linux x86-64 AppImage (`cpu2026-tools-x86_64.AppImage`) bundling Verilator 5.020, Yosys, ABC, OpenSTA, and the ASAP7 7.5-track standard cell libraries.

Place `cpu2026-tools-x86_64.AppImage` into the repository root directory and grant execution permissions:

```sh
chmod +x cpu2026-tools-x86_64.AppImage
```

Make automatically uses the image at this location: `make build` uses its Verilator, and `make synth` uses its Yosys, ABC, OpenSTA, and ASAP7 libraries. Python, Make, and the C++ compiler run on the host. Make does not download or rebuild the AppImage.

#### Option B: Use Docker Container

Build the Docker image:

```sh
docker build -t cpu2026 .
```

Mount local code into the container:

```sh
docker run --rm -it -v "$PWD":/work cpu2026 bash
```

After entering the `/work` directory inside the container, all `make` commands will work properly.

#### Option C: Manually specified toolchain

Specify toolchain paths in `config.mk`:
  ```make
  APPIMAGE =
  VERILATOR = /path/to/verilator
  YOSYS = /path/to/yosys
  ABC = /path/to/yosys-abc
  STA = /path/to/sta
  ASAP7_LIB = /path/to/asap7/lib
  ```

### 3. Project Template

We also provide a [Chisel template](https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026/tree/chisel-example).


---

## Overview

You may implement your CPU in **any hardware description language** (e.g., Verilog, SystemVerilog, Chisel, Assasyn). Because our evaluation infrastructure and synthesis flow consume Verilog/SystemVerilog, designs authored in higher-level HDLs must emit Verilog files prior to simulation and submission.

### Directory Structure

```text
.
├── config.mk                   # Local overrides (tools, paths, flags)
├── Makefile                    # Unified entrypoint for build, simulation, test, and synthesis
├── docs/
│   ├── axi4-lite.md            # AXI4-Lite protocol and memory conventions
│   └── sram.md                 # SRAM interface, cost model, and supported configurations
├── verilog/
│   └── filelist.f              # List of RTL source paths (relative to verilog/)
├── testcases/                  # Official testcases (submodule)
│   ├── correctness_*           # Functional correctness tests
│   └── perf_*                  # Benchmark suites for IPC evaluation
├── scripts/                    # Build scripts and simulation harness (Do not modify)
└── packaging/                  # AppImage packaging and build scripts (You can remove it if you don't need)
```

---

## Architecture & Project Requirements

### 1. Instruction Set Architecture (RV32IM)

- **Base Integer Instructions**: Full RV32I user-level instruction set.
- **M Extension**: Complete standard multiplication and division extensions:
  `MUL`, `MULH`, `MULHSU`, `MULHU`, `DIV`, `DIVU`, `REM`, `REMU`.
- **Loads & Stores**: Full integer load and store instructions:
  `LB`, `LBU`, `LH`, `LHU`, `LW`, `SB`, `SH`, `SW`.
  - Memory accesses are naturally aligned (half-words aligned to 2 bytes, words aligned to 4 bytes). Unaligned memory accesses are not required.
- **Omitted Instructions**:
  - `CSR*` (Control and Status Register) instructions are not required.
  - `FENCE` and `FENCE.I` instructions are not required.
  - `ECALL` and `EBREAK` instructions are not required.

### 2. Microarchitecture Requirements

- **Out-of-Order (OoO) Execution**: Instructions must be dispatched/executed out of program order when operands become available.
- **In-Order Commit**: Instructions must retire in strict program order (e.g., using a Reorder Buffer / ROB).
- **Parameterization**:
  Key microarchitectural parameters should be parameterized in your design:
  - Issue width
  - Reorder Buffer (ROB) capacity
  - Physical Register File (PRF) size
  - Reservation Station / Issue Queue depth
  - Cache capacity and associativity

### 3. Termination & Output Convention

- The CPU halts and communicates its exit status by performing a **32-bit word store to MMIO address `0x80000000`** with write strobe `WSTRB = 4'b1111` (`4'hf`).
- The exit return code is placed in `WDATA[31:0]`.
- Correctness is determined by comparing the final exit result with the reference answer.

### 4. Memory Layout

- **External RAM**: 256 MiB little-endian RAM (`0x00000000`–`0x0fffffff`).

### 5. Final Report

Each team (up to 2 students) must submit a project report covering:
- **Parameter Sensitivity Analysis**: How performance (IPC) changes across different parameter configurations (e.g., varying issue width, PRF size, ROB size, cache configurations).
- **Architectural Exploration**: Key design trade-offs explored during development.

---

## Grading & Milestones

### 1. Correctness (Max 85 Points)

| Stage | Requirements | Cumulative Score |
| --- | --- | ---: |
| Basic Programs | Pass: vector multiplication, vector addition, sum 0 to 100 | 75 |
| Simulation Programs | Pass remaining CPU simulation test programs | 85 |

*Note: Passing the preceding stage is a prerequisite for earning points in the subsequent stage. The final exit result must match the reference answer.*

### 2. Performance (Max 15 Points + 4 Frequency Bonus Points)

- **Area**: Standard cell area synthesized with **Yosys + ASAP7** 7.5-track RVT TT libraries, plus estimated FakeRAM SRAM area (in $\mu m^2$). The report shows total area and its combinational, sequential, and SRAM components.
- **IPC**: Measured dynamically in Verilator as $\frac{\text{Dynamic Instructions}}{\text{Simulation Cycles}}$. Overall IPC is calculated as the **geometric mean (GEOMEAN)** across all benchmark testcases under `testcases/perf_*`.

| Tier   | Maximum Area ($\mu m^2$) | Minimum IPC (Geomean) | Minimum frequency (MHz) | Cumulative Score |
|--------|--------------------------|-----------------------|-------------------------|------------------|
| Tier 1 | 9,000                    | 0.6000                | 300                     | 90               |
| Tier 2 | 18,000                   | 0.8450                | 300                     | 95               |
| Tier 3 | 36,000                   | 1.0985                | 300                     | 100              |

**Frequency Bonus**: After meeting a tier's area, IPC, and 300 MHz minimum frequency requirements, add the following bonus to that tier's cumulative score.

| Minimum Frequency (MHz) | Bonus Points |
| --- | ---: |
| 300 | +0 |
| 400 | +2 |
| 500 | +4 |

For example, Tier 1 at 400 MHz earns 92 points, and Tier 3 at 500 MHz earns 104 points.

### 3. Schedule & Policy

- **Midterm Check**: Week 7
- **Final Deadline**: Week 14, Saturday 23:59
- **AI Policy**: AI tools are permitted; however, detailed design trade-offs, microarchitectural implementation details, and LLM interaction logs will be examined during Code Review.

---

## Top-Level Interface & AXI4-Lite Protocol

The top-level module of your CPU must be named `student_top` and placed in `verilog/filelist.f`. It interacts with external memory through an AXI4-Lite master interface.

### Module Port Declaration

```verilog
module student_top (
    input  wire        clock,
    input  wire        reset,    // Active-high, held high for 5 cycles during initialization

    // AXI4-Lite Read Address Channel (AR)
    output wire [31:0] araddr,
    output wire        arvalid,
    input  wire        arready,

    // AXI4-Lite Read Data Channel (R)
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,    // 2'b00 = OKAY, 2'b10 = SLVERR, 2'b11 = DECERR
    input  wire        rvalid,
    output wire        rready,

    // AXI4-Lite Write Address Channel (AW)
    output wire [31:0] awaddr,
    output wire        awvalid,
    input  wire        awready,

    // AXI4-Lite Write Data Channel (W)
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,    // Byte write enable mask
    output wire        wvalid,
    input  wire        wready,

    // AXI4-Lite Write Response Channel (B)
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready
);
```

### Protocol & Memory Specification

- **Address Range**: `0x00000000`–`0x0fffffff` (256 MiB). Unloaded bytes initialize to zero.
- **Alignment**: 32-bit data bus; read and write addresses must be naturally 4-byte aligned (`addr[1:0] == 2'b00`).
- **Queues & Latency**: The simulation slave maintains 16-entry request queues. A request is serviced at earliest in the cycle after handshake; default response latency is 10 cycles (`--latency 10`).
- **SRAM library**: Instantiate the parameterized `sram_fakeram` module for synchronous on-chip RAM, including byte write enables. The framework supplies its simulation model and generates FakeRAM libraries from the parameters in your Verilog; SRAM area is included in the total. No RAM list or Chisel metadata is needed. See the [SRAM interface and supported configurations](docs/sram.md).

For detailed timing diagrams and handshake rules, refer to [`docs/axi4-lite.md`](docs/axi4-lite.md).

---

## Setting up `config.mk`

`config.mk` allows you to customize tool paths, simulator options, and compilation flags without modifying the repository Makefile. Command-line assignments override variables in `config.mk`.

| Variable | Default Value | Description |
| --- | --- | --- |
| `APPIMAGE` | `$(FRAMEWORK_DIR)/cpu2026-tools-x86_64.AppImage` | Path to hardware tools AppImage; set empty to disable |
| `PYTHON` | `python3` | Python 3 executable |
| `CXX` | `g++` | Host C++ compiler (supporting C++17) |
| `AR` | `ar` | Host archiver |
| `BUILD_MAKE` | `make` | Host Make utility |
| `VERILATOR` | *(Empty)* | Native Verilator override |
| `YOSYS` | *(Empty)* | Native Yosys override |
| `ABC` | *(Empty)* | Native ABC override |
| `STA` | *(Empty)* | Native OpenSTA override |
| `ASAP7_LIB` | *(Empty)* | Directory containing the five ASAP7 `.lib` files |
| `SIM` | *(Empty)* | Optional prebuilt simulator binary (skips RTL compilation) |
| `FILELIST` | `verilog/filelist.f` | File list containing RTL source paths |
| `BUILD` | `build` | Simulator build output directory |
| `SYNTH_OUT` | `$(BUILD)/synth` | Synthesis output root; each mode writes to its own subdirectory |
| `MODE` | `opt` | Synthesis mode: `opt` or `diagnose` |
| `CLOCK_PERIOD_NS` | `2.0` | Target clock period in ns for synthesis and timing analysis |
| `JOBS` | `4` | Parallel compilation threads |
| `MAX_CYCLES` | `1000000` | Maximum simulation cycle limit |
| `LATENCY` | `10` | Memory latency in cycles |
| `WAVE` | *(Empty)* | Output VCD waveform file path |
| `LOG` | *(Empty)* | File path to save simulation output log (including `$display`) |

---

## Running Tests & Synthesis

Run `make help` for a quick reference of available commands.

### 1. Compile Simulator

Compile your RTL into a Verilator-based cycle-accurate simulator:

```sh
make build
make build JOBS=8
```

The compiled simulator binary will be written to `build/sim`.

### 2. Run Correctness Testcases

Run the functional correctness suite:

```sh
# Run all correctness testcases
make test

# Run a specific testcase
make test Case=correctness_add_to_100

# Run with increased cycle limit and custom memory latency
make test MAX_CYCLES=5000000 LATENCY=10
```

### 3. Run Performance Benchmarks

Measure dynamic cycles, instruction counts, and IPC across all benchmark suites:

```sh
# Run all performance benchmarks and print IPC table with GEOMEAN
make perf

# Run a single benchmark
make perf Case=perf_median
```

### 4. Run Single Image with Waveform Tracing & Output Logging

Execute a single test program image directly, optionally dumping VCD waveforms or saving simulation logs (including RTL `$display` debug messages):

```sh
# Run a single program with expected exit code
make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050

# Dump VCD waveform for debugging
make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050 WAVE=trace.vcd

# Save console output and debug logs to a file (mirrored live to terminal)
make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050 LOG=run.log

# Simultaneously generate waveforms and capture log output
make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050 WAVE=trace.vcd LOG=run.log
```

View the generated `trace.vcd` with [Surfer](https://surfer-project.org/) or [GTKWave](https://gtkwave.sourceforge.net/).

We strongly advise against debugging by looking at waveforms; even printing logs is better than that, and using higher-level HDLs is even better.

### 5. Synthesize Design and Measure Area and Frequency

The framework integrates the Yosys, ABC, and OpenSTA toolchains: Yosys and ABC synthesize the RTL design and map it to the ASAP7 standard cell library, after which OpenSTA performs static timing analysis (STA) on the mapped gate-level netlist. The synthesis report includes total design area (broken down into combinational logic, sequential logic, and a separate SRAM estimate), estimated maximum frequency ($F_{\max}$), minimum clock period, worst setup slack, and critical path details.

```sh
make synth                          # Default: opt mode
make synth MODE=diagnose            # diagnose mode: preserve hierarchy for per-module area breakdown
make synth CLOCK_PERIOD_NS=1.0      # opt mode: set target clock period to 1.0 ns
```

| Mode | Purpose | Default output directory |
| --- | --- | --- |
| `opt` | Flatten hierarchy and optimize across module boundaries to evaluate the final submitted design's area and timing | `build/synth/opt/` |
| `diagnose` | Preserve full module hierarchy to inspect and isolate area consumption across module instances | `build/synth/diagnose/` |

During optimization, first run **`diagnose` mode** to locate area bottlenecks. After refactoring your RTL, switch to **`opt` mode** to enable cross-boundary flattening and obtain accurate area and frequency figures close to the evaluation environment.

**Clock Target and Timing Constraints**:
`CLOCK_PERIOD_NS` defaults to **`2.0` ns** (a 500 MHz target). This constraint guides timing optimization during synthesis and serves as the baseline for setup checks in OpenSTA:
- Estimated frequency is calculated from the critical path delay as the reciprocal of the minimum clock period ($1 / T_{\min}$).
- A positive worst setup slack (`+`) means all analyzed paths meet the target clock period with margin to spare; a negative slack (`-`) indicates timing violations on the critical path.

**Module Tree Breakdown (diagnose Mode)**:
In `diagnose` mode, the report displays an instance-level breakdown tree (repeated instances of the same module are accounted for separately):
- **`Area (um^2)`**: Including the module itself and all of its submodules.
- **`Direct (um^2)`**: Counting only standard cells instantiated directly within the module (excluding submodules).
- **`% total`**: `Area` of the module as a percentage of the entire design's total area.

**Output Files and Artifacts**:
Synthesis outputs are stored in `$(SYNTH_OUT)/$(MODE)/` (`build/synth/opt/` or `build/synth/diagnose/` by default):

| File | Contents |
| --- | --- |
| `report.txt` | Human-readable text report containing area/timing summaries, the full module hierarchy tree (in diagnose mode), and critical path endpoints |
| `report.json` | Machine-readable structured JSON report containing area, timing, hierarchy, tool versions, and source hashes |
| `timing.rpt` | Detailed OpenSTA critical path report with per-cell delay and slack breakdown |
| `area.json` / `timing.json` | Isolated area and timing metric JSON files |
| `constraints.sdc` | SDC clock and interface constraints used during timing analysis |

### 6. Clean Build Artifacts

```sh
make clean
```

Removes `build/`, `build/synth/`, and `./code`.

---

## OJ Submission

When submitting your repository to the Online Judge:

1. Ensure your top-level module is named `student_top` with the exact AXI4-Lite port interface.
2. Ensure all Verilog/SystemVerilog sources are listed with relative paths in `verilog/filelist.f`.
