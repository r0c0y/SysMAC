# Vivado results (out-of-context)

`ooc.tcl` produces utilisation, timing (Fmax) and power reports for the
systolic top and the baseline. It has not been run yet; the first person who
runs it should commit `synthesis/vivado/<top>/*.rpt` and `fmax.txt` (not the
`.dcp` checkpoints) and fix the script if Vivado complains.

## Which Vivado

Use **Vivado 2025.2**. From 2026.1 the free tier ("BASIC") needs a yearly,
machine-locked licence file, which breaks on cloud machines that change
between sessions. 2025.2 is the last free release without one and is still on
AMD's download page. Only the Artix-7 device family is needed. About 3 GB of
RAM is enough for this design; disk for the install is roughly 30 to 50 GB.

## Where to run it

This design cannot be run in Vivado on Apple Silicon. Options, best first:

1. A Windows or Linux x86 PC with Vivado (a teammate or a college lab).
2. GitHub Codespaces, 8-core machine (64 GB disk): free within the monthly
   allowance; install with the web installer in batch mode.
3. A cloud VM (for example AWS EC2 m7i-flex.large, Ubuntu, 100 GB disk):
   a few dollars for a weekend, or free on new-account credits. Delete the
   VM and disk afterwards.

## Run

From the repository root:

```
vivado -mode batch -nojournal -nolog -source synthesis/vivado/ooc.tcl -tclargs 10.0
```

This runs both designs in one session and writes `summary.txt` plus the full
reports per design. Read `summary.txt` and each `fmax.txt`. If WNS is large and positive, rerun with a smaller period
(Vivado stops optimising once timing is met). If WNS is negative, rerun with
a larger period. Report the part, speed grade, Vivado version and period with
every number.

## Why out-of-context

The top has 436 port bits; an xc7a35t has 106 user I/O (cpg236) or 210
(csg324). Out-of-context mode measures the core without pins. Port-to-register
paths are not timed; register-to-register paths, including each PE's
multiply-add, are. The power report has no I/O power and uses default
switching activity, so treat it as an estimate.

## What to look at in timing.rpt

Our longest logic path (Yosys, 85 gate levels) starts at the controller's
`t`, goes through the scheduler's index arithmetic and operand select, and
ends in an edge PE's multiply-add. Check whether Vivado reports the same
worst path. If it does, registering the scheduler outputs is the obvious
way to raise Fmax.
