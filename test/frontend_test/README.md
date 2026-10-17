# frontend_test — 前端子系统级联测试

把 `frontend_ooo + rename + rob + stub_exec` 接成一条完整的前端/提交链：

```
pc_unit -> icache_pipe -> decoder -> rename -> rob
                              |                 |
                              +-> bpu           +-> commit / redirect / recover
                                                  |
                                              stub_exec (cdb/complete/br_update)
```

```
test/frontend_test/
├── run.sh
├── frontend_subsystem.sv  # 联测顶层（stub/TB 不进 filelist）
├── frontend_tb.cpp        # C++ 指令内存 + 提交/重定向检查
└── README.md
```

## 1. 怎么跑

```sh
sh test/frontend_test/run.sh
FRONTEND_W=2 sh test/frontend_test/run.sh   # 接口预留，当前只取 lane0
```

输出示例：

```text
straight: commits=8 cycles=51 fails=0
branch: redirect=1 pc=00000020 branch_commit=1 target_commit=1 cycles=41 fails=0
frontend_tb: PASS
```

## 2. 测试内容

1. **直线程序**：内存中放 NOP、`addi`、`add`、`sw` 等 8 条指令；检查提交
   顺序、PC、指令编码；中途拉高 `force_stall` 10 拍，确认恢复后继续提交。
2. **分支误预测**：`beq x0,x0,+16` 在 `0x10`，stub 脚本化 `br_update`
   taken/target=0x20；ROB 检测预测错误，产生 `redirect_valid`，
   前端从 `0x20` 继续取指；检查分支与目标指令都提交。

C++ TB 负责 `refill_valid/refill_addr` 的指令内存响应：收到请求后一拍返回
`mem_word(addr)`，未定义地址返回 NOP。

## 3. 模块连接约定

- `frontend_ooo` 输出 decoded uop（`CPU_DECODE_W`，含 rs1/rs2）；
- `rename` 输出 renamed uop（`CPU_RENAME_W`，不含 rob_idx）与 `old_tag`；
- `rob` 分配 `alloc_rob_idx`，并把 commit/recover 反馈给 rename；
- `stub_exec` 从 rename 输出取 dispatch（tag/pc/控制位/reg_we），
  从 ROB 取 `rob_idx`；按 tag 派生不同延迟，乱序返回 cdb/complete；
- `backend_ready = stub 空间 && ROB 空间`；rename 的 `out_ready` 同时看两者；
- 分支同时发 `complete`（置 done）与 `br_update`（解析方向），
  ROB 收到 `br_update` 后才允许提交该分支。

## 4. 限制

- W=2 使用 2 个 decoded-uop slot 成组送给 rename/ROB，但 I-Cache 仍每拍只
  取一条；真正的双宽取指（双 bank/多字行）留到后续 P2；
- `stub_exec` 不实现真实执行语义，`force_taken/force_target` 由 TB 脚本控制；
- `squash` 只做保守的 rob_idx 距离判断，真实后端由乙实现；
- 该测试验证的是接口/控制流，不验证 RV32IM 数据通路正确性。

## 5. 当前状态

- 直线 + 分支误预测两级 smoke 通过；
- 尚未进入 `filelist.f`，不影响基线 `make build`。
