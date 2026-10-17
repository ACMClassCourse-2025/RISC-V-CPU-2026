// -----------------------------------------------------------------------------
// if_defs_check.sv — 把 if_defs.sv 的派生宽度/偏移导出给 C++ 测试台
// -----------------------------------------------------------------------------

module if_defs_check (
  output logic [31:0] dispatch_w,
  output logic [31:0] dispatch_bus_w,
  output logic [31:0] dispatch_lane1,
  output logic [31:0] dispatch_src2_tag_off,
  output logic [31:0] dispatch_lsq_id_off,
  output logic [31:0] dispatch_rob_idx_off,
  output logic [31:0] cdb_w,
  output logic [31:0] cdb_bus_w,
  output logic [31:0] cdb_value_off,
  output logic [31:0] complete_w,
  output logic [31:0] complete_exception_off,
  output logic [31:0] commit_w,
  output logic [31:0] commit_lsq_id_off,
  output logic [31:0] br_update_w,
  output logic [31:0] br_tag_off,
  output logic [31:0] squash_w,
  output logic [31:0] if_req_w,
  output logic [31:0] if_resp_w,
  output logic [31:0] data_req_w,
  output logic [31:0] data_resp_w
);

  assign dispatch_w           = `CPU_DISPATCH_W;
  assign dispatch_bus_w       = `CPU_DISPATCH_BUS_W;
  assign dispatch_lane1       = `CPU_DISPATCH_LANE(1);
  assign dispatch_src2_tag_off = `CPU_DISPATCH_SRC2_TAG_OFF;
  assign dispatch_lsq_id_off  = `CPU_DISPATCH_LSQ_ID_OFF;
  assign dispatch_rob_idx_off = `CPU_DISPATCH_ROB_IDX_OFF;
  assign cdb_w                = `CPU_CDB_W;
  assign cdb_bus_w            = `CPU_CDB_BUS_W;
  assign cdb_value_off        = `CPU_CDB_VALUE_OFF;
  assign complete_w           = `CPU_COMPLETE_W;
  assign complete_exception_off = `CPU_COMPLETE_EXCEPTION_OFF;
  assign commit_w             = `CPU_COMMIT_W;
  assign commit_lsq_id_off    = `CPU_COMMIT_LSQ_ID_OFF;
  assign br_update_w          = `CPU_BR_UPDATE_W;
  assign br_tag_off           = `CPU_BR_TAG_OFF;
  assign squash_w             = `CPU_SQUASH_W;
  assign if_req_w             = `CPU_IF_REQ_W;
  assign if_resp_w            = `CPU_IF_RESP_W;
  assign data_req_w           = `CPU_DATA_REQ_W;
  assign data_resp_w          = `CPU_DATA_RESP_W;

endmodule
