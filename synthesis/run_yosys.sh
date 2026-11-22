#!/usr/bin/env bash
# Open-source synthesis with Yosys for Xilinx 7-series primitives.
#
#   synthesis/run_yosys.sh
#
# Synthesises the systolic top and the sequential baseline twice each:
#   hierarchical  synth_xilinx            (module boundaries kept)
#   flattened     synth_xilinx -flatten   (optimised across boundaries)
# and writes full logs to synthesis/yosys/*.log (not committed) and the cell
# counts to synthesis/yosys/summary.txt (committed).
#
# These are cell counts only: no placement, no routing, no timing, no Fmax.
# Utilisation and maximum frequency come from Vivado (synthesis/vivado/).
#
# Why the two flows differ: in the hierarchical flow each processing element
# keeps its a_out/b_out/valid registers even at the array edge, where nothing
# reads them. Flattening lets Yosys see they are unused and remove them.

set -eu
cd "$(dirname "$0")/.."
command -v yosys >/dev/null || { echo "missing tool: yosys"; exit 2; }

OUT=synthesis/yosys
mkdir -p "$OUT"

SYS="rtl/systolic_controller.v rtl/input_buffer.v rtl/input_scheduler.v
     rtl/processing_element.v rtl/systolic_array.v rtl/output_registers.v
     rtl/systolic_accelerator_top.v"
SEQ="rtl/seq_matmul.v"

run() {     # run <name> <top> <flatten flag> <files>
    local name=$1 top=$2 flag=$3; shift 3
    # shellcheck disable=SC2086
    yosys -q -l "$OUT/$name.log" -p "read_verilog $*; synth_xilinx -top $top $flag; check; stat" >/dev/null
}

# shellcheck disable=SC2086
run systolic_hier     systolic_accelerator_top ""         $SYS
# shellcheck disable=SC2086
run systolic_flat     systolic_accelerator_top "-flatten" $SYS
run seq_matmul_hier   seq_matmul               ""         $SEQ
run seq_matmul_flat   seq_matmul               "-flatten" $SEQ

summary() { # summary <log>: DSP FF LUT
    python3 - "$1" <<'EOF'
import re, sys
text = open(sys.argv[1]).read()
# the last stat block is for the whole design (top including submodules)
block = text.rsplit("Printing statistics.", 1)[-1]            # the final explicit stat
if "=== design hierarchy ===" in block:                       # hierarchical: use the totals
    block = block.rsplit("=== design hierarchy ===", 1)[-1]
cells = dict()
for n, cell in re.findall(r"^\s+(\d+)\s+(\S+)\s*$", block, re.M):
    cells[cell] = cells.get(cell, 0) + int(n)
dsp = cells.get("DSP48E1", 0)
ff = sum(v for k, v in cells.items() if re.fullmatch(r"FD[RSCP]E?", k))
lut = sum(v for k, v in cells.items() if re.fullmatch(r"LUT[1-6]", k))
problems = re.findall(r"Found and reported (\d+) problems", text)
print("%d %d %d %s" % (dsp, ff, lut, problems[-1] if problems else "?"))
EOF
}

{
    echo "Yosys $(yosys -V | awk '{print $2}') synth_xilinx, 7-series primitives, no timing"
    echo
    printf "%-26s %8s %6s %6s %9s\n" design DSP48E1 FF LUT problems
    for n in systolic_hier systolic_flat seq_matmul_hier seq_matmul_flat; do
        read -r dsp ff lut prob <<<"$(summary "$OUT/$n.log")"
        printf "%-26s %8s %6s %6s %9s\n" "$n" "$dsp" "$ff" "$lut" "$prob"
    done
} | tee "$OUT/summary.txt"
