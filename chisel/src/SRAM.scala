package cpu2026

import chisel3._
import chisel3.util.log2Ceil

/** External course SRAM; the framework supplies its simulation and synthesis models.
  * See docs/sram.md for the single-port, one-cycle read and write-mask semantics.
  */
class SRAM(depth: Int, width: Int, writeGranularity: Int) extends ExtModule(
  Map(
    "DEPTH" -> IntParam(depth),
    "WIDTH" -> IntParam(width),
    "WRITE_GRANULARITY" -> IntParam(writeGranularity)
  )
) {
  require(depth >= 1 && depth <= 1048576, "SRAM depth must be 1..1048576")
  require(width >= 1 && width <= 4096, "SRAM width must be 1..4096")
  require(depth.toLong * width <= 16777216, "SRAM capacity must be <= 16777216 bits")
  require(writeGranularity >= 1 && writeGranularity <= width,
    "SRAM write granularity must be 1..width")
  require(width % writeGranularity == 0, "SRAM write granularity must divide width")

  override def desiredName = "sram_fakeram"

  val clk   = IO(Input(Clock()))
  val en    = IO(Input(Bool()))
  val we    = IO(Input(Bool()))
  val wmask = IO(Input(UInt((width / writeGranularity).W)))
  val addr  = IO(Input(UInt(math.max(1, log2Ceil(depth)).W)))
  val wdata = IO(Input(UInt(width.W)))
  val rdata = IO(Output(UInt(width.W)))
}
