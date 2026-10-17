# icache_pipe_test — `icache_pipe.sv` 单元测试

用 Verilator 把 P1 流水线 I-Cache 编成 C++ 单元测试，覆盖命中吞吐、缺失回填、
反压、flush 与随机对拍。

```
test/icache_pipe_test/
├── run.sh             # 编译并运行
├── icache_pipe_tb.cpp # 测试台 + 回填内存模型
├── README.md
└── build/             # 编译产物（已忽略）
```

> 本目录和 `icache_pipe.sv` 暂不进入 `filelist.f`；等 P1 前端集成时再登记。

## 1. 怎么跑

```sh
sh test/icache_pipe_test/run.sh                 # 定向 + 10 万拍随机
sh test/icache_pipe_test/run.sh --quick         # 2 万拍随机
sh test/icache_pipe_test/run.sh --seed 123
ICACHE_INDEX_BITS=10 sh test/icache_pipe_test/run.sh --quick
```

默认测试用 `INDEX_BITS=4`（16 行），便于覆盖同索引不同 tag 的别名；正式配置
默认是 10（1024 行）。回填数据由 `mem_word(addr) = (addr & ~3) ^ 0x5a5a0000`
生成，测试台在 `refill_valid` 期间检查地址稳定。

## 2. 接口

```systemverilog
module icache_pipe #(
  parameter integer INDEX_BITS = `CPU_ICACHE_INDEX_BITS
) (
  input  logic        clk, reset, flush,

  input  logic        fetch_valid,
  input  logic [31:0] fetch_pc,
  output logic        fetch_ready,

  output logic        fetch_resp_valid,
  output logic [31:0] fetch_resp_pc,
  output logic [31:0] fetch_inst,
  input  logic        fetch_resp_ready,

  output logic        refill_valid,
  output logic [31:0] refill_addr,
  input  logic        refill_resp_valid,
  input  logic [31:0] refill_rdata
);
```

- `fetch_valid/fetch_ready`：PC 在两者同拍为 1 时被接收；
- `fetch_resp_valid/fetch_resp_ready`：命中响应按接收顺序返回，反压时保持；
- `refill_valid` 在缺失期间保持，`refill_addr` 直到响应都不变；
- `flush` 单拍有效、最高优先级：清空 lookup 与输出缓冲；若正在等回填，
  进入 DRAIN，等旧响应返回后丢弃，不会写入 Cache。

## 3. 流水结构

```
s1: 请求寄存器 -> tag/data SRAM 读
s2: 寄存 s1 的 PC/tag 与 SRAM 读出的 tag/data/valid -> 命中组合输出
buf: 回填响应 1 项缓冲（保持输出顺序 + 吸收反压）
```

- 命中：s2 每拍可消费一条，s1 同拍接收下一条，稳态 1 条/拍；
- 缺失：s2 记录缺失 PC，s1 中唯一的年轻 PC 存入 `pending`，回填完成后先输出
  缺失 PC，再重新取 `pending`，不会丢已接收的请求；
- 回填：写 data/tag SRAM、置 valid，并把 `refill_rdata` 旁路到 buf；
- 行宽固定 4B（P1 契约）；P2 扩展多字行时在 REFILL 内按字写入。

## 4. 测试分组

| 组 | 内容 |
| --- | --- |
| 冷缺失/回填 | 首次访问缺失、回填数据、重复访问命中且不再 refill |
| 别名 | 同索引不同 tag 覆盖后旧 PC 重新缺失 |
| 反压 | `fetch_resp_ready=0` 时 PC/指令保持稳定，释放后正确消费 |
| 吞吐 | 预填 8 条连续 PC 后连续取指，8 条/10 拍（约 1 条/拍） |
| flush | lookup 中冲刷、refill 中冲刷（旧响应丢弃且需重新 refill）、输出缓冲中冲刷 |
| 随机 | 10 万拍随机 fetch/ready/flush + 随机回填延迟，按序核对 PC/指令 |

完整运行输出示例：

```text
hit throughput: 8 instructions in 10 cycles
icache_pipe_tb: checked=19229 fails=0 accepts=18082 responses=16864 refills=14800
PASS
```

随机测试的 refill 数较高，是因为默认用 16 行 Cache + 24 个 PC 的池子并随机
flush，属于压力场景，不代表真实程序命中率。

## 5. 当前状态

- Verilator 单测通过；`ICACHE_INDEX_BITS=10` 也做快速回归；
- 尚未接入 `frontend_ooo`，因此未登记 `filelist.f`；
- 基线 `core.sv` 仍使用原 `icache.sv`，`make build` 不受影响。
