# 接口规定

- 甲（前端/提交线）：取指、译码、BPU、rename、ROB、commit
- 乙（执行/存储线）：PRF、Issue Queue、CDB、ALU/divider、LSU/LSQ、D-Cache、mem_subsystem
- 参数：`verilog/cpu_config.sv`（由 `tools/config_gen.py` 生成）
- 字段切片宏：`verilog/if_defs.sv`（P1 创建，排在 `cpu_config.sv` 之后）；本文档表格是唯一依据，禁止手写偏移

## 约定

1. 所有 bundle 为扁平 `logic [N-1:0]`，字段从低位按表序打包；多路时 lane i 位于 `[i*BUS_W +: BUS_W]`，lane 0 最老。
2. tag = 物理寄存器号（`CPU_PRF_IDX_W`）：每条 uop 都分配唯一 `dest_preg`（含 `reg_we=0`）作为唯一标识；`PRF[0]` 恒 0 不分配，x0 作源时 `tag=0, ready=1`。同拍 lane 间依赖（lane 1 读 lane 0 的结果）用 `src_ready=0` + tag 指向对方 `dest_tag` 表达，由 CDB 唤醒，不做同拍旁路。
3. `dispatch`/`commit` 的 valid 前缀有效（lane i 有效 ⇒ 更低 lane 全有效）：`backend_ready=1` 时 dispatch 整体吸收，commit 按序逐 lane 吸收；`complete` 的 lane 相互独立（乱序完成，无前缀要求）。
4. 采样语义"本拍末有效、次拍消费"。预测失败的恢复：甲收到 `br_update` 后与保存的预测比较，自行冲刷前端并切 PC；后端中错误路径的 uop 由 `squash` 清除。
5. 反压：
   - `dispatch`：`backend_ready=1` 时乙吸收全部有效 lane；`=0` 时甲冻结 lane、IF/ID 与取指，保持到其恢复为 1 的下一拍。电平信号，不得脉冲丢失，复位后为 1。
   - 其余总线无 ready：`commit`/`cdb`/`complete`/`br_update`/`squash` 接收方每拍吸收；`if_refill`/`data_mem` 单未完成事务，请求保持到响应。

## 总线总览

| 总线 | 方向 | 单路宽度 | 打包后宽度（默认 W=1, R=1） |
| --- | --- | ---: | ---: |
| `dispatch[W]` | 甲 → 乙 | `124 + 3·PRF + LSQ + ROB` | W×150 |
| `cdb[R]` | 乙 → 甲 | `34 + PRF` | R×40 |
| `complete[W]` | 乙 → 甲 | `2 + PRF` | W×8 |
| `commit[W]` | 甲 → 乙 | `3 + PRF + LSQ` | W×12 |
| `br_update` | 乙 → 甲 | `67 + PRF` | 73 |
| `squash` | 甲 → 乙 | `1 + ROB` | 6 |
| `if_refill` | 甲 ↔ mem_subsystem | 请求 33 + 响应 33 | 66 |
| `data_mem` | 乙 ↔ mem_subsystem | 请求 70 + 响应 33 | 103 |
| `backend_ready` | 乙 → 甲 | 1 | 1 |

W = `CPU_ISSUE_WIDTH`（发射宽度，每拍可同时 dispatch/commit/complete 的 uop 数，默认 1）；

R = `CPU_CDB_NUM`（CDB 条数，默认 1）；

PRF = `CPU_PRF_IDX_W`（默认 6），LSQ = `CPU_LSQ_IDX_W`（默认 3），ROB = `CPU_ROB_TAG_W`（默认 5）。

各总线字段表见下文。

## 参数（默认 bring-up）

| 宏 | 默认 | 说明 |
| --- | ---: | --- |
| `CPU_ISSUE_WIDTH`（W） | 1 | dispatch/commit/complete 路数 |
| `CPU_CDB_NUM`（R） | 1 | CDB 条数 |
| `CPU_ROB_DEPTH` | 32 | ROB 深度；`CPU_ROB_TAG_W = $clog2(CPU_ROB_DEPTH)`（也用于跨接缝的 `rob_idx`） |
| `CPU_PRF_SIZE` | 64 | 物理寄存器数，任意整数 4..4096（验收含 96）；`CPU_PRF_IDX_W = $clog2(CPU_PRF_SIZE)` |
| `CPU_RS_DEPTH` | 8 | 每个发射队列深度；`CPU_RS_IDX_W = $clog2(CPU_RS_DEPTH)` |
| `CPU_LSQ_DEPTH` | 8 | LSQ 深度；`CPU_LSQ_IDX_W = $clog2(CPU_LSQ_DEPTH)` |
| `CPU_ICACHE_*` / `CPU_DCACHE_*` | 10/1/4 | index bits / ways / line bytes |
| `CPU_BTB_INDEX_BITS` / `CPU_BHT_INDEX_BITS` | 6 / 8 | BPU 项数 = 2^index_bits（BTB 64 项 / BHT 256 项） |

以下偏移列中 `PRF` = `CPU_PRF_IDX_W`（默认 6），`LSQ` = `CPU_LSQ_IDX_W`（默认 3），`ROB` = `CPU_ROB_TAG_W`（默认 5）。

## dispatch[W]（甲 → 乙）

| 字段 | 位宽 | 偏移 | 说明 |
| --- | ---: | ---: | --- |
| `valid` | 1 | 0 | |
| `pc` | 32 | 1 | |
| `inst` | 32 | 33 | 原始指令（调试/异常） |
| `imm` | 32 | 65 | |
| `rd` | 5 | 97 | 提交时更新 RAT |
| `reg_we` | 1 | 102 | |
| `alu_op` | 5 | 103 | `rv32_defs.sv` 编码（含 M） |
| `a_sel` | 2 | 108 | |
| `b_sel` | 1 | 110 | |
| `wb_sel` | 2 | 111 | |
| `is_branch` | 1 | 113 | |
| `is_jal` | 1 | 114 | |
| `is_jalr` | 1 | 115 | |
| `is_load` | 1 | 116 | |
| `is_store` | 1 | 117 | |
| `illegal` | 1 | 118 | 提交时停机（P1） |
| `mem_size` | 2 | 119 | |
| `mem_unsigned` | 1 | 121 | |
| `dest_tag` | PRF (6) | 122 | 唯一 tag |
| `src1_tag` | PRF (6) | 122+PRF | |
| `src1_ready` | 1 | 122+2·PRF | |
| `src2_tag` | PRF (6) | 123+2·PRF | |
| `src2_ready` | 1 | 123+3·PRF | |
| `lsq_id` | LSQ (3) | 124+3·PRF | 非访存 don't-care |
| `rob_idx` | ROB (5) | 124+3·PRF+LSQ | 该 uop 的 ROB 分配序号（按程序序、在飞唯一），用于恢复排序 |

总宽 `CPU_DISPATCH_W = 124 + 3·PRF + LSQ + ROB`（默认 150）。

`lsq_id` 由前端在 rename 时分配（循环计数器），乙的 LSQ 以其为下标；load 的表项
在 commit 时释放；store 的表项在 commit 时排入写内存，真正写完成前仍占位并计入
`backend_ready` 反压（否则新 dispatch 复用 `lsq_id` 会覆盖未写出的数据）。

## cdb[R]（乙 → 甲 + 乙内部）

| 字段 | 位宽 | 偏移 | 说明 |
| --- | ---: | ---: | --- |
| `valid` | 1 | 0 | |
| `tag` | PRF (6) | 1 | 结果的物理寄存器号 |
| `value` | 32 | 1+PRF | |
| `exception` | 1 | 33+PRF | 与 ROB 完成同拍 |

总宽 `CPU_CDB_W = 34 + PRF`（默认 40）。PRF 写回由乙在 cdb 广播同拍完成；无值结果走
`complete`；多 CDB 仲裁在乙内部，每 lane 一个赢家。

唤醒竞态：`cdb` 广播与 `dispatch` 同拍时，乙必须在把 dispatch uop 写入 IQ 的
同拍用本拍 `cdb` 做旁路比较（`src_tag` 命中即直接置就绪）；甲保证更早完成的
结果在 dispatch 时 `src_ready` 已为 1。否则消费者会等待一个永不重发的广播，
导致死锁。

## complete[W]（乙 → 甲）

| 字段 | 位宽 | 偏移 | 说明 |
| --- | ---: | ---: | --- |
| `valid` | 1 | 0 | |
| `tag` | PRF (6) | 1 | 完成 uop 的 dest_tag |
| `exception` | 1 | 1+PRF | |

总宽 `CPU_COMPLETE_W = 2 + PRF`（默认 8）。用于不产生 CDB 值的 uop；
同一条 uop 只允许 `cdb`/`complete` 二选一。

## commit[W]（甲 → 乙）

| 字段 | 位宽 | 偏移 | 说明 |
| --- | ---: | ---: | --- |
| `valid` | 1 | 0 | 按序提交窗口 |
| `tag` | PRF (6) | 1 | 提交 uop 的 dest_tag |
| `is_store` | 1 | 1+PRF | |
| `is_load` | 1 | 2+PRF | |
| `lsq_id` | LSQ (3) | 3+PRF | 该 uop 的 LSQ 表项（load/store） |

总宽 `CPU_COMMIT_W = 3 + PRF + LSQ`（默认 12）。语义：`is_store=1` 把该 store
排入写内存，排空前其 LSQ 表项保持占用（见 dispatch 小节）；`is_load=1` 直接
释放 LSQ 表项；两者都为 0 则忽略 `lsq_id`。提交前 store 不得写内存。

## br_update（乙 → 甲）

| 字段 | 位宽 | 偏移 | 说明 |
| --- | ---: | ---: | --- |
| `valid` | 1 | 0 | |
| `pc` | 32 | 1 | |
| `taken` | 1 | 33 | 真实方向 |
| `target` | 32 | 34 | 真实目标 |
| `is_jalr` | 1 | 66 | 供 RAS 备用 |
| `tag` | PRF (6) | 67 | 该分支 uop 的 dest_tag，用于 ROB 精确定位 |

总宽 `CPU_BR_UPDATE_W = 67 + PRF`（默认 73）。每条解析完成的分支/跳转都发
一条；甲据此更新 BPU，并用 `tag` 在 ROB 中精确定位该表项（同一 PC 可能有多
条在飞，如循环），与保存的预测比较：不一致（含未预测的跳转）时由甲自行冲刷
并切 PC，无需乙判定。每拍最多一条；同拍多条解析完成时由乙内部排队、择机发出
（BPU 更新与恢复不在关键路径上）。`tag` 已不在 ROB（被更老的恢复冲刷）时忽略
本条；BPU 更新是否照常由实现决定。

精确恢复前提：**分支/跳转在甲收到其 `br_update` 之前不得提交**（`cdb`/
`complete` 提前到达无害，只标记 done、不改变这条约束）；乙必须保证每条
`br_update` 最终送达、不丢失/不覆盖（队列满时自行反压分支执行）。否则预测
失败会在分支提交之后才被发现，错误路径的年轻指令可能已被退休。

## squash（甲 → 乙）

| 字段 | 位宽 | 偏移 | 说明 |
| --- | ---: | ---: | --- |
| `valid` | 1 | 0 | |
| `rob_idx` | ROB (5) | 1 | 保留该序号及更老，丢弃更年轻的 |

总宽 `CPU_SQUASH_W = 1 + ROB`（默认 6）。甲在 `br_update` 比对失败时发出；
乙丢弃所有比 `rob_idx` 更年轻的在飞 uop（按 dispatch 顺序判定），释放其
IQ/LSQ 资源，并保证它们不再广播 `cdb`/`complete`；更老的 uop 不受影响。
每拍最多一条；与 dispatch 同拍时 squash 优先（先清后收），乙以本条 `rob_idx`
重置用于排序比较的基准。

## if_refill（甲 ↔ mem_subsystem）

| 方向 | 字段 | 位宽 | 偏移 |
| --- | --- | ---: | ---: |
| 请求 | `valid` | 1 | 0 |
| | `addr` | 32 | 1 |
| 响应 | `valid` | 1 | 0 |
| | `rdata` | 32 | 1 |

总宽 33 / 33。I-Cache 缺失时发起；响应 1 拍脉冲。P1 行宽 = 4B；行宽 >4B 时的
多拍/burst 方案在 P2 走 M5 扩展。

## data_mem（乙 ↔ mem_subsystem）

| 方向 | 字段 | 位宽 | 偏移 |
| --- | --- | ---: | ---: |
| 请求 | `valid` | 1 | 0 |
| | `we` | 1 | 1 |
| | `addr` | 32 | 2 |
| | `wdata` | 32 | 34 |
| | `wstrb` | 4 | 66 |
| 响应 | `valid` | 1 | 0 |
| | `rdata` | 32 | 1 |

总宽 70 / 33。store 响应表示已受理；与 `if_refill` 的仲裁在 mem_subsystem
内部，对甲透明。

## backend_ready（乙 → 甲）

1 位电平信号。`1` = 后端本拍可吸收全部有效 lane；`0` = 前端冻结 lane、IF/ID
与取指，保持到其恢复为 1 的下一拍。不得脉冲丢失，复位后为 1。

## Stub（P1 起）

Stub 是接口与真实模块完全一致、行为简化/脚本化的假模块：对方 RTL 没写完
时，用它替换对方那一侧，自己就能编译并跑单元测试（M3 机制）。

规则：

- 端口、时序、字段切片宏必须与真实模块一致（都取自 `if_defs.sv`），否则集成
  时对不上；
- 不要求功能正确，只按协议制造延迟、反压、异常、分支误预测等边界场景；
- 绝不进 `filelist.f`，只出现在单元测试里；
- 集成窗口按 M4 逐边替换：真前端 + stub 后端 → stub 前端 + 真后端 → 全真。

| stub | 主人 | 给谁用 | 行为 |
| --- | --- | --- | --- |
| `stub_exec.sv` | 甲 | 甲测前端/ROB | 收 `dispatch[W]`/`squash`/`commit[W]`，随机延迟回 `cdb[R]`/`complete[W]`（被 squash 的 uop 不再回），可造异常；按脚本发 `br_update`、驱动 `backend_ready`（可拉低测反压） |
| `stub_front_ooo.sv` | 乙 | 乙测后端 | 按脚本发 `dispatch[W]`/`squash`/`commit[W]`；收 `cdb`/`complete`/`br_update`；收 `backend_ready`（低时冻结发送） |
| `stub_mem.sv` | 乙 | 乙测访存 | 对 `if_refill`/`data_mem` 固定延迟响应，可注入错误 |

## 决策记录

1. tag 方案：唯一 `dest_preg`（每条 uop 分配，含 `reg_we=0`）；不采用 `cdb` 带 `rob_id`。
2. `cdb`/`complete` 分工：有值走 `cdb`，无值（store/branch 等）走 `complete`；同一条 uop 只发一种。
3. 参数：接受 `CPU_CDB_NUM=1`、`CPU_LSQ_DEPTH=8`（`config_gen.py` 可调）。
4. `commit` 字段：`valid/tag/is_store/is_load/lsq_id`（新增 `is_load` 用于 load 释放）；暂不补 `pc`/`exception`。
5. `br_update` 字段：`valid/pc/taken/target/is_jalr/tag`（新增 `tag` 用于 ROB 精确定位）；`is_call`/`is_return` 等 P2 升级预测时再加。
6. W 路规则：`dispatch`/`commit` 前缀有效；dispatch 由 `backend_ready` 整体吸收，commit 按序逐 lane；`complete` 的 lane 相互独立（乱序完成）。
7. `data_mem`：不补 `size`（`wstrb` 足够；该总线两端均属乙）。
8. `illegal`：P1 提交时停机；P3 需要精确异常时再引入状态位。
9. 分支恢复：删除 `redirect` 总线；乙对所有分支/跳转发 `br_update`（含 `tag`），甲基于 ROB 中保存的预测自行判定，并向后端发 `squash`。
10. 后端恢复：`dispatch` 增加 `rob_idx`（ROB 分配序号）；新增 `squash`（甲→乙，`valid + rob_idx`）用于丢弃错误路径的在飞 uop。
11. 精确恢复前提：分支/跳转在甲收到 `br_update` 前不得提交；乙保证 `br_update` 不丢失（队列满时自行反压）。

