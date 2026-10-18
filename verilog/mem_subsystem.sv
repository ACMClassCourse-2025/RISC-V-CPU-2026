// -----------------------------------------------------------------------------
// mem_subsystem.sv — 存储器子系统 v1
//
// 对上游提供两个互斥的客户口：
//   - if_refill：I-Cache 缺失回填（只读）；
//   - data_mem ：后端 LSU 的 load/store 事务。
// 对下游例化唯一的 AXI4-Lite 主机适配器 axi_mem_if。
//
// P1 策略：
//   - 单事务串行化；busy 时锁存 owner，响应按 owner 路由；
//   - 两客户同时请求时 round-robin 仲裁，避免 I-Cache 被数据流饿死；
//   - 请求方必须保持 valid/addr 直到看到自己的 resp_valid（单未完成事务协议）。
// P2 会在这里加入 D-Cache 与写缓冲，对上游接口保持不变。
// -----------------------------------------------------------------------------

module mem_subsystem (
  input  logic        clk,
  input  logic        reset,

  // I-Cache refill client
  input  logic        if_req_valid,
  input  logic [31:0] if_req_addr,
  output logic        if_resp_valid,
  output logic [31:0] if_resp_rdata,

  // Data memory client (LSU)
  input  logic        data_req_valid,
  input  logic        data_req_we,
  input  logic [31:0] data_req_addr,
  input  logic [31:0] data_req_wdata,
  input  logic [3:0]  data_req_wstrb,
  output logic        data_resp_valid,
  output logic [31:0] data_resp_rdata,

  // AXI4-Lite read address channel
  output logic [31:0] araddr,
  output logic        arvalid,
  input  logic        arready,

  // AXI4-Lite read data channel
  input  logic [31:0] rdata,
  input  logic [1:0]  rresp,
  input  logic        rvalid,
  output logic        rready,

  // AXI4-Lite write address channel
  output logic [31:0] awaddr,
  output logic        awvalid,
  input  logic        awready,

  // AXI4-Lite write data channel
  output logic [31:0] wdata,
  output logic [3:0]  wstrb,
  output logic        wvalid,
  input  logic        wready,

  // AXI4-Lite write response channel
  input  logic [1:0]  bresp,
  input  logic        bvalid,
  output logic        bready
);

  localparam logic OWNER_IF   = 1'b0;
  localparam logic OWNER_DATA = 1'b1;

  logic        busy;
  logic        owner;
  logic        last;       // round-robin: 1 = data was served last

  logic        sel_if;
  logic        sel_data;

  logic        axi_req_valid;
  logic        axi_req_we;
  logic [31:0] axi_req_addr;
  logic [31:0] axi_req_wdata;
  logic [3:0]  axi_req_wstrb;
  logic        axi_resp_valid;
  logic [31:0] axi_resp_rdata;

  // ---- 仲裁 ---------------------------------------------------------------
  // 只在空闲时选择客户；两个同时有效时轮流。
  always_comb begin
    sel_if   = 1'b0;
    sel_data = 1'b0;
    if (!busy) begin
      if (if_req_valid && data_req_valid) begin
        // last=1 means data was served most recently, so serve if next.
        sel_if   =  last;
        sel_data = ~last;
      end else if (if_req_valid) begin
        sel_if = 1'b1;
      end else if (data_req_valid) begin
        sel_data = 1'b1;
      end
    end
  end

  assign axi_req_valid = sel_if | sel_data;
  assign axi_req_we    = sel_data & data_req_we;
  assign axi_req_addr  = sel_if ? if_req_addr : data_req_addr;
  assign axi_req_wdata = data_req_wdata;
  assign axi_req_wstrb = data_req_wstrb;

  // ---- 响应路由 -----------------------------------------------------------
  assign if_resp_valid   = busy && (owner == OWNER_IF)   && axi_resp_valid;
  assign if_resp_rdata   = axi_resp_rdata;
  assign data_resp_valid = busy && (owner == OWNER_DATA) && axi_resp_valid;
  assign data_resp_rdata = axi_resp_rdata;

  // ---- 事务状态 -----------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      busy  <= 1'b0;
      owner <= OWNER_IF;
      last  <= 1'b0;
    end else if (!busy) begin
      if (sel_if | sel_data) begin
        busy  <= 1'b1;
        owner <= sel_data ? OWNER_DATA : OWNER_IF;
        last  <= sel_data;
      end
    end else if (axi_resp_valid) begin
      busy <= 1'b0;
    end
  end

  // ---- AXI 主机适配器 ------------------------------------------------------
  axi_mem_if u_axi (
    .clk        (clk),
    .reset      (reset),
    .req_valid  (axi_req_valid),
    .req_we     (axi_req_we),
    .req_addr   (axi_req_addr),
    .req_wdata  (axi_req_wdata),
    .req_wstrb  (axi_req_wstrb),
    .resp_valid (axi_resp_valid),
    .resp_rdata (axi_resp_rdata),
    .araddr     (araddr),
    .arvalid    (arvalid),
    .arready    (arready),
    .rdata      (rdata),
    .rresp      (rresp),
    .rvalid     (rvalid),
    .rready     (rready),
    .awaddr     (awaddr),
    .awvalid    (awvalid),
    .awready    (awready),
    .wdata      (wdata),
    .wstrb      (wstrb),
    .wvalid     (wvalid),
    .wready     (wready),
    .bresp      (bresp),
    .bvalid     (bvalid),
    .bready     (bready)
  );

endmodule
