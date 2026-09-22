# 片上 SRAM 存储库 (`sram_fakeram`)

本框架提供了参数化的 `sram_fakeram` 模块，用于在你的 CPU 中实例化具备可估算面积与时序的片上同步 SRAM 存储块。

> [!NOTE]
> 它用于构建 CPU 内部的**片上存储结构**（例如指令/数据 Cache 的数据与标签阵列、分支目标缓冲 BTB、分支历史表 BHT 等）。它与仿真平台提供的外部 256 MiB AXI4-Lite 内存从机是完全独立的。

---

## 1. 快速上手

### Verilog / SystemVerilog 实例化示例

在你的 RTL 中直接实例化 `sram_fakeram` 即可：

```systemverilog
// 示例：1024 深度 x 32 位宽 SRAM，支持字节写使能掩码
wire [31:0] ram_rdata;

sram_fakeram #(
    .DEPTH             (1024), // 存储字数（深度）
    .WIDTH             (32),   // 每个字的位宽
    .WRITE_GRANULARITY (8)    // 写掩码粒度为 8 位（对应 4 位 wmask）
) data_ram (
    .clk   (clock),
    .en    (ram_en),
    .we    (ram_we),
    .wmask (ram_wmask),  // 4 位写掩码：wmask[0] 控制 wdata[7:0]，依此类推
    .addr  (ram_addr),   // 10 位字索引（范围 0..1023）
    .wdata (ram_wdata),  // 32 位写入数据
    .rdata (ram_rdata)   // 32 位读出数据，在读操作发起的下一个周期有效
);
```

### 构建与综合命令

将你的 RTL 源文件列入 `verilog/filelist.f`，然后使用常规命令：

```sh
make build    # 使用 Verilator 编译仿真可执行文件
make synth    # 使用 Yosys 综合 RTL，并汇总标准单元逻辑面积与 SRAM 估算面积
```

> [!IMPORTANT]
> - **切勿将 `scripts/ram/sram_fakeram.sv` 添加到 `verilog/filelist.f`**，构建与综合脚本会自动引入该文件。
> - **切勿在你的工程中自行声明或编写 `sram_fakeram` 的空桩（Stub）代码**，模块名 `sram_fakeram` 以及以 `sram_fakeram_`、`fakeram_asap7_` 开头的前缀均为框架保留名称。
> - 如需在框架外的独立仿真环境中编译，只需将 [`scripts/ram/sram_fakeram.sv`](../scripts/ram/sram_fakeram.sv) 与你的设计一同编译即可，仿真阶段不需要 Yosys 或 Liberty 文件。

---

## 2. 参数配置与端口规范

### 参数配置说明

| 参数名 | 默认值 | 支持范围 | 描述 |
| :--- | :---: | :--- | :--- |
| `DEPTH` | `256` | 整数 $1 \dots 1{,}048{,}576$ | 可寻址的存储字数。 |
| `WIDTH` | `32` | 整数 $1 \dots 4{,}096$ | 每个存储字的位宽（支持 1、8、21、32、128 等任意合法整数）。 |
| `WRITE_GRANULARITY` | `WIDTH` | 整数 $1 \dots \text{WIDTH}$ | 写使能掩码的粒度（位数），**必须能够整除 `WIDTH`**。 |

单个 `sram_fakeram` 实例最多包含 **16,777,216 位**（即 $\text{DEPTH} \times \text{WIDTH} \le 2^{24}$ 位，折合 2 MiB）。

### 端口信号说明

| 端口名 | 方向 | 位宽 | 功能描述 |
| :--- | :---: | :--- | :--- |
| `clk` | 输入 | `1` | 时钟信号（上升沿有效触发）。 |
| `en` | 输入 | `1` | 存储体访问使能（高电平有效）。读写均须置 `1`。 |
| `we` | 输入 | `1` | 读写选择（`0` = 读操作，`1` = 写操作）。`en=0` 时忽略。 |
| `wmask` | 输入 | `WIDTH / WRITE_GRANULARITY` | 写字节/位掩码（高电平有效，低位对应低数据通道）。 |
| `addr` | 输入 | $\max(1, \lceil\log_2(\text{DEPTH})\rceil)$ | **字索引地址**（有效范围 $0 \le \text{addr} < \text{DEPTH}$）。 |
| `wdata` | 输入 | `WIDTH` | 写入数据总线。 |
| `rdata` | 输出 | `WIDTH` | 同步读出数据总线，在读发起后的下一个周期保持有效。 |

> [!TIP]
> **写掩码 `wmask` 与写粒度 `WRITE_GRANULARITY` 搭配：**
> - **整字写入**：省略 `WRITE_GRANULARITY`（默认等于 `WIDTH`），此时 `wmask` 为 1 位宽，直接接 `1'b1` 即可。
> - **字节写入**：设置 `WRITE_GRANULARITY = 8`，且 `WIDTH` 为 8 的倍数。例如 32 位宽有 4 位掩码，128 位宽有 16 位掩码。

---

## 3. 操作语义与访问时序

`sram_fakeram` 遵循现代同步单端口（1RW）SRAM 硬件时序。深入理解以下规则能有效避免流水线设计缺陷：

1. **单端口 1RW 架构**：SRAM 仅具备一个共享的读写端口。在任何给定时钟周期内，只能执行**一次读**或者**一次写**。
2. **同步 1 周期读延迟（Synchronous 1-Cycle Read Latency）**：
   - 当时钟上升沿采样到 `en = 1` 且 `we = 0` 时，启动读操作。
   - 读出的数据将在**该时钟沿之后（即下一个周期）**在 `rdata` 上有效并保持整个周期。
3. **带通道掩码的同步写操作**：
   - 当时钟上升沿采样到 `en = 1` 且 `we = 1` 时，对所有 `wmask[i] == 1` 的通道更新为 `wdata` 对应的值；`wmask[i] == 0` 的通道保持原值不变。
   - 若 `wmask` 全为 0，则当前存储内容完全不受影响。
4. **写周期与禁用周期的未定义输出**：
   - 当 `en = 0`，或者处于写周期（`en = 1, we = 1`）时，`rdata` 上的数据是**未定义的**。
5. **无全局复位引脚**：
   - SRAM 不保证 reset 后内容全 0，若需要请手动依次清空。
6. **地址合法性要求**：
   - 每次 `en = 1` 时，`addr` 必须处于合法区间 $[0, \text{DEPTH}-1]$。访问越界地址会报错并终止仿真。
