# P1 集成状态（乙侧，2026-10-18）

## 已完成

- P0：`divider` 边界修复、`tools/unit/build.py`、`mem_subsystem` v1、
  黄金模型/`trace_diff`、接口复核、`p0-baseline` tag。
- P1 后端：`prf.sv`、`cdb.sv`、`issue_queue.sv`、`lsu.sv`、`lsq.sv`、
  `backend_ooo.sv`，以及对应 W=1/W=2 单测。
- 集成顶层：`verilog/student_top_ooo.sv`（模块名 `student_top`，仅用于
  `test/integration/filelist.f`；官方 `verilog/filelist.f` 未改）。

## 当前集成结果

```sh
sh test/integration/run_smoke.sh correctness_add_to_100 200000
```

结果：**FAIL / timeout**。当前提交轨迹在第 16 条指令（最后提交 PC `0x54`）
后停止，ROB 填满 32 项，IQ 仍有 4 项且 `out_valid=0`，CDB 无有效结果。
`correctness_add_to_100` 的黄金轨迹共 421 条；前 16 条与黄金模型一致。

## 已定位并修复的甲侧问题

### 1. ROB 恢复时丢失在飞 RAT 映射

`rename.sv` 原来在 `recover_valid` 时直接 `rat <= crat`，只恢复已提交映射。
JALR 写 `ra` 后若发生误预测恢复，branch 自身及更老在飞 uop 的 rd 映射会丢失，
重新取指的 `jalr zero,0(ra)` 读到旧物理寄存器，PC 跑飞。

修复：

- `rob.sv` 新增 `recover_rat[32*PW]`：从 `crat` 出发，按程序序重放
  `branch` 及更老的有效表项（`entry_rd/dest_tag/reg_we`）。
- `rename.sv` 恢复时使用 `recover_rat`，不再只用 `crat`。
- `core_ooo.sv` 增加连接；`test/rename_test` 增加 `recover_rat` 驱动。

回归：`rename_test` W=1/W=2、`rob_test` W=1/W=2 全 PASS。

### 2. BPU 预测 taken 但没有驱动 PC

`frontend_ooo.sv` 原来只把 `bpu_taken/bpu_target` 存进 slot 给 ROB 比较，
PC 仍顺序 `+4`。预测 taken 时前端会取 fall-through，但 ROB 认为预测匹配，
可能提交错误路径。

修复：当一条 branch/jal/jalr 被接收且 `bpu_taken=1` 时：

- 下一拍 PC 切到 `bpu_target`；
- flush I-Cache 丢弃顺序路径；
- 不清除已接收的分支 slot。

回归：`frontend_test` W=1/W=2、`core_skeleton_test` 全 PASS。

### 3. 已发射结果在 squash 后仍广播

接口文档要求被 squash 的 uop 不得再广播 `cdb/complete`。原后端 ALU/divider
结果缓冲、branch complete、store complete 没有 rob_idx 过滤。

修复：

- ALU/divider/branch-complete/store-complete 结果缓冲增加 `rob_idx`；
- `squash_valid` 时丢弃更年轻的已发射结果；
- 仍在运行的 divider 标记 discard，done 后不广播。

回归：`backend_test` W=1/W=2、`lsu_test` 全 PASS。

## 仍未解决的问题

在上述修复之后，`correctness_add_to_100` 仍在 `0x54` 后死锁。可复现观察：

- 最后提交：`0x54`（黄金轨迹前 16 条完全一致）；
- ROB：head=16、count=32、`in_ready=0`，head 项 `0x58 addi a5,a5,1`
  `done=0`；
- IQ：`count=4`、`out_valid=0`，即剩余表项都不 ready；
- CDB：无有效源，`alu_valid_q/div_valid_q/load_result_valid` 均为 0；
- 说明 `0x58` 要么从未进入 IQ，要么被错误的 squash 清掉；其后所有
  uop 依赖它，ROB 填满后死锁。

下一步建议（需要甲一起看前端/squash 语义）：

1. 用 `test/integration/run_smoke.sh correctness_add_to_100 20000` +
   VCD 对齐 `0x58` 的 dispatch/rename/ROB index，确认它是否被
   `squash_rob_idx` 误清。
2. 检查 ROB `flush_young` 与 IQ/LSQ 的 squash 是否对“branch 本身/更老”
   的边界完全一致；ROB depth=32，IQ depth=8，当前使用
   `diff < DEPTH/2` 的模比较。
3. 检查 branch 预测 taken 时 I-Cache flush 与 slot 保留的时序，确认
   重定向后新 uop 的 rob_idx/tag 不复用旧路径表项。
4. 如需彻底消除前端恢复复杂度，可考虑在 P1 bring-up 阶段对每个
   branch/jal/jalr 暂停取指直到 `br_update`，换取正确性后再恢复预测。

## 复现命令

```sh
sh test/integration/run_smoke.sh correctness_add_to_100 20000
```

官方基线仍不受影响：

```sh
make build
sh test/run_all.sh --build
```
