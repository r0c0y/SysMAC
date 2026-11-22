#!/usr/bin/env python3
"""Mutation check: do the testbenches catch real bugs?

A passing test suite is only evidence if it would FAIL on a wrong design.
This script plants one known bug ("mutant") at a time in a scratch copy of the
repository, runs scripts/run_simulation.sh on it, and records which
testbenches fail ("kill" the mutant). The repository itself is never edited.

Each mutant is a plain text edit of the current RTL. If the code has changed
so that an edit no longer applies, the mutant is reported as "not applied"
instead of silently passing.

Usage (from anywhere):
  python3 scripts/mutation_check.py            # run all mutants, print a table
  python3 scripts/mutation_check.py --list     # list mutants only
  python3 scripts/mutation_check.py --markdown # table in Markdown, for the report

Exit code: 0 if every mutant that should be killed was killed, 1 otherwise,
2 if the unmodified design does not pass to begin with.

Needs python3, bash, iverilog and vvp. Takes about 30 seconds.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# name: (description, expected, [(file, find, replace), ...])
# expected = "killed" for a real bug, "equivalent" when the change is still
# correct under docs/port_spec.md (no test can or should catch it).
MUTANTS = [
    ("skew_b_late", "B enters one cycle late", "killed", [
        ("rtl/input_scheduler.v",
         "b_in_flat[n*8 +: 8] = b_mat[(k*3 + n)*8 +: 8];",
         "b_in_flat[n*8 +: 8] = (k > 0) ? b_mat[((k-1)*3 + n)*8 +: 8] : 8'd0;")]),
    ("b_transposed", "B read transposed", "killed", [
        ("rtl/input_scheduler.v", "b_mat[(k*3 + n)*8 +: 8]", "b_mat[(n*3 + k)*8 +: 8]")]),
    ("unsigned_multiply", "multiplier treats operands as unsigned", "killed", [
        ("rtl/processing_element.v",
         "wire signed [2*DATA_WIDTH-1:0] product = a_in * b_in;",
         "wire signed [2*DATA_WIDTH-1:0] product = $unsigned(a_in) * $unsigned(b_in);")]),
    ("acc_16_bit", "accumulator wraps at 16 bits", "killed", [
        ("rtl/processing_element.v",
         "wire signed [2*DATA_WIDTH-1:0] product = a_in * b_in;",
         "wire signed [2*DATA_WIDTH-1:0] product = a_in * b_in;\n"
         "    wire signed [15:0] sum16 = acc[15:0] + product;"),
        ("rtl/processing_element.v", "acc <= acc + product;", "acc <= sum16;")]),
    ("no_clear", "clear does not reset the PE", "killed", [
        ("rtl/processing_element.v", "if (reset || clear) begin", "if (reset) begin")]),
    ("clear_only_acc", "clear resets the accumulator but not the forwarding registers", "killed", [
        ("rtl/processing_element.v", "if (reset || clear) begin",
         "if (clear && !reset) begin\n            acc <= {ACC_WIDTH{1'b0}};\n"
         "        end else if (reset) begin")]),
    ("ignore_valid_b", "PE accumulates on valid_a alone", "killed", [
        ("rtl/processing_element.v", "if (valid_a_in && valid_b_in) begin", "if (valid_a_in) begin")]),
    ("ctrl_one_short", "controller ends COMPUTE one cycle early", "killed", [
        ("rtl/systolic_controller.v", "if (t == 3'd6)", "if (t == 3'd5)")]),
    ("restart_in_capture", "controller restarts on start during CAPTURE", "killed", [
        ("rtl/systolic_controller.v", "CAPTURE: state <= DONE;", "CAPTURE: state <= start ? LOAD : DONE;")]),
    ("restart_in_done", "controller restarts on start during DONE", "killed", [
        ("rtl/systolic_controller.v", "DONE:    state <= IDLE;", "DONE:    state <= start ? LOAD : IDLE;")]),
    ("buffer_no_latch", "input buffer copies its inputs every cycle", "killed", [
        ("rtl/input_buffer.v", "end else if (load) begin", "end else begin")]),
    ("seq_no_restart", "baseline does not restart the sum for each C[i][j]", "killed", [
        ("rtl/seq_matmul.v", "(k == 2'd0) ? 32'sd0 : acc", "acc")]),
    ("capture_every_cycle", "output registers copy every cycle", "equivalent", [
        ("rtl/output_registers.v", "else if (capture)", "else if (1'b1)")]),
]


def run_suite(tree):
    """Run the full suite in `tree`. Returns (ok, {testbench: PASS/FAIL/...})."""
    env = dict(os.environ, TIMEOUT="60")
    out = subprocess.run(["bash", "scripts/run_simulation.sh"], cwd=tree, env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
    results = {}
    for line in out.splitlines():
        m = re.match(r"^  (PASS|FAIL|WAITING)\s+(tb_\S+)", line)
        if m:
            results[m.group(2)] = m.group(1)
    return results


def copy_tree(dst):
    shutil.copytree(ROOT, dst, ignore=shutil.ignore_patterns(".git", "build", "*.vcd", "__pycache__"))


def apply(tree, edits):
    for path, find, replace in edits:
        full = os.path.join(tree, path)
        with open(full) as f:
            text = f.read()
        if text.count(find) != 1:
            return False
        with open(full, "w") as f:
            f.write(text.replace(find, replace))
    return True


def short(tb):
    return (tb.replace("tb_matmul_vectors_systolic_top", "vectors(systolic)")
              .replace("tb_matmul_vectors_seq", "vectors(seq)")
              .replace("tb_", ""))


def main():
    if "--list" in sys.argv:
        for name, desc, exp, _ in MUTANTS:
            print("%-22s %-11s %s" % (name, exp, desc))
        return 0
    markdown = "--markdown" in sys.argv

    with tempfile.TemporaryDirectory(prefix="sysmac_mut_") as tmp:
        base = os.path.join(tmp, "base")
        copy_tree(base)
        clean = run_suite(base)
        if not clean or any(v != "PASS" for v in clean.values()):
            print("the unmodified design does not pass every testbench:", clean)
            return 2

        rows, bad = [], 0
        for i, (name, desc, expected, edits) in enumerate(MUTANTS):
            tree = os.path.join(tmp, "m%d" % i)
            copy_tree(tree)
            if not apply(tree, edits):
                rows.append((name, desc, expected, "not applied (code changed)", "check"))
                bad += 1
                continue
            res = run_suite(tree)
            killers = [short(tb) for tb, r in res.items() if r == "FAIL"]
            killed = bool(killers)
            verdict = "ok" if killed == (expected == "killed") else "UNEXPECTED"
            if verdict != "ok":
                bad += 1
            rows.append((name, desc, expected,
                         ", ".join(killers) if killers else "survived", verdict))
            shutil.rmtree(tree)

    if markdown:
        print("| Mutant | Planted bug | Expected | Killed by | Verdict |")
        print("|---|---|---|---|---|")
        for r in rows:
            print("| %s | %s | %s | %s | %s |" % r)
    else:
        for name, desc, expected, by, verdict in rows:
            print("%-22s %-10s %-10s %s" % (name, verdict, expected, by))
    total = sum(1 for m in MUTANTS if m[2] == "killed")
    killed = sum(1 for r in rows if r[2] == "killed" and r[4] == "ok")
    print("\n%d of %d real bugs killed; %d equivalent mutant(s) survived as expected; %d problem(s)"
          % (killed, total, sum(1 for r in rows if r[2] == "equivalent" and r[4] == "ok"), bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
