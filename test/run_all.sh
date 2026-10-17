#!/bin/sh
# -----------------------------------------------------------------------------
# run_all.sh — 甲侧已完成模块的一键回归
#
#   sh test/run_all.sh              # 快速参数矩阵
#   sh test/run_all.sh --full       # 完整随机对拍
#   sh test/run_all.sh --build      # 结束后再跑 make build
#   sh test/run_all.sh --seed 123
#
# 不修改 Makefile/scripts；所有单测仍走各自的 run.sh。
# -----------------------------------------------------------------------------
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"

full=0
do_build=0
seed=0x20261018

while [ $# -gt 0 ]; do
    case "$1" in
        --full)  full=1; shift ;;
        --build) do_build=1; shift ;;
        --seed)
            [ $# -ge 2 ] || { echo "error: --seed needs a value" >&2; exit 2; }
            seed=$2
            shift 2
            ;;
        *)
            echo "usage: $0 [--full] [--build] [--seed N]" >&2
            exit 2
            ;;
    esac
done

if [ "$full" -eq 1 ]; then
    quick=""
else
    quick="--quick"
fi

run() {
    name=$1
    shift
    printf '\n===== %s =====\n' "$name"
    "$@"
}

printf 'run_all: root=%s full=%d seed=%s\n' "$root" "$full" "$seed"

run "config check" python3 tools/config_gen.py --check
run "pc_unit" sh test/pc_unit_test/run.sh $quick --seed "$seed"
run "bpu default" sh test/bpu_test/run.sh $quick --seed "$seed"
run "bpu 4/6 bits" env BPU_BTB_INDEX_BITS=4 BPU_BHT_INDEX_BITS=6 \
    sh test/bpu_test/run.sh $quick --seed "$seed"
run "if_defs default" sh test/if_defs_test/run.sh
run "if_defs W=2/PRF=96/ROB=64" env \
    IF_TEST_W=2 IF_TEST_PRF=96 IF_TEST_CDB=2 IF_TEST_ROB=64 IF_TEST_LSQ=16 \
    sh test/if_defs_test/run.sh
run "icache index=4" env ICACHE_INDEX_BITS=4 \
    sh test/icache_pipe_test/run.sh $quick --seed "$seed"
run "icache index=10" env ICACHE_INDEX_BITS=10 \
    sh test/icache_pipe_test/run.sh $quick --cycles 5000 --seed "$seed"
run "rename W=1" env RENAME_W=1 sh test/rename_test/run.sh $quick --seed "$seed"
run "rename W=2" env RENAME_W=2 sh test/rename_test/run.sh $quick --seed "$seed"
run "rob W=1" env ROB_W=1 sh test/rob_test/run.sh $quick --seed "$seed"
run "rob W=2" env ROB_W=2 sh test/rob_test/run.sh $quick --seed "$seed"
run "frontend W=1" env FRONTEND_W=1 sh test/frontend_test/run.sh
run "frontend W=2" env FRONTEND_W=2 sh test/frontend_test/run.sh

if [ "$do_build" -eq 1 ]; then
    run "make build" make build JOBS=4
fi

printf '\nrun_all: ALL PASS\n'
