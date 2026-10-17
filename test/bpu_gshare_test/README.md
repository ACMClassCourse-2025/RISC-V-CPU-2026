# bpu_gshare_test — P2 预研：gshare + BTB

用 Verilator 对 `verilog/bpu_gshare.sv` 做串行分支流测试：先读预测，再在时钟沿
更新；C++ 参考模型独立实现 BTB + gshare，并同时维护普通 2-bit BHT 作为准确率
对照。

```
test/bpu_gshare_test/
├── run.sh
├── bpu_gshare_tb.cpp
├── README.md
└── build/
```

> 本目录和 `bpu_gshare.sv` 暂不进 `filelist.f`；P2 正式接入前先与乙确认
> 是否需要 `br_update` 增加 GHR 快照字段。

## 1. 怎么跑

```sh
sh test/bpu_gshare_test/run.sh                 # 默认 8-bit GHR，5 万拍随机
sh test/bpu_gshare_test/run.sh --quick
GHIST_BITS=4 sh test/bpu_gshare_test/run.sh --quick --cycles 5000
```

参数：`BTB_BITS`（默认 6）、`BHT_BITS`（默认 8）、`GHIST_BITS`（默认 8）。
`run.sh` 在参数变化时清理旧 build 目录，避免复用旧对象。

## 2. 结构

- BTB：直接映射 `{valid, tag, target, is_uncond}`；
- gshare：BHT 索引 = `pc[bits+1:2] ^ GHR`，2-bit 饱和计数器；
- GHR：每次 `upd_valid` 左移并写入 `upd_taken`；
- BHT 有效位：`bht_valid` 复位为 0；未初始化表项按 `2'b01`（弱不跳转）使用，
  避免要求整张 BHT 有复位值；
- 同拍更新旁路：BTB/BHT 索引与 fetch 冲突时用更新后的值；
- 更新策略与 `bpu.sv` 一致：无条件跳转置 `11`；条件 taken 饱和加一；
  not-taken 只更新已有 BTB 项。

## 3. 测试结果（默认参数）

```text
loop 9T/1N: gshare 15985/20000 = 79.92%, bht 17999/20000 = 90.00%
correlated: gshare 9994/10000 = 99.94%, bht 0/10000 = 0.00%
random: gshare accuracy 25094/50000 = 50.19%
bpu_gshare_tb: btb=6 bht=8 ghr=8 checked=80000 fails=0
PASS
```

- 单分支 9T/1N：普通 BHT 更优（gshare 被历史打散）；
- 相关分支流：gshare 接近 100%，BHT 0%，体现全局历史价值；
- 随机独立分支：两者都接近 50%，符合无信息场景。

## 4. 限制

- 当前 `br_update` 不带预测时的 GHR 快照，更新使用当拍 GHR；P2 正式接入时
  应在 ROB 表项保存 GHR 快照，避免乱序解析导致更新错误；
- RAS 需要 `is_call/is_return` 字段，当前接口没有，等 M5 扩展后再加；
- 准确率数据来自 synthetic trace，不代表课程程序真实 IPC。

## 5. 当前状态

- 默认 8-bit 与 4-bit GHR 均通过模型对拍；
- 尚未进入 `filelist.f`，不影响基线 `make build`。
