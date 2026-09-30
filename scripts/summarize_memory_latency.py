#!/usr/bin/env python3
"""Validate cross-counter identities and generate the compact meeting report."""
import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/evaluation/latency-results"
BASE = dict(looped=23685, streaming=13290, resident=9818, offload=4272, cold_warm=8452)


def read(name):
    with (OUT / name).open() as f:
        return [{k: int(v) if k not in ("policy", "mode") else v
                 for k, v in r.items()} for r in csv.DictReader(f)]


def table(headers, rows):
    return "\n".join(["| " + " | ".join(headers) + " |",
                       "|" + "|".join("---" for _ in headers) + "|"] +
                      ["| " + " | ".join(str(v) for v in row) + " |" for row in rows])


def main():
    programs, commands = read("programs.csv"), read("commands.csv")
    def program(policy, mode, delay):
        return next(r for r in programs if r["policy"] == policy and
                    r["mode"] == mode and r["read_delay"] == delay)
    def command(policy, mode, delay, number):
        return next(r for r in commands if r["policy"] == policy and
                    r["mode"] == mode and r["read_delay"] == delay and r["command"] == number)
    for r in programs:
        assert r["whole_cycles"] == BASE[r["mode"]] + r["fetch_wait"] + r["cpu_data_wait"] + r["pim_wait"]
        assert r["fetch_wait"] == r["fetches"] * (r["fetch_delay"] - 1)
        assert r["completion_writes"] == 1
        if r["mode"] == "cold_warm":
            cs = [command(r["policy"], r["mode"], r["read_delay"], c) for c in (0, 1)]
            assert r["whole_cycles"] == sum(c["setup_cycles"] + c["execution_cycles"] +
                                             c["completion_cycles"] for c in cs)
    for r in commands:
        peer = command("fixed_fetch" if r["policy"] == "unified" else "unified",
                       r["mode"], r["read_delay"], r["command"])
        assert r["execution_cycles"] == peer["execution_cycles"]
        assert r["execution_cycles"] == (4141 if r["command"] == 0 else 4140) + r["pim_wait"]
        assert r["pim_wait"] == (r["vector_reads"] + r["matrix_reads"]) * (r["read_delay"] - 1)
        assert r["cpu_blocked"] == r["execution_cycles"]
    def whole(policy):
        return table(["L", "Looped CPU", "Streaming CPU", "Resident CPU", "PIM offload", "Two-command PIM total"],
            [[delay] + [f'{program(policy, mode, delay)["whole_cycles"]:,}' for mode in BASE]
             for delay in (1, 2, 5, 10, 20)])
    reuse = table(["L", "Cold execution", "Warm execution", "Saving", "Saving / cold", "Execution average N=2, includes cold"],
        [[d, (c:=command("unified","cold_warm",d,0))["execution_cycles"],
          (w:=command("unified","cold_warm",d,1))["execution_cycles"],
          c["execution_cycles"]-w["execution_cycles"],
          f'{100*(c["execution_cycles"]-w["execution_cycles"])/c["execution_cycles"]:.3f}%',
          (c["execution_cycles"]+w["execution_cycles"])/2] for d in (1,2,5,10,20)])
    def overhead(policy):
        return table(["L", "Cold setup", "Cold status/clear", "Warm setup", "Warm status/completion", "Two-command total / 2"],
            [[d, (c:=command(policy,"cold_warm",d,0))["setup_cycles"], c["completion_cycles"],
              (w:=command(policy,"cold_warm",d,1))["setup_cycles"], w["completion_cycles"],
              program(policy,"cold_warm",d)["whole_cycles"]/2] for d in (1,2,5,10,20)])
    waits = table(["Program", "Fetches", "Vector reads", "Matrix reads", "Output writes", "CPU blocked", "Fetch wait", "CPU data wait", "PIM data wait", "Fetch share of added cycles"],
        [[mode, (r:=program("unified",mode,20))["fetches"], r["vector_reads"], r["matrix_reads"],
          r["output_writes"], r["cpu_blocked"], r["fetch_wait"], r["cpu_data_wait"], r["pim_wait"],
          f'{100*r["fetch_wait"]/(r["whole_cycles"]-BASE[mode]):.2f}%'] for mode in BASE])
    text = """# Matched memory-response sensitivity — meeting with Professor Stan

The primary **uniform unified-memory** policy increases latency for every RAM
read, including CPU instruction fetches. A separately labeled **fixed-fetch**
sensitivity case keeps instruction reads at one cycle and delays RAM data reads
identically for CPU and PIM. MMIO retains the existing one-cycle status interface
in both cases. Both use acceptance-to-response-consumption edges, immediate
accepted writes, a single RAM port and one outstanding read.
See the [policy committed before coding](../memory-response-policy.md) and
[comparison contract](../comparison-contract.md).

All 50 program configurations passed: 30 CPU runs, 10 one-command PIM offloads,
and 10 two-command PIM programs, checking 1,920 output stores in total.
The 30 PIM commands include 10 successful warm commands with verified buffer
contents from their immediately preceding cold fill, without reset/invalidation.
Every run checks unchanged operands, completion, fixed traffic counts,
one-cycle measurements, response deadlines/data/ownership, and stalled-request
stability. A separate responder test forces pending-write backpressure and checks
write acceptance, fixed-fetch timing and reset cancellation. Production RTL is
unchanged; the runner mechanically replaces only the production top's RAM
adapter in ignored build output, with exact-match assertions against topology
drift. The one-cycle setting reproduces every existing program measurement.

## Whole-program cycles: primary unified-memory policy

""" + whole("unified") + """

Whole-program boundaries include CPU setup and status handling, ending at the
accepted RKYC store. The last column executes two workloads; use its explicitly
cold-inclusive average or command boundaries, not as a single offload.

![Whole-program comparison under explicitly different fetch assumptions](whole-program.png)

## Separately labeled sensitivity: instruction fetch fixed at one cycle

This assumes different latency classes for instruction and data reads on the
same single port; it is not the uniform primary policy and does not model a
cache. Data-read delays, write timing, ordering and outstanding limits are
unchanged.

""" + whole("fixed_fetch") + """

At L=20, the resident CPU/offload whole-program ratio is 3.588 under unified
latency and 1.385 with fixed fetch latency (2.298 at L=1 for both).
These are observations for different assumptions, not calibrated DRAM speedups.

## Cold versus warm execution: identical under both policies

""" + reuse + """

Each command performs 512 matrix reads, 32 writes and 512 MACs. Cold/warm vector
RAM reads are 16/0; buffer writes 16/0 and buffer reads 496/512.
CPU blocked by PIM busy equals the execution-cycle count in this table.
The existing one-command cold offload has the same execution interval; its
different whole-program setup/status boundary remains in programs.csv.

Observed saving: 1, 17, 65, 145 and 305 cycles. Increasing latency exposes
the 16 avoided vector reads, but even at L=20 the saving is only 2.152%
of cold execution because the 512 matrix reads remain. Measured identities:
cold = 4141 + 528(L−1), warm = 4140 + 512(L−1), saving = 1 + 16(L−1).
These summarize the measured sweep, not measurements at other L.

Controller explanation (inference from RTL): cold vector request/wait/response
bypass and warm buffer read/capture have equal base state time at L=1. Cold
additionally initializes the vector once. External responses extend cold's
vector wait path; local buffer timing does not change. Matrix/MAC scheduling
stays the same. Thus 16 avoided external waits plus initialization explain the
observations; reduced traffic alone does not imply proportional latency savings.

![PIM reuse saving and instruction-fetch contribution](pim-reuse-and-fetch.png)

## Setup and completion/status outside execution

Primary unified-memory policy:

""" + overhead("unified") + """

Fixed-fetch sensitivity:

""" + overhead("fixed_fetch") + """

Cold setup runs through cold START inclusive; cold status/clear ends at accepted
STATUS_CLEAR. Warm setup runs after that clear through warm START; warm
completion ends at accepted RKYC. These six adjacent intervals sum to the
two-command whole-program total. Do not add blocked/wait counters, which overlap
these intervals. Different setup/status work is not vector-reuse acceleration.

For N execution commands starting cold, average = [Tcold + (N−1)Twarm]/N
= Twarm + [1+16(L−1)]/N. At L=20 the measured two-command execution average
is 14,020.5 cycles, not 13,868. For N=10 this projects 13,898.5 (only N=2 was
executed). Whole-program N=2 averages above include actual control/status work
and initial cold cost; no unmeasured steady-state host/control overhead is
assumed. Matrix reads average 512 per command, vector reads 16/N.

## Executable counters and instruction-fetch contribution

At L=20 under primary unified timing:

""" + waits + """

Two-command totals include 64 outputs and 1,024 matrix reads. Other rows
represent one workload. All programs also perform one completion write.
CPU programs have one signature RAM read; PIM programs have a literal plus
signature RAM read. MMIO counts are 7 writes/1 read for offload and
9 writes/6 reads for cold/warm.

Added read waits equal L−1 per accepted read, split into CPU fetch, CPU data and
PIM data. CPU blocked counts pending requests denied acceptance; CPU response
waiting is separate, so zero blocked clocks for CPU-only programs does not mean
zero memory stalls. All blocked request clocks here are caused by PIM busy.
For every measured case, whole-program growth equals the sum of categorized
read waits. Fixed-fetch runs have zero fetch wait and the same data waits.
Full per-configuration counters and command boundaries are in
[programs.csv](programs.csv) and [commands.csv](commands.csv);
cold-inclusive averages and labeled projections are in
[repeated-commands.csv](repeated-commands.csv).

## Reproduce and limits

Run from /home/robel/OpenCoreX in Ubuntu WSL:

~~~bash
make latency-sweep
python3 scripts/run_memory_latency_sweep.py --check
python3 scripts/summarize_memory_latency.py
PYTHONPATH=obj_dir/plot_dependencies python3 scripts/plot_memory_latency.py
make verify
git diff --check
~~~

The full Verilator build command is printed into /tmp/opencorex-latency.log;
build/simulation logs are under obj_dir/verification/memory_latency and
obj_dir/verification/latency_responder_unit. The default runner regenerates
CSV measurements; --check, make test and make verify compare exact snapshots.
Plotting uses Matplotlib 3.10.8 installed only under ignored obj_dir with:

~~~bash
python3 -m pip install --target obj_dir/plot_dependencies matplotlib==3.10.8
~~~

Plotting dependencies are not required for RTL verification.
This is a deterministic sensitivity experiment, not calibrated DRAM.
There are no banks, row hits, refresh, bursts, caches, physical timings or
energy parameters. Host placement is excluded; operands begin in the same RAM.
The CPU has no cache; PIM is a separate digital MAC, not in-array CIM.
Cycles cannot establish area, energy or physical clock-time superiority.
The resident CPU is the strongest implemented 16×32 comparator; the looped
CPU remains the general reference. Results do not extrapolate to larger matrices,
packed int8, matrix residency or nonblocking execution.

Next: define packed signed-int8 layout and CPU extraction, then implement the
one-lane D8 digital comparator and its CPU reference before SRAM CIM or RRAM.
See the [architecture memo](../d8-sram-cim-design-memo.md).
"""
    (OUT / "README.md").write_text(text)
    averages = []
    for policy in ("unified", "fixed_fetch"):
        for delay in (1,2,5,10,20):
            cold = command(policy,"cold_warm",delay,0)["execution_cycles"]
            warm = command(policy,"cold_warm",delay,1)["execution_cycles"]
            for n in (2,10,100):
                averages.append(dict(policy=policy, read_delay=delay, commands=n,
                    basis="measured_two_commands" if n == 2 else "execution_only_projection",
                    cold_execution=cold, warm_execution=warm,
                    average_execution=(cold+(n-1)*warm)/n,
                    average_vector_reads=16/n, average_matrix_reads=512,
                    average_whole_program=program(policy,"cold_warm",delay)["whole_cycles"]/2 if n==2 else ""))
    with (OUT / "repeated-commands.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f,fieldnames=averages[0].keys(),lineterminator="\n")
        writer.writeheader(); writer.writerows(averages)
    print("PASS: cross-counter identities, timing partitions and cold-inclusive averages")


if __name__ == "__main__":
    main()
