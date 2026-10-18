// -----------------------------------------------------------------------------
// student_top_ooo.sv — P1 集成用顶层（模块名仍为 student_top）
//
// 组成：
//   core_ooo     —— 甲：取指/BPU/I-Cache/decode/rename/ROB/commit
//   backend_ooo  —— 乙：PRF/IQ/CDB/ALU/divider/LSU/LSQ
//   mem_subsystem—— 乙：I$ 回填 + 数据访存 + axi_mem_if
//
// 该文件只用于 test/integration/filelist.f；官方 verilog/filelist.f 仍由甲
// 维护，替换 student_top 前双方需确认。
// -----------------------------------------------------------------------------

module student_top (
  input  wire        clock,
  input  wire        reset,

  output wire [31:0] araddr,
  output wire        arvalid,
  input  wire        arready,

  input  wire [31:0] rdata,
  input  wire [1:0]  rresp,
  input  wire        rvalid,
  output wire        rready,

  output wire [31:0] awaddr,
  output wire        awvalid,
  input  wire        awready,

  output wire [31:0] wdata,
  output wire [3:0]  wstrb,
  output wire        wvalid,
  input  wire        wready,

  input  wire [1:0]  bresp,
  input  wire        bvalid,
  output wire        bready
);

  // core_ooo <-> backend_ooo
  logic                    backend_ready;
  logic [`CPU_DISPATCH_BUS_W-1:0] dispatch;
  logic [`CPU_COMMIT_BUS_W-1:0]   commit;
  logic [`CPU_SQUASH_W-1:0]       squash;
  logic [`CPU_CDB_BUS_W-1:0]      cdb;
  logic [`CPU_COMPLETE_BUS_W-1:0] complete;
  logic [`CPU_BR_UPDATE_W-1:0]    br_update;
  logic                    halt;

  // I-Cache refill
  logic        if_refill_valid;
  logic [31:0] if_refill_addr;
  logic        if_refill_resp_valid;
  logic [31:0] if_refill_rdata;

  // data memory
  logic        data_req_valid;
  logic        data_req_we;
  logic [31:0] data_req_addr;
  logic [31:0] data_req_wdata;
  logic [3:0]  data_req_wstrb;
  logic        data_resp_valid;
  logic [31:0] data_resp_rdata;

  core_ooo u_core (
    .clk               (clock),
    .reset             (reset),
    .backend_ready     (backend_ready),
    .cdb               (cdb),
    .complete          (complete),
    .br_update         (br_update),
    .dispatch          (dispatch),
    .commit            (commit),
    .squash            (squash),
    .halt              (halt),
    .refill_valid      (if_refill_valid),
    .refill_addr       (if_refill_addr),
    .refill_resp_valid (if_refill_resp_valid),
    .refill_rdata      (if_refill_rdata)
  );

  backend_ooo u_backend (
    .clk            (clock),
    .reset          (reset),
    .dispatch       (dispatch),
    .commit         (commit),
    .squash         (squash),
    .cdb            (cdb),
    .complete       (complete),
    .br_update      (br_update),
    .backend_ready  (backend_ready),
    .data_req_valid (data_req_valid),
    .data_req_we    (data_req_we),
    .data_req_addr  (data_req_addr),
    .data_req_wdata (data_req_wdata),
    .data_req_wstrb (data_req_wstrb),
    .data_resp_valid(data_resp_valid),
    .data_resp_rdata(data_resp_rdata)
  );

  mem_subsystem u_mem (
    .clk             (clock),
    .reset           (reset),
    .if_req_valid    (if_refill_valid),
    .if_req_addr     (if_refill_addr),
    .if_resp_valid   (if_refill_resp_valid),
    .if_resp_rdata   (if_refill_rdata),
    .data_req_valid  (data_req_valid),
    .data_req_we     (data_req_we),
    .data_req_addr   (data_req_addr),
    .data_req_wdata  (data_req_wdata),
    .data_req_wstrb  (data_req_wstrb),
    .data_resp_valid (data_resp_valid),
    .data_resp_rdata (data_resp_rdata),
    .araddr          (araddr),
    .arvalid         (arvalid),
    .arready         (arready),
    .rdata           (rdata),
    .rresp           (rresp),
    .rvalid          (rvalid),
    .rready          (rready),
    .awaddr          (awaddr),
    .awvalid         (awvalid),
    .awready         (awready),
    .wdata           (wdata),
    .wstrb           (wstrb),
    .wvalid          (wvalid),
    .wready          (wready),
    .bresp           (bresp),
    .bvalid          (bvalid),
    .bready          (bready)
  );

endmodule
