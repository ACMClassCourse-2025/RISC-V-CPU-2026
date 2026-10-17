# 甲的工作日志（P0/P1 前端与提交线）

> 记录人：甲（前端/提交线）。日期：2026-10-18。
> 详细交接状态见本地 `prompt.md` 第 11 节（不提交）。

## 已完成

- P0：`pc_unit`、BTB + 2-bit BHT BPU、`cpu_config`/`if_defs` 参数与接口宏。
- P1：流水线 I-Cache、`rename`（W=1/2）、ROB + commit + 精确恢复、
  `frontend_ooo` + `stub_exec` 前端子系统、`core_ooo` 薄封装。
- 额外：一键参数矩阵 `test/run_all.sh`；gshare 预测器预研；W=2 双 slot
  前端（I-Cache 仍单宽取指）。

## 验证

| 测试 | 覆盖 | 状态 |
| --- | --- | --- |
| `pc_unit_test` | 复位/优先级/回绕/10 万拍随机 | PASS |
| `bpu_test` | BTB+BHT、同拍旁路、准确率 | PASS |
| `icache_pipe_test` | 吞吐/回填/反压/flush/随机 | PASS |
| `rename_test` | W=1/2、RAT/空闲表/恢复 | PASS |
| `rob_test` | 提交/恢复/重复完成/迟到事件 | PASS |
| `frontend_test` | 直线 + 分支误预测，W=1/2 | PASS |
| `bpu_gshare_test` | gshare 对拍 + 准确率 | PASS |
| `core_skeleton_test` | Verilator lint + Yosys check | PASS |

`test/run_all.sh` 覆盖上述测试及 W/PRF/ROB/BPU/I-Cache 参数档，当前全 PASS。
基线 `make build` 保持通过。

## P2 预研结论

- gshare 在相关分支流上接近 100%，但单分支 9T/1N 低于普通 2-bit BHT；
  正式接入需在 ROB 保存预测时的 GHR 快照，并扩展 `is_call/is_return` 后再做
  RAS。
- W=2 已完成 rename/ROB/双 slot 前端；真正双宽取指需要双 bank 或多字行
  I-Cache，尚未实现。

## 阻塞 / 下一步

- 真实功能/性能验收依赖乙的 PRF/IQ/CDB/LSU/LSQ/D-Cache/mem_subsystem；
- 下一步：W=2 I-Cache 取指、gshare 的 GHR 快照接口、SVA 压力用例；
- `filelist.f` 尚未加入新模块，基线 `core.sv/student_top` 未切换。
