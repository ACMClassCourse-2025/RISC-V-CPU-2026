# pc_unit_test — `pc_unit.sv` 单元测试

用 Verilator 把 `verilog/pc_unit.sv` 编成一个 C++ 单元测试，对 PC 更新逻辑做
**复位 + 定向边界 + 随机对拍**自检。

```
test/pc_unit_test/
├── run.sh         # 编译并运行（一条命令）
├── pc_unit_tb.cpp # 测试台（Verilator C++ harness + 参考模型）
├── README.md      # 本文件
└── build/         # 编译产物（已被 .gitignore 忽略）
```

> 这个文件夹**不要**加进 `verilog/filelist.f`；它只用于本地测试，不参与 OJ
> 综合和提交。`pc_unit` 本身也暂不登记进 filelist，等 P1 前端例化时再加。

---

## 1. 环境要求

- Verilator 5.020（课程 AppImage 内置版本一致）；
- 宿主机 g++（C++17）、GNU Make。

Verilator 解析顺序：`$VERILATOR` > AppImage 环境（`$CPU2026_APPDIR`）> PATH >
自动借仓库根目录的 `cpu2026-tools-x86_64.AppImage` 重入。因此本机不需要预装
Verilator。

## 2. 怎么跑

在仓库根目录（或任意目录）执行：

```sh
sh test/pc_unit_test/run.sh              # 完整：定向 + 10 万拍随机对拍
sh test/pc_unit_test/run.sh --quick      # 快速：定向 + 1 万拍随机
sh test/pc_unit_test/run.sh --seed 123   # 换随机种子
sh test/pc_unit_test/run.sh --cycles 200000
```

可用的环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `VERILATOR` | 自动探测 / AppImage | 指定 Verilator 可执行文件 |

输出示例（全过）：

```text
pc_unit_tb: checked=100073 fails=0
PASS
```

退出码：`0` = 全过；`1` = 有失败；`2` = 环境/参数错误。可以直接挂到 CI。

## 3. 测试假设的接口与语义

```systemverilog
module pc_unit (
  input  logic        clk, reset,
  input  logic        advance,        // 下游接收，pc <= pc + 4
  input  logic        stall,          // 保持当前 PC
  input  logic        redirect_valid,
  input  logic [31:0] redirect_pc,
  output logic [31:0] pc
);
```

每个时钟沿按优先级更新：

| 优先级 | 条件 | 行为 |
| ---: | --- | --- |
| 1 | `reset=1` | `pc <= 0x0000_0000`（程序入口，高有效同步复位） |
| 2 | `redirect_valid=1` | `pc <= redirect_pc` |
| 3 | `stall=1` | `pc` 保持 |
| 4 | `advance=1` | `pc <= pc + 4` |
| — | 都不满足 | `pc` 保持 |

补充约定：

1. redirect 在有效当拍的时钟沿被接受，**下一拍** `pc` 输出已经是新值；
2. `stall` 与 `advance` 同拍时 stall 优先（下游未接收，不推进）；
3. PC 是 32 位自然回绕：`0xFFFF_FFFC + 4 = 0x0000_0000`；
4. reset 优先级最高，复位同拍的 redirect/stall/advance 一律忽略。

## 4. 测试分组

| 组 | 数量 | 内容 |
| --- | ---: | --- |
| 复位 | 4 | 复位与 redirect/stall/advance 同拍冲突、复位后空闲 |
| 定向 | 69 | 空闲保持、连续推进、stall、stall+advance、redirect 单独/同拍 advance/同拍 stall/三者同拍、连续 redirect、redirect 次拍生效、`pc+4` 回绕 |
| 随机 | 100,000 | 随机 reset/redirect/stall/advance 组合，逐拍与 C++ 参考模型对拍（默认） |

合计 `100073` 拍（`--quick` 为 `10073` 拍）。

随机激励的权重约为：reset 1/256、redirect 1/8、stall 1/2、advance 1/2；
重定向目标偶尔取 `0xFFFF_FFF8/0xFFFF_FFFC` 以覆盖回绕边界。任何失败都会打印
前 12 条的周期号、前一拍 PC、输入和期望值。

## 5. 这个测试是怎么写的

1. **独立参考模型**：C++ 里按优先级顺序更新 `model_pc`，与 RTL 的
   `always_ff` 写法相互独立，逐拍比较 DUT 的 `pc` 输出；
2. **同拍冲突定向覆盖**：reset/redirect/stall/advance 的所有关键组合都显式
   驱动，避免只靠随机碰运气；
3. **时序检查**：输入在时钟沿前施加、沿后采样，redirect "次拍生效" 的语义
   直接由连续两拍用例验证；
4. **回绕边界**：从 `0xFFFF_FFF8/0xFFFF_FFFC/0xFFFF_FFFE` 出发连续推进，
   检查 32 位自然溢出。

## 6. 当前状态

- 已通过：`checked=100073 fails=0`（默认种子 `0x20261018`）；
- 未修改 `filelist.f`；`pc_unit` 尚未参与 `make build`，等 P1 例化时登记。
