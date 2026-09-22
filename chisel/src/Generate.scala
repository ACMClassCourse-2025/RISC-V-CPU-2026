package cpu2026

import chisel3.stage.ChiselGeneratorAnnotation
import circt.stage.{ChiselStage, FirtoolOption}

object Generate {
  def main(args: Array[String]): Unit = {
    require(args.length <= 1, "Usage: mill chisel.run [verilog-output-directory]")
    val rtlDir = os.Path(args.headOption.getOrElse("verilog"), os.pwd)
    val generated = rtlDir / "generated" / "student_top.sv"
    val filelist = rtlDir / "filelist.f"
    val entry = "generated/student_top.sv"
    val previous = if (os.exists(filelist)) os.read(filelist) else ""
    val listed = previous.linesIterator.exists { line =>
      val path = line.takeWhile(_ != '#').trim
      path.nonEmpty && os.Path(path, rtlDir) == generated
    }
    val next = if (listed) previous else {
      previous + (if (previous.isEmpty || previous.endsWith("\n")) "" else "\n") + entry + "\n"
    }

    os.makeDir.all(rtlDir)
    val staging = os.temp.dir(dir = rtlDir, prefix = ".chisel-")
    try {
      // Single-file emission keeps the framework's plain RTL file list sufficient.
      (new ChiselStage).execute(
        Array("--target", "systemverilog", "--target-dir", staging.toString),
        Seq(ChiselGeneratorAnnotation(() => new StudentTop)) ++ Seq(
          "--disable-all-randomization",
          "--strip-debug-info",
          "--default-layer-specialization=enable",
          "--verification-flavor=if-else-fatal",
          "--lowering-options=disallowLocalVariables,disallowPackedArrays"
        ).map(FirtoolOption(_))
      )
      val emitted = os.walk(staging).filter(p => os.isFile(p) &&
        Set("sv", "v", "svh", "vh").contains(p.ext))
      require(emitted.toSet == Set(staging / "student_top.sv"),
        "Expected one student_top.sv. External RTL resources or extracted layers require " +
          "an explicit export/filelist setup; no submitted RTL has been updated.")

      os.write(staging / "filelist.f", next)
      os.makeDir.all(generated / os.up)
      os.move(staging / "student_top.sv", generated, replaceExisting = true, atomicMove = true)
      os.move(staging / "filelist.f", filelist, replaceExisting = true, atomicMove = true)
      println(s"Generated $generated and updated $filelist")
    } finally {
      os.remove.all(staging)
    }
  }
}
