module divider (
  input  logic        clk,
  input  logic        reset,
  input  logic        start,        // 1 拍脉冲；busy=1 时应忽略
  input  logic        is_signed,    // 1: DIV/REM, 0: DIVU/REMU
  input  logic [31:0] a,            // 被除数
  input  logic [31:0] b,            // 除数
  output logic        busy,
  output logic        done,         // 完成时 1 拍脉冲
  output logic [31:0] quotient,
  output logic [31:0] remainder
);

  logic [31:0] b_u;
  logic [31:0] quot_u, rest_u;
  logic [4:0] i;
  logic [31:0] quotient_mem, remainder_mem;
  typedef enum logic[1:0] { IDLE, RUNNING, DONE } divider_state;
  divider_state state;
  logic negative_a, negative_b;
  assign negative_a = is_signed && a[31];
  assign negative_b = is_signed && b[31];
  always_ff @ (posedge clk or posedge reset) begin
    if (reset) begin
      rest_u <= 32'b0;
      b_u <= 32'b0;
      quot_u <= 32'b0;
      quotient_mem <= 32'b0;
      remainder_mem <= 32'b0;
      i <= 5'b11111;
      state <= IDLE;
    end else begin
      unique case (state)
        IDLE: begin
          if (start == 1) begin
            if (b == 32'b0) begin
              // RISC-V M extension: division by zero yields all ones for the
              // quotient and the original dividend for the remainder.
              quotient_mem  <= 32'hffff_ffff;
              remainder_mem <= a;
              state         <= DONE;
            end else if (is_signed && (a == 32'h8000_0000) &&
                         (b == 32'hffff_ffff)) begin
              // INT_MIN / -1: quotient = INT_MIN, remainder = 0.
              quotient_mem  <= 32'h8000_0000;
              remainder_mem <= 32'b0;
              state         <= DONE;
            end else begin
              rest_u <= negative_a ? -$signed(a) : a;
              b_u <= negative_b ? -$signed(b) : b;
              quot_u <= 32'b0;
              i <= 5'b11111;
              state <= RUNNING;
            end
          end
        end
        RUNNING: begin
          logic [31:0] new_rest_u, new_quot_u;
          if ((rest_u  >> i) >= b_u) begin
            new_rest_u = rest_u - (b_u << i);
            new_quot_u = quot_u | (1 << i);
          end else begin
            new_rest_u = rest_u;
            new_quot_u = quot_u;
          end
          rest_u <= new_rest_u;
          quot_u <= new_quot_u;
          quotient_mem <= (negative_a ^ negative_b) ? -$signed(new_quot_u) : new_quot_u;
          remainder_mem <= negative_a ? -$signed(new_rest_u) : new_rest_u;
          state <= (i == 0 ? DONE : RUNNING);
          i <= i - 1;
        end
        DONE: begin
          state <= IDLE;
        end
      endcase
    end
  end
  assign busy = (state == RUNNING);
  assign done = (state == DONE);
  assign quotient = quotient_mem;
  assign remainder = remainder_mem;

endmodule
