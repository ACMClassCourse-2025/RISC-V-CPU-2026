# rename_test — `rename.sv` 单元测试

用 Verilator 把寄存器重命名模块编成 C++ 单元测试，覆盖 RAT/commit RAT、
空闲物理寄存器表、x0、W 路组内依赖、提交释放、唤醒和恢复。

```
test/rename_test/
├── run.sh      # 编译并运行
├── rename_tb.cpp
├── README.md
└── build/      # 编译产物（已忽略）
```

> 本目录和 `rename.sv` 暂不进入 `filelist.f`；等 `frontend_ooo` 集成时再登记。

## 1. 怎么跑

```sh
sh test/rename_test/run.sh                 # W=1，定向 + 20 万拍随机
sh test/rename_test/run.sh --quick         # W=1，2 万拍随机
RENAME_W=2 sh test/rename_test/run.sh      # W=2，额外跑组内依赖用例
RENAME_W=2 sh test/rename_test/run.sh --quick
```

`RENAME_W` 会同时覆盖 `CPU_ISSUE_WIDTH` 和 C++ 测试的 `TB_W`；切换宽度时
`run.sh` 会清理旧 build 目录，避免 Verilator 复用旧对象。

## 2. 接口约定

- 输入 `in_uop` 是 `W × CPU_DECODE_W` 扁平总线。每个 lane 的前 122 位与
  `dispatch` 布局一致，另外在偏移 122/127 放 `rs1/rs2`（rename 需要源寄存器号）。
- 输出 `out_uop` 是 `W × CPU_RENAME_W`，字段与 `dispatch` 相同但**不含**
  `rob_idx`；`rob_idx` 由 ROB 分配。`out_old_tag` 给出每条 `reg_we=1` uop 的
  旧物理映射。
- `in_ready/out_ready` 是整组握手；`in_valid` 前缀有效。
- `lsq_id` 由 rename 对 load/store 循环分配，宽度 `CPU_LSQ_IDX_W`。

### 提交端口

ROB 每拍送出最多 W 条提交信息：

| 字段 | 说明 |
| --- | --- |
| `commit_valid` | 提交有效 |
| `commit_rd` / `commit_dest_tag` / `commit_reg_we` | 更新 commit RAT |
| `commit_free_valid` / `commit_free_tag` | 释放的物理 tag。`reg_we=1` 时通常是 `old_tag`；`reg_we=0` 时由 ROB 释放该 uop 的 `dest_tag` |

### 唤醒与恢复

- `wake_valid/wake_tag`：CDB/complete 汇总，清 `busy`；
- `recover_valid`：ROB 给出恢复后的 `recover_free_mask`、`recover_busy_mask`、
  `recover_lsq_ptr`；rename 在同一拍把 `rat <= crat` 并整体装载这些状态。
  `recover_valid` 当拍 `in_ready=0`。

## 3. 复位与分配策略

- 所有架构寄存器复位映射到物理寄存器 0（`PRF[0]` 恒 0），因此初始值全为 0、
  全部 ready；这样不要求 PRF 有复位值；
- `free_vec` 复位为除 bit0 外全 1；
- 每条有效 uop 都分配一个唯一 `dest_tag`，包括 `reg_we=0`；
- 分配优先低编号物理寄存器；同拍 W 条按 lane 顺序依次分配；
- 组内 lane `i` 读 lane `j<i` 写的 rd 时，`src_tag=dest_tag[j]`、`src_ready=0`；
  对应 `old_tag` 也指向 lane j 的 dest；
- x0 作源恒为 `tag=0, ready=1`，不参与 RAT 分配；
- 同拍 commit 释放的 tag 不在本拍分配中使用（下一拍才可见），与 RTL 的
  `free_vec` 更新时序一致。

## 4. 测试分组

| 组 | 内容 |
| --- | --- |
| 定向 | 首次写、读 busy 源、wake、commit 更新/释放、非架构写、空闲表耗尽与恢复 |
| 恢复 | `recover_free_mask`/`recover_busy_mask` 装载、`rat<=crat`、恢复后分配 |
| W=2 | 组内 x5 依赖、两条写同一 rd 的 old_tag |
| 随机 | 20 万拍随机 uop/commit/wake/out_ready，逐拍与独立参考模型比较 dest/src/old/lsq/in_ready |

完整运行输出：

```text
rename_tb: W=1 checked=200072 fails=0
PASS
rename_tb: W=2 checked=200074 fails=0
PASS
```

## 5. 当前状态

- W=1 / W=2 完整随机对拍通过；
- Yosys `proc; opt; check` 0 problems；
- 尚未登记进 `filelist.f`，基线 `make build` 不受影响。
