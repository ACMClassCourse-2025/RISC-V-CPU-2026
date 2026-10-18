# P0 接口复核记录（乙侧）

日期：2026-10-18  
复核人：乙  
甲侧签字：⬜ 待补

本文档记录乙对 `docs/interface.md` 冻结接口的逐条复核结果。字段偏移的
唯一实现来源是 `verilog/if_defs.sv`；默认参数由 `tools/config_gen.py --check`
确认与 `verilog/cpu_config.sv` 一致。

## 1. 八条跨接缝总线

默认参数：`W=1`、`R=1`、`PRF=6`、`LSQ=3`、`ROB=5`。

| 总线 | 方向 | 单 lane 宽度 | 默认打包宽度 | 乙侧复核 |
| --- | --- | ---: | ---: | --- |
| `dispatch[W]` | 甲 → 乙 | 150 | 150 | ✅ 字段偏移与 `if_defs.sv` 一致 |
| `cdb[R]` | 乙 → 甲/乙 | 40 | 40 | ✅ tag/value/exception 布局一致 |
| `complete[W]` | 乙 → 甲 | 8 | 8 | ✅ 无值完成走此总线 |
| `commit[W]` | 甲 → 乙 | 12 | 12 | ✅ tag/is_store/is_load/lsq_id |
| `br_update` | 乙 → 甲 | 73 | 73 | ✅ pc/taken/target/is_jalr/tag |
| `squash` | 甲 → 乙 | 6 | 6 | ✅ valid + rob_idx |
| `if_refill` | 甲 ↔ mem_subsystem | 33 / 33 | 33 / 33 | ✅ 单未完成事务 |
| `data_mem` | 乙 ↔ mem_subsystem | 70 / 33 | 70 / 33 | ✅ we/addr/wdata/wstrb + rdata |
| `backend_ready` | 乙 → 甲 | 1 | 1 | ✅ 电平，复位后为 1 |

验证命令与结果：

```text
python3 tools/config_gen.py --check
  -> cpu_config.sv is up to date

sh test/if_defs_test/run.sh
  -> if_defs_tb: W=1 PRF=64 CDB=1 ROB=32 LSQ=8 checked=22 fails=0 PASS
```

## 2. 关键语义确认（乙侧实现依据）

- `dispatch` 在 `backend_ready=1` 时整体吸收全部有效 lane；`=0` 时前端冻结，
  后端不得只吸收一部分。
- 每条 uop 都有唯一 `dest_tag`，包括 `reg_we=0`；x0 固定 tag 0、ready 1。
- `cdb` 与 `complete` 二选一；有值走 `cdb`，无值（store/branch 等）走
  `complete`。
- `dispatch` 写入 IQ 的同拍必须用本拍 `cdb` 做旁路唤醒，否则会漏唤醒死锁。
- `squash` 按 `rob_idx` 丢弃更年轻的在飞 uop，且与 dispatch 同拍时 squash
  优先；被 squash 的 uop 不得再广播 `cdb`/`complete`。
- store 只在 `commit` 后写内存；未排空表项仍占 `lsq_id` 并计入
  `backend_ready`。
- 分支/跳转在甲收到 `br_update` 前不得提交；乙保证 `br_update` 不丢失。
- `backend_ready` 是电平信号，不能脉冲丢失；复位后为 1。

## 3. divider 内部接口

`divider.sv` 的 `start/busy/done` 与 `done` 当拍结果有效已写入
`docs/interface.md`。除零和 `INT_MIN / -1` 边界已修复，`divider_test --quick`
通过。

## 4. P0 交付状态

| 项目 | 状态 |
| --- | --- |
| `divider.sv` + `divider_test` | ✅ |
| `tools/unit/build.py` | ✅ |
| `mem_subsystem.sv` v1 + 单测 | ✅ |
| 黄金模型 + `trace_diff.py` | ✅（19/19 correctness） |
| 接口宽度检查 | ✅（22/22） |
| `make build` 基线 | ✅ |
| 甲侧签字 | ⬜ 待补 |
| `p0-baseline` tag | ✅ 已创建（作为回滚点；甲侧签字后可在记录中补签） |
