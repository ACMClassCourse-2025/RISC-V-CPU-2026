# RISC-V CPU 模板

[![Target: RV32IM](https://img.shields.io/badge/target-RV32IM-283272)](https://msyksphinz-self.github.io/riscv-isadoc/)
[![Simulator: Verilator](https://img.shields.io/badge/simulator-Verilator-4B7BE5)](https://www.veripool.org/verilator/)
[![Synthesis: Yosys + ASAP7](https://img.shields.io/badge/synthesis-Yosys%20%2B%20ASAP7-f39c12)](https://yosyshq.net/yosys/)
[![Bus: AXI4--Lite](https://img.shields.io/badge/bus-AXI4--Lite-green)](docs/axi4-lite.md)

[English](README-EN.md) | [简体中文](README-ZH.md)

> 开始编写你的 CPU 时，请用你自己的 README 替换本文档。

## 快速上手

欢迎来到 RISC-V CPU 课程（CPU 2026）！本仓库提供了官方 CPU 设计框架与工程模板，供你基于此设计并实现一个支持乱序执行（Out-of-Order, OoO）的 RISC-V 处理器。框架内包含了基于 Verilator 的仿真环境、AXI4-Lite 内存从机模型、官方正确性与性能测试用例、Yosys + ASAP7 逻辑综合与 OpenSTA 时序分析流程，以及统一的测试运行器。

我们强烈建议你 **Fork 本仓库**，而非直接下载 ZIP 压缩包，以便在官方测试用例或框架更新时能够轻松同步更新。Fork 之后，将其克隆到你的本地开发环境。

### 1. 初始化子模块

克隆仓库后，初始化官方测试用例子模块：

```sh
git submodule update --init --recursive
```

### 2. 硬件工具链配置

运行 Verilator 仿真、Yosys/ASAP7 综合与 OpenSTA 时序分析有以下推荐方式：

#### 方案 A：课程硬件工具链 AppImage（推荐 Linux x86-64 与 WSL2）

我们提供了独立的 Linux x86-64 预编译包 `cpu2026-tools-x86_64.AppImage`，内置了 Verilator 5.020、Yosys、ABC、OpenSTA，以及 ASAP7 7.5-track 标准单元库和私有运行时依赖。

将 `cpu2026-tools-x86_64.AppImage` 放置在项目根目录下，并赋予可执行权限：

```sh
chmod +x cpu2026-tools-x86_64.AppImage
```

Make 会自动使用此位置的工具包：`make build` 调用其中的 Verilator，`make synth` 调用其中的 Yosys、ABC、OpenSTA 与 ASAP7 库。Python、Make 和 C++ 编译器在宿主机上运行。Make 不会自动下载或重新构建 AppImage。

#### 方案 B：使用 Docker 容器

[Docker 安装](https://docs.docker.com/engine/install/)

构建基础镜像：

```sh
docker build -t cpu2026 .
```

使用命令挂载本地代码进入容器：

```sh
docker run --rm -it -v "$PWD":/work cpu2026 bash
```

进入容器 `/work` 目录下后，所有 make 命令均能正常工作。

#### 方案 C：手动指定工具链

你可以在 `config.mk` 中配置工具链具体路径：
  ```make
  APPIMAGE =
  VERILATOR = /path/to/verilator
  YOSYS = /path/to/yosys
  ABC = /path/to/yosys-abc
  STA = /path/to/sta
  ASAP7_LIB = /path/to/asap7/lib
  ```

### 3. 项目模板

我们也提供了 [Chisel 模板](https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026/tree/chisel-example)。

---

## 概述

在本门课程中，你可以使用**任意硬件描述语言**来实现你的 CPU（例如 Verilog、SystemVerilog、Chisel、Assasyn 等）。由于课程评测平台与综合工具以 Verilog/SystemVerilog 为统一输入，使用高层 HDL 的同学在提交前需要将其编译输出为 Verilog 代码。

### 目录结构

```text
.
├── config.mk                   # 本地配置（工具路径、测试参数等）
├── Makefile                    # 统一构建、仿真、测试与综合入口
├── docs/
│   ├── axi4-lite.md            # AXI4-Lite 协议与内存约定详解
│   └── sram.md                 # SRAM 接口、成本模型与支持范围
├── verilog/
│   └── filelist.f              # RTL 源文件列表（路径相对于 verilog/ 目录）
├── testcases/                  # 官方测试用例（submodule）
│   ├── correctness_*           # 功能正确性测试集
│   └── perf_*                  # IPC 评测性能基准测试集
├── scripts/                    # 构建脚本与仿真驱动（请勿修改）
└── packaging/                  # AppImage 打包与构建脚本（如果你不需要，你可以删掉它）
```

---

## 架构要求与设计规范

### 1. 指令集（RV32IM）

- **基础整数指令**：完整支持 RV32I 用户态指令集。
- **M 扩展**：完整实现标准乘除法指令：
  `MUL`, `MULH`, `MULHSU`, `MULHU`, `DIV`, `DIVU`, `REM`, `REMU`。
- **访存指令**：完整实现整数 Load/Store 指令：
  `LB`, `LBU`, `LH`, `LHU`, `LW`, `SB`, `SH`, `SW`。
  - 访存地址按自然边界对齐（半字 2 字节对齐，字 4 字节对齐）。不要求支持非对齐访存。
- **免除指令**：
  - `CSR*` 控制与状态寄存器指令不做要求。
  - `FENCE` 与 `FENCE.I` 内存屏障指令不做要求。
  - `ECALL` 与 `EBREAK` 指令不做要求。

### 2. 微架构要求

- **乱序执行（Out-of-Order Execution）**：当操作数就绪时，指令必须能够乱序发射并执行。
- **按序提交（In-Order Commit）**：必须按原始程序顺序提交（退休）指令（例如使用 Reorder Buffer / ROB）。
- **参数化设计**：
  核心微架构参数应可在设计中进行参数化配置：
  - 发射宽度（Issue Width）
  - 重排序缓冲区大小（ROB Depth）
  - 物理寄存器堆大小（PRF Size）
  - 保留站 / 发射队列深度
  - Cache 容量与相联度

### 3. 终止与输出约定

- 程序通过向 MMIO 地址 **`0x80000000` 执行 32 位 Store 操作**（`WSTRB = 4'b1111` 即 `4'hf`）标记结束并输出结果。
- 最终退出返回值存放于 `WDATA[31:0]`。
- 正确性评测将最终退出返回值与标准答案进行比较。

### 4. 内存布局

- **外部 RAM**：容量为 256 MiB 的小端内存（地址范围 `0x00000000`–`0x0fffffff`）。

### 5. 设计报告要求

两人一组，项目完成后需提交一份实验报告，内容涵盖：
- **参数敏感度分析**：评估不同参数配置（例如不同发射宽度、物理寄存器堆大小、ROB 大小、Cache 配置等）对性能（IPC）的敏感度与影响趋势。
- **架构探索总结**：记录在开发过程中所做的架构探索、遇到的问题以及权衡取舍（Trade-offs）。

---

## 评分标准与时间安排

### 1. 正确性（满分 85 分）

| 阶段 | 要求 | 累计分数 |
| --- | --- | ---: |
| 基础程序 | 通过：向量乘法、向量加法、`0` 到 `100` 的累加 | 75 |
| 仿真程序 | 继续通过 CPU 仿真测试集中的其余程序 | 85 |

*注：未通过前一阶段测试时，无法获得后一阶段的分数。最终退出返回值需与标准答案完全一致。*

### 2. 性能（满分 15 分，另有最高 4 分频率加分）

- **面积**：使用 **Yosys + ASAP7** 7.5-track RVT TT 标准单元库综合评估逻辑面积，加上 FakeRAM 的 SRAM 估算面积（单位 $\mu m^2$）。报告列出总面积，以及组合逻辑、时序逻辑和 SRAM 各部分面积。
- **IPC**：使用 Verilator 仿真测量实际运行周期，计算公式为 $\text{IPC} = \frac{\text{动态指令数}}{\text{运行周期数}}$。综合 IPC 为所有 `testcases/perf_*` 测试点 IPC 的**几何平均数（GEOMEAN）**。

| 阶段   | 最大面积 ($\mu m^2$) | 最低 IPC（几何平均） | 最低频率（MHz） | 累计分数 |
|------|------------------|--------------|-----------|------|
| 阶段 1 | 9,000            | 0.6000       | 300       | 90   |
| 阶段 2 | 18,000           | 0.8450       | 300       | 95   |
| 阶段 3 | 36,000           | 1.0985       | 300       | 100  |

**频率加分**：满足某一阶段的面积、IPC 和 300 MHz 最低频率要求后，在该阶段的累计分数基础上增加以下分数。

| 最低频率（MHz） | 加分 |
| --- | ---: |
| 300 | +0 |
| 400 | +2 |
| 500 | +4 |

例如，达到阶段 1 且频率为 400 MHz 时得 92 分，达到阶段 3 且频率为 500 MHz 时得 104 分。

### 3. 时间安排与 AI 政策

- **中期检查**：第 7 周
- **最终截止（DDL）**：第 14 周周六 23:59
- **AI 政策**：允许使用 AI 辅助编码，但 Code Review 时会重点考察架构设计细节、模块具体权衡，并会查看与 LLM 的交互记录。

---

## 顶层模块与 AXI4-Lite 协议

你的 CPU 顶层模块名必须为 `student_top`，并列入 `verilog/filelist.f`。CPU 作为 Master 端，通过 AXI4-Lite 协议与外部内存 Slave 端通信。

### 模块端口定义模板

```verilog
module student_top (
    input  wire        clock,
    input  wire        reset,    // 高电平复位，初始化时保持 5 周期高电平

    // AXI4-Lite 读地址通道 (AR)
    output wire [31:0] araddr,
    output wire        arvalid,
    input  wire        arready,

    // AXI4-Lite 读数据通道 (R)
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,    // 2'b00 = OKAY, 2'b10 = SLVERR, 2'b11 = DECERR
    input  wire        rvalid,
    output wire        rready,

    // AXI4-Lite 写地址通道 (AW)
    output wire [31:0] awaddr,
    output wire        awvalid,
    input  wire        awready,

    // AXI4-Lite 写数据通道 (W)
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,    // 字节写使能掩码
    output wire        wvalid,
    input  wire        wready,

    // AXI4-Lite 写响应通道 (B)
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready
);
```

### 总线与内存约定

- **地址范围**：`0x00000000`–`0x0fffffff`（256 MiB）。未初始化的字节默认清零。
- **对齐要求**：32 位数据总线，读写地址必须自然 4 字节对齐（`addr[1:0] == 2'b00`）。
- **队列与延迟**：内存模拟从机为每个通道维护 16 项请求队列。请求最快在握手后的下一周期被服务；从服务到响应可见默认延迟 10 个周期（可通过 `--latency 10` 调整）。
- **SRAM 库**：实例化参数化的 `sram_fakeram` 模块即可使用同步片上 RAM，支持字节写使能。框架自动提供仿真模型，并从提交的 Verilog 参数生成 FakeRAM 库；SRAM 估算面积计入总面积。无需 RAM 清单或 Chisel 元数据。接口及支持范围见 [SRAM 使用指南](docs/sram.md)。

详细握手时序与响应码说明请参阅 [`docs/axi4-lite.md`](docs/axi4-lite.md)。

---

## 配置 `config.mk`

通过编辑 [`config.mk`](config.mk)，你可以为本地机器指定工具路径与运行参数，而无需修改 Makefile。命令行传入的参数具有最高优先级。

| 变量名 | 默认值 | 说明 |
| --- | --- | --- |
| `APPIMAGE` | `$(FRAMEWORK_DIR)/cpu2026-tools-x86_64.AppImage` | 硬件工具链 AppImage 路径；设为空则禁用 |
| `PYTHON` | `python3` | 宿主机 Python 3 可执行文件 |
| `CXX` | `g++` | 宿主机 C++ 编译器（需支持 C++17） |
| `AR` | `ar` | 宿主机归档工具 |
| `BUILD_MAKE` | `make` | 宿主机 GNU Make |
| `VERILATOR` | *(空)* | 原生 Verilator 路径覆盖 |
| `YOSYS` | *(空)* | 原生 Yosys 路径覆盖 |
| `ABC` | *(空)* | 原生 ABC 路径覆盖 |
| `STA` | *(空)* | 原生 OpenSTA 路径覆盖 |
| `ASAP7_LIB` | *(空)* | 包含 5 个 ASAP7 `.lib` 文件的目录路径 |
| `SIM` | *(空)* | 预编译模拟器路径（跳过 RTL 编译） |
| `FILELIST` | `verilog/filelist.f` | RTL 源文件列表文件 |
| `BUILD` | `build` | 模拟器构建输出目录 |
| `SYNTH_OUT` | `$(BUILD)/synth` | 综合产物输出根目录；每种模式写入各自的子目录 |
| `MODE` | `opt` | 综合模式：`opt` 或 `diagnose` |
| `CLOCK_PERIOD_NS` | `2.0` | 综合与时序分析的目标时钟周期，单位 ns |
| `JOBS` | `4` | 多线程并行编译任务数 |
| `MAX_CYCLES` | `1000000` | 单测试点最大仿真周期数限制 |
| `LATENCY` | `10` | 内存访问响应周期延迟 |
| `WAVE` | *(空)* | 输出 VCD 波形文件路径 |
| `LOG` | *(空)* | 保存仿真输出日志（包含 `$display` 输出）的文件路径 |

---

## 编译、运行与综合

运行 `make help` 可查看常用命令帮助。

### 1. 编译仿真器

将 RTL 代码通过 Verilator 编译为周期精确仿真器：

```sh
make build
make build JOBS=8
```

编译产物将生成在 `build/sim`。

### 2. 运行正确性测试

运行全部或单个功能正确性测试：

```sh
# 运行全部正确性测试点
make test

# 运行单个测试点
make test Case=correctness_add_to_100

# 自定义最大周期上限与内存延迟
make test MAX_CYCLES=5000000 LATENCY=10
```

### 3. 运行性能基准测试

测量各基准程序的动态指令数、周期数与 IPC：

```sh
# 运行全部性能测试点并输出 IPC 表格与几何平均值
make perf

# 运行单个性能测试点
make perf Case=perf_median
```

### 4. 运行单程序、导出波形与日志

执行单个二进制/数据镜像，并支持导出 VCD 波形与保存仿真日志（包括 RTL 中的 `$display` 调试信息）：

```sh
# 运行单测试点并指定期望结果
make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050

# 导出 VCD 波形
make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050 WAVE=trace.vcd

# 保存仿真控制台输出与调试日志到文件（终端仍会同步显示）
make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050 LOG=run.log

# 同时导出波形与保存日志
make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050 WAVE=trace.vcd LOG=run.log
```

生成的 `trace.vcd` 可以使用 [Surfer](https://surfer-project.org/) 或 [GTKWave](https://gtkwave.sourceforge.net/) 查看。

我们强烈建议你不要对着波形调试，即使是打印日志也比波形强，使用某些高级 HDL 语言更好。

### 5. 逻辑综合与面积、频率评估

框架集成了 Yosys、ABC 与 OpenSTA 工具链：由 Yosys 与 ABC 将 RTL 设计综合并映射到 ASAP7 标准单元库，再通过 OpenSTA 对门级网表执行静态时序分析（STA）。综合流程会自动评估并输出：电路总面积（细分为组合逻辑、时序逻辑及独立的 SRAM 估算面积）、估算最高运行频率（$F_{\max}$）、最小时钟周期、建立时间裕量（Worst Setup Slack）以及关键路径详情。

```sh
make synth                          # 默认使用 opt 模式
make synth MODE=diagnose            # diagnose 模式：保留模块层次，定位逐模块面积开销
make synth CLOCK_PERIOD_NS=1.0      # opt 模式：指定目标时钟周期为 1.0 ns
```

| 模式 | 用途 | 默认输出目录 |
| --- | --- | --- |
| `opt` | 展平模块层次并进行跨边界逻辑优化，用于评估最终提交设计的面积与时序性能 | `build/synth/opt/` |
| `diagnose` | 保留完整模块层次结构，用于逐级排查各模块及其实例的面积占用情况 | `build/synth/diagnose/` |

在进行优化时，先运行 **`diagnose` 模式**，定位消耗面积最多的模块；对其重构后，切换至 **`opt` 模式** 进行跨模块边界展平优化，获取更接近真实评测表现的面积与频率结果。

**时钟周期与时序约束说明**：
`CLOCK_PERIOD_NS` 默认为 **`2.0` ns**（对应 500 MHz 目标频率）。该参数用于驱动 ABC 在逻辑优化阶段进行时序重构，并作为 OpenSTA 检查建立时间的时钟基准：
- 估算最高频率（Estimated frequency）是基于最差关键路径延迟推算得出的最小时钟周期倒数（$1 / T_{\min}$）。
- 建立时间裕量（Worst Setup Slack）为正（`+`）表示所有时序路径均满足设定的目标周期要求；裕量为负（`-`）则表示最差路径超时，存在建立时间违例（Timing Violation）。

**模块树面积统计（diagnose 模式）**：
在 `diagnose` 模式下，报告会按照模块实例层级展开树状明细（同一模块被多次例化时，各实例独立统计）：
- **`Area (um^2)`**：包含当前模块及其所有子模块的面积总和。
- **`Direct (um^2)`**：仅统计直接属于当前模块、不包含任何下属子模块的标准单元面积。
- **`% total`**：当前模块 `Area` 占整个设计总面积的百分比。

**产物目录说明**：
每次运行的详细产物存放在 `$(SYNTH_OUT)/$(MODE)/`（默认为 `build/synth/opt/` 或 `build/synth/diagnose/`）目录下：

| 输出文件 | 说明 |
| --- | --- |
| `report.txt` | 面积与时序摘要纯文本报告，包含 diagnose 模式下的完整模块树及关键路径起止点 |
| `report.json` | 机器可读的结构化 JSON 报告，包含面积、时序、模块层次、工具版本及源码校验信息 |
| `timing.rpt` | OpenSTA 生成的详细关键路径报告，包含路径上逐级门级单元延迟与 Slack 明细 |
| `area.json` / `timing.json` | 独立的面积与时序数据 |
| `constraints.sdc` | 时序分析使用的时钟及 I/O 约束定义文件 |

### 6. 清理构建产物

```sh
make clean
```

该命令将清除 `build/`、`build/synth/` 以及根目录下的 `code` 可执行文件。

---

## OJ 提交

在向 OJ 提交你的仓库前，请完成以下检查：

1. 确保顶层模块命名为 `student_top`，并严格实现规范要求的 AXI4-Lite 端口信号。
2. 确保所有涉及的 Verilog/SystemVerilog 源文件均以相对路径列入 `verilog/filelist.f`。
