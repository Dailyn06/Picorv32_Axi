#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

trace_flags=()
if [[ $# -eq 1 && $1 == --waves ]]; then
    trace_flags=(--trace --trace-depth 2)
    mkdir -p waves
elif [[ $# -ne 0 ]]; then
    printf 'Usage: bash %s [--waves]\n' "$0" >&2
    exit 2
fi

build_dir=$(mktemp -d)
trap 'rm -rf -- "$build_dir"' EXIT

make -C fw BUILD_DIR="$build_dir/fw"

verilator --binary --timing --assert -Wno-fatal --top-module tb_axi_soc \
    --Mdir "$build_dir" -j "${JOBS:-2}" "${trace_flags[@]}" \
    picorv32.v top.v axi_decoder.v axi_lite_interconnect.v rom.v sram.v \
    uart_axi.v uart_rx.v uart_tx.v tb/tb_axi_soc.sv

run_case() {
    local name=$1
    shift
    if ((${#trace_flags[@]})); then
        set -- "$@" "+waves=$PWD/waves/$name.vcd"
    fi
    "$build_dir/Vtb_axi_soc" "$@"
}

run_case boot_echo
run_case sram +sram_test +romhex=tb/sram_uart.hex
run_case firmware +firmware_test "+romhex=$build_dir/fw/firmware.hex"
