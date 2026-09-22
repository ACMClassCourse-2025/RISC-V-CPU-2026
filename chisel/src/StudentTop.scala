package cpu2026

import chisel3._

/** Course interface. Replace the idle outputs with your CPU implementation. */
class StudentTop extends Module with RequireSyncReset {
  override def desiredName = "student_top"

  // Separate IO declarations preserve the exact harness port names (no io_ prefix).
  val araddr  = IO(Output(UInt(32.W)))
  val arvalid = IO(Output(Bool()))
  val arready = IO(Input(Bool()))

  val rdata   = IO(Input(UInt(32.W)))
  val rresp   = IO(Input(UInt(2.W)))
  val rvalid  = IO(Input(Bool()))
  val rready  = IO(Output(Bool()))

  val awaddr  = IO(Output(UInt(32.W)))
  val awvalid = IO(Output(Bool()))
  val awready = IO(Input(Bool()))

  val wdata   = IO(Output(UInt(32.W)))
  val wstrb   = IO(Output(UInt(4.W)))
  val wvalid  = IO(Output(Bool()))
  val wready  = IO(Input(Bool()))

  val bresp   = IO(Input(UInt(2.W)))
  val bvalid  = IO(Input(Bool()))
  val bready  = IO(Output(Bool()))

  // This skeleton builds but does not execute instructions or pass CPU tests.
  araddr  := 0.U
  arvalid := false.B
  rready  := false.B
  awaddr  := 0.U
  awvalid := false.B
  wdata   := 0.U
  wstrb   := 0.U
  wvalid  := false.B
  bready  := false.B
}
