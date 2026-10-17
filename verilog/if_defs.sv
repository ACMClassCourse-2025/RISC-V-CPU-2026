// -----------------------------------------------------------------------------
// if_defs.sv — 前端/后端跨接缝总线与字段切片宏
//
// 本文件必须在 cpu_config.sv 之后、所有使用跨接缝总线的模块之前。所有位宽
// 由 cpu_config.sv 的参数推导；字段偏移与 docs/interface.md 的表格一一对应。
//
// 约定：
//   - 所有 bundle 是扁平 logic，lane i 位于 [i*BUS_W +: BUS_W]，lane 0 最老；
//   - 字段从 lane 低位按 interface.md 的表序打包；
//   - 总线宽度已经包含 CPU_ISSUE_WIDTH 路（dispatch/complete/commit），
//     单路宽度用 *_W；CDB 宽度用 CPU_CDB_BUS_W。
//   - Yosys 0.63 不支持 package/struct，禁止在端口里使用 struct。
// -----------------------------------------------------------------------------

`ifndef CPU_IF_DEFS_VH
`define CPU_IF_DEFS_VH

// ---- 短别名（只在本文件内使用，避免污染全局） ------------------------------
`define CPU_PRFD `CPU_PRF_IDX_W
`define CPU_LSQD `CPU_LSQ_IDX_W
`define CPU_ROBD `CPU_ROB_TAG_W
`define CPU_WD   `CPU_ISSUE_WIDTH

// ---- dispatch[W]（甲 → 乙）-------------------------------------------------
`define CPU_DISPATCH_W       (124 + 3*`CPU_PRFD + `CPU_LSQD + `CPU_ROBD)
`define CPU_DISPATCH_BUS_W   (`CPU_WD * `CPU_DISPATCH_W)
`define CPU_DISPATCH_LANE(i) ((i) * `CPU_DISPATCH_W)

`define CPU_DISPATCH_VALID_OFF        0
`define CPU_DISPATCH_PC_OFF           1
`define CPU_DISPATCH_INST_OFF         33
`define CPU_DISPATCH_IMM_OFF          65
`define CPU_DISPATCH_RD_OFF           97
`define CPU_DISPATCH_REG_WE_OFF       102
`define CPU_DISPATCH_ALU_OP_OFF       103
`define CPU_DISPATCH_A_SEL_OFF        108
`define CPU_DISPATCH_B_SEL_OFF        110
`define CPU_DISPATCH_WB_SEL_OFF       111
`define CPU_DISPATCH_IS_BRANCH_OFF    113
`define CPU_DISPATCH_IS_JAL_OFF       114
`define CPU_DISPATCH_IS_JALR_OFF      115
`define CPU_DISPATCH_IS_LOAD_OFF      116
`define CPU_DISPATCH_IS_STORE_OFF     117
`define CPU_DISPATCH_ILLEGAL_OFF      118
`define CPU_DISPATCH_MEM_SIZE_OFF     119
`define CPU_DISPATCH_MEM_UNSIGNED_OFF 121
`define CPU_DISPATCH_DEST_TAG_OFF     (122)
`define CPU_DISPATCH_SRC1_TAG_OFF     (122 + `CPU_PRFD)
`define CPU_DISPATCH_SRC1_READY_OFF   (122 + 2*`CPU_PRFD)
`define CPU_DISPATCH_SRC2_TAG_OFF     (123 + 2*`CPU_PRFD)
`define CPU_DISPATCH_SRC2_READY_OFF   (123 + 3*`CPU_PRFD)
`define CPU_DISPATCH_LSQ_ID_OFF       (124 + 3*`CPU_PRFD)
`define CPU_DISPATCH_ROB_IDX_OFF      (124 + 3*`CPU_PRFD + `CPU_LSQD)

// ---- cdb[R]（乙 → 甲 + 乙内部）---------------------------------------------
`define CPU_CDB_W        (34 + `CPU_PRFD)
`define CPU_CDB_BUS_W    (`CPU_CDB_NUM * `CPU_CDB_W)
`define CPU_CDB_LANE(i)  ((i) * `CPU_CDB_W)

`define CPU_CDB_VALID_OFF      0
`define CPU_CDB_TAG_OFF        1
`define CPU_CDB_VALUE_OFF      (1 + `CPU_PRFD)
`define CPU_CDB_EXCEPTION_OFF  (33 + `CPU_PRFD)

// ---- complete[W]（乙 → 甲）-------------------------------------------------
`define CPU_COMPLETE_W       (2 + `CPU_PRFD)
`define CPU_COMPLETE_BUS_W   (`CPU_WD * `CPU_COMPLETE_W)
`define CPU_COMPLETE_LANE(i) ((i) * `CPU_COMPLETE_W)

`define CPU_COMPLETE_VALID_OFF      0
`define CPU_COMPLETE_TAG_OFF        1
`define CPU_COMPLETE_EXCEPTION_OFF  (1 + `CPU_PRFD)

// ---- commit[W]（甲 → 乙）---------------------------------------------------
`define CPU_COMMIT_W       (3 + `CPU_PRFD + `CPU_LSQD)
`define CPU_COMMIT_BUS_W   (`CPU_WD * `CPU_COMMIT_W)
`define CPU_COMMIT_LANE(i) ((i) * `CPU_COMMIT_W)

`define CPU_COMMIT_VALID_OFF     0
`define CPU_COMMIT_TAG_OFF       1
`define CPU_COMMIT_IS_STORE_OFF  (1 + `CPU_PRFD)
`define CPU_COMMIT_IS_LOAD_OFF   (2 + `CPU_PRFD)
`define CPU_COMMIT_LSQ_ID_OFF    (3 + `CPU_PRFD)

// ---- br_update（乙 → 甲）---------------------------------------------------
`define CPU_BR_UPDATE_W        (67 + `CPU_PRFD)
`define CPU_BR_VALID_OFF       0
`define CPU_BR_PC_OFF          1
`define CPU_BR_TAKEN_OFF       33
`define CPU_BR_TARGET_OFF      34
`define CPU_BR_IS_JALR_OFF     66
`define CPU_BR_TAG_OFF         (67)

// ---- squash（甲 → 乙）------------------------------------------------------
`define CPU_SQUASH_W        (1 + `CPU_ROBD)
`define CPU_SQUASH_VALID_OFF 0
`define CPU_SQUASH_ROB_IDX_OFF 1

// ---- if_refill（甲 ↔ mem_subsystem）---------------------------------------
`define CPU_IF_REQ_W        33
`define CPU_IF_REQ_VALID_OFF 0
`define CPU_IF_REQ_ADDR_OFF  1
`define CPU_IF_RESP_W        33
`define CPU_IF_RESP_VALID_OFF 0
`define CPU_IF_RESP_RDATA_OFF 1

// ---- data_mem（乙 ↔ mem_subsystem）----------------------------------------
`define CPU_DATA_REQ_W        70
`define CPU_DATA_REQ_VALID_OFF 0
`define CPU_DATA_REQ_WE_OFF    1
`define CPU_DATA_REQ_ADDR_OFF  2
`define CPU_DATA_REQ_WDATA_OFF 34
`define CPU_DATA_REQ_WSTRB_OFF 66
`define CPU_DATA_RESP_W        33
`define CPU_DATA_RESP_VALID_OFF 0
`define CPU_DATA_RESP_RDATA_OFF 1

// 短别名保留：字段宏在展开时才引用它们，不能 undef。

`endif
