# Unit-test build helper

`build.py` compiles one RTL module (or a small module group) together with a
C++ Verilator testbench.  It intentionally takes an **explicit source list**:
unit tests never read `verilog/filelist.f`, so stubs and testbenches cannot leak
into the OJ build.

## Usage

```sh
python3 tools/unit/build.py \
    --top divider \
    --tb test/divider_test/divider_tb.cpp \
    --sources verilog/divider.sv \
    -- --quick
```

- `--top` — top module name
- `--tb` — C++ testbench
- `--sources` — RTL files, in compile order
- `--define/-D` — macro override (e.g. `-DCPU_ISSUE_WIDTH=2`)
- `--out` — build directory (default `build/unit/<top>`)
- `--no-run` — compile only
- `--` — remaining arguments are passed to the test binary

The script uses the course AppImage when Verilator is not on `PATH`, matching
`make build`.  A native Verilator can be selected with `--verilator` or the
`VERILATOR` environment variable is not needed.
