# bpu_test — `bpu.sv` 单元测试

用 Verilator 把 `verilog/bpu.sv` 编成一个 C++ 单元测试，对 BTB + 2-bit BHT
分支预测器做**复位、定向边界、随机对拍、准确率**四层自检。

```
test/bpu_test/
├── run.sh      # 编译并运行（一条命令）
├── bpu_tb.cpp  # 测试台（Verilator C++ harness + 独立参考模型）
├── README.md   # 本文件
└── build/      # 编译产物（已被 .gitignore 忽略）
```

> 这个文件夹**不要**加进 `verilog/filelist.f`；`bpu.sv` 也暂不登记进
> filelist，等 P1 `frontend_ooo` 例化时再加。

---

## 1. 怎么跑

```sh
sh test/bpu_test/run.sh                    # 定向 + 10 万拍随机
sh test/bpu_test/run.sh --quick            # 定向 + 1 万拍随机
sh test/bpu_test/run.sh --seed 123
sh test/bpu_test/run.sh --cycles 200000
```

可覆盖参数（会同时传给 Verilator `-G` 和 C++ 参考模型）：

```sh
BPU_BTB_INDEX_BITS=4 BPU_BHT_INDEX_BITS=6 sh test/bpu_test/run.sh --quick
```

| 变量 | 默认 | 说明 |
| --- | ---: | --- |
| `VERILATOR` | 自动探测 / AppImage | 指定 Verilator |
| `BPU_BTB_INDEX_BITS` | 6 | BTB 项数 = 2^6 = 64 |
| `BPU_BHT_INDEX_BITS` | 8 | BHT 项数 = 2^8 = 256 |

输出示例（全过）：

```text
loop 9T/1N accuracy: 8999/10000 = 89.99%
alternating accuracy: 0/10000 = 0.00%
bpu_tb: btb=6 bits bht=8 bits checked=240048 fails=0
PASS
```

退出码：`0` = 全过；`1` = 有失败；`2` = 参数错误。

## 2. 接口

```systemverilog
module bpu #(
  parameter integer BTB_INDEX_BITS = `CPU_BTB_INDEX_BITS,
  parameter integer BHT_INDEX_BITS = `CPU_BHT_INDEX_BITS
) (
  input  logic        clk, reset,

  input  logic [31:0] fetch_pc,
  output logic        predict_taken,
  output logic [31:0] predict_target,

  input  logic        upd_valid,
  input  logic [31:0] upd_pc,
  input  logic        upd_taken,
  input  logic [31:0] upd_target,
  input  logic        upd_is_uncond
);
```

预测口是**组合**输出：`fetch_pc` 稳定后同拍得到方向和目标。BTB 未命中时
`predict_taken=0`、`predict_target=0`。更新口来自 `br_update`；`upd_is_uncond`
由前端从对应 uop 的译码信息补充（`br_update` 总线本身只有 `is_jalr`，不足以
区分 JAL 和条件分支）。

## 3. 预测与更新策略

- **BTB**：直接映射，索引 `pc[BTB_INDEX_BITS+1:2]`（字地址），表项
  `{valid, tag, target, is_uncond}`；
- **BHT**：2-bit 饱和计数器，索引 `pc[BHT_INDEX_BITS+1:2]`，MSB 为 1 表示
  预测 taken；
- **无条件跳转**：BTB 命中即预测 taken，目标取 BTB；更新时 BHT 置为 `11`；
- **条件分支**：只有 BTB 命中且 BHT MSB=1 才预测 taken；
- **分配策略**：只有 taken 的条件分支和无条件跳转才分配/覆盖 BTB 项；
  条件不跳转只更新已有同 tag 项的计数器，不污染 BTB；
- **首次分配**：条件分支首次 observed taken 时 BHT 初始化为 `10`（弱 taken），
  无条件跳转初始化为 `11`；因此 BTB 数据阵列不需要复位，只复位 valid；
- **同拍冲突**：更新索引与 fetch 索引相同时，组合预测用更新后的值旁路，
  包括新目标、新 valid、新跳转类型和 BHT 次态；
- **饱和**：`00`/`11` 为两端，继续同向更新保持不变。

## 4. 测试分组

| 组 | 内容 |
| --- | --- |
| 复位/冷启动 | 复位后所有 PC 均不命中；复位清空 BTB valid |
| 定向 | 无条件跳转、条件 taken/not-taken 的 2-bit 状态迁移与饱和、目标更新、BTB tag 别名覆盖、同拍读写旁路 |
| 随机 | 10 万拍随机 fetch/update 组合（含同 PC 冲突），逐拍与 C++ 参考模型比较 pre/post 预测 |
| 准确率 | 9-taken/1-not-taken 循环（约 90%）、交替 taken/not-taken（2-bit 计数器最坏情况 0%） |

默认种子 `0x20261018`，`checked=240048 fails=0`（其中含 pre/post 两次逐拍
比较）。失败时打印前 15 条的 fetch/update 输入、阶段和期望值。

## 5. 当前状态

- `verilog/bpu.sv` 已通过 Verilator 单测与 Yosys `proc; opt; check`；
- 参数已接入 `cpu_config.sv`：`CPU_BTB_INDEX_BITS=6`、`CPU_BHT_INDEX_BITS=8`；
- 尚未登记进 `filelist.f`，基线 `make build` 不受影响。
