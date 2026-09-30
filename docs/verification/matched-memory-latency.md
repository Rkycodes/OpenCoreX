# Matched latency experiment verification — 2026-09-30

Integration PR [#5](https://github.com/Rkycodes/OpenCoreX/pull/5) was merged as
`9a27e3537b95d43a49c1d89836a54825aad6f000`. Local Ubuntu WSL main was
fast-forwarded to the same commit. Current branch names follow the user's
`feat/` or `integration/` naming preference; the remote integration branch
is now `integration/matvec-experiments`.

Experiment branch: `feat/matched-memory-latency`. The response policy was
committed before its implementation. Production RTL and the original measured
assertions remain unchanged. A generated test top retains the production
instances and topology and replaces only the RAM adapter; accepted CPU grants
identify fetches. No CIM implementation was added.

## Gate and observations

Verilator 5.032 with GNU C++ in Ubuntu WSL passed:
RTL lint, all 33 original positive benches, four focused CPU diagnostic
configurations, the responder protocol unit, all 50 sweep configurations,
and every expected-failure case. The snapshot check reproduces 50 program
records and 30 PIM command records exactly. The sweep checks 1,920 output
stores in total, operands, signatures, warm buffer validity, read deadlines,
response data/ownership and request stability. A unit test drives writes
while a read is pending and verifies response cancellation on reset.

Image regeneration leaves all three tracked images unchanged. No compiler
workaround was required. The initial sweep build found an oversized testbench
array index under -Wall; it was narrowed to its actual one-bit command selector,
without suppressing the warning or changing a measurement assertion.

See [measured tables, interpretation and plots](../evaluation/latency-results/README.md)
and the [D8/SRAM-CIM/RRAM decision memo](../evaluation/d8-sram-cim-design-memo.md).

## Exact validation commands run

All shell commands below used Ubuntu WSL, working directory /home/robel/OpenCoreX.
The earlier integration's commands/results are in [its gate record](experiment-integration.md).

```bash
make latency-sweep > /tmp/opencorex-latency.log 2>&1
python3 scripts/run_memory_latency_sweep.py --check > /tmp/opencorex-latency-check.log 2>&1
python3 scripts/summarize_memory_latency.py
python3 -m pip install --target obj_dir/plot_dependencies matplotlib==3.10.8 > /tmp/opencorex-plot-install.log 2>&1
PYTHONPATH=obj_dir/plot_dependencies python3 scripts/plot_memory_latency.py
make verify > /tmp/opencorex-latency-verify.log 2>&1
python3 scripts/generate_matvec_diagnostics.py
python3 scripts/generate_pim_cold_warm_1x16_16x32.py
git diff --exit-code main -- programs/hex
git diff --check
```

The responder build is:
`verilator --binary --timing -Wall -j 4 --top-module latency_memory_responder_tb`
with memory.sv, latency_memory_responder.sv and its unit test.

The experiment build is:
`verilator --binary --timing -Wall -j 4 --top-module opencorex_memory_latency_tb`
with pim_pkg.sv first, remaining production RTL, the generated test top,
latency_memory_responder.sv and opencorex_memory_latency_tb.sv.
Full absolute command lines and per-case stdout are preserved in build/sweep logs
under obj_dir/verification/memory_latency and latency_responder_unit.
Each simulation uses `+MODE=0..4 +DELAY=1,2,5,10,20 +FIXED_FETCH=0/1`
as the Cartesian product, not comma-delimited Verilator arguments.

Plotting was isolated under ignored obj_dir; neither the host-wide Python nor
RTL toolchain was modified. A venv attempt failed because this WSL Python lacks
ensurepip; pip --target succeeded. The figures are available as PNG and SVG and
were visually inspected.

## Limits and next task

Uniform RAM delay includes instruction fetch; the fixed-fetch case explicitly
changes that assumption. MMIO is unchanged and separately counted.
These are deterministic single-port latency sensitivities, not calibrated DRAM.
No energy, area or physical clock period was measured; no cache, matrix-resident
CIM or packed-int8 datapath was implemented. N=2 cold-inclusive repeated-command
averages are measured; N=10/100 execution averages are algebraic projections.
Next: freeze packed int8 lane order, sign extraction, accumulator semantics and
a CPU unpack instruction contract; implement one-lane D8 and its matched CPU
reference before a matrix-resident SRAM-CIM model, then RRAM.
