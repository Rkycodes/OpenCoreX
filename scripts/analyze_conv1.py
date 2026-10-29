"""Generate a readable analysis directly from the measured convolution CSV."""
import csv
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/"docs/evaluation/conv1-results"
MODES = ("streaming","tiled","mac","offload")
LABELS = ("A: streaming","B: tiled MUL+ADD","C: tiled MAC","D: GEMV + CPU")


def main():
    rows = list(csv.DictReader((OUT/"programs.csv").open()))
    assert len(rows) == 24
    index = {(r["case"],r["mode"],int(r["read_latency"])):r for r in rows}
    def n(case,mode,latency,key):
        return int(index[case,mode,latency][key])
    comparisons = []
    table = ["| Case | RAM latency | A cycles | B cycles | C cycles | D cycles | C / D |",
             "|---|---:|---:|---:|---:|---:|---:|"]
    for case in ("small","wrap"):
        for latency in (1,5,20):
            a,b,c,d = [n(case,m,latency,"whole_cycles") for m in MODES]
            item = dict(case=case,read_latency=latency,streaming_cycles=a,
                tiled_cycles=b,mac_cycles=c,offload_cycles=d,
                tiling_speedup=a/b,fusion_speedup=b/c,offload_vs_mac=c/d,
                offload_vs_streaming=a/d,fusion_cycles_saved=b-c,
                offload_packing_fraction=n(case,"offload",latency,"packing_cycles")/d,
                offload_post_fraction=n(case,"offload",latency,"post_cycles")/d)
            comparisons.append(item)
            assert b-c == 5*34560+4+4*latency
            table.append(f"| {case} | {latency} | {a:,} | {b:,} | {c:,} | {d:,} | {c/d:.3f}x |")
    (OUT/"analysis.json").write_text(json.dumps(comparisons,indent=2)+"\n")
    traffic = ["| Variant | Patch reads | Weight reads | CPU instructions (wrap) | Total RAM reads |",
               "|---|---:|---:|---:|---:|"]
    phase_table = ["| L=20, wrap case | Setup | CPU packing | Computation | CPU bias/ReLU | Whole job |",
                   "|---|---:|---:|---:|---:|---:|"]
    for mode,label in zip(MODES,LABELS):
        traffic.append("| "+label+" | "+" | ".join(f"{n('wrap',mode,20,key):,}" for key in
            ("patch_reads","weight_reads","fetches","ram_reads"))+" |")
        phase_table.append("| "+label+" | "+" | ".join(f"{n('wrap',mode,20,key):,}" for key in
            ("setup_cycles","packing_cycles","compute_cycles","post_cycles","whole_cycles"))+" |")
    r1 = next(r for r in comparisons if r["case"]=="wrap" and r["read_latency"]==1)
    r20 = next(r for r in comparisons if r["case"]=="wrap" and r["read_latency"]==20)
    proof = json.loads((OUT/"proof.json").read_text())
    negative_counts = {case: sum(int(word,16) >= 2**31 for word in
        (ROOT/f"obj_dir/verification/conv1/images/{case}_biased.hex").read_text().split())
        for case in ("small","wrap")}
    assert negative_counts["small"]-negative_counts["wrap"] == 19
    for mode in MODES:
        for latency in (1,5,20):
            assert n("small",mode,latency,"whole_cycles")-n("wrap",mode,latency,"whole_cycles") == 114
    assert proof["rtl_runs"] == 24 and proof["rtl_stage_words_checked"] == 92160
    regression = ("Full repository regression is still running."
        if not (OUT/"verification.json").exists() else
        "Full make verify also passed; see [verification receipt](verification.json).")
    text = f"""# VGG conv1_1: measured CPU and GEMV comparison

Existing GEMV completes this small packed-patch pipeline **{r1['offload_vs_mac']:.3f}x
faster than tiled CPU MAC at L=1** and **{r20['offload_vs_mac']:.3f}x at L=20**.
Measured RTL cycles include CPU packing, launch/status handling and software
bias/ReLU. Host placement is excluded. Workload: 4x5x3 input, 64 filters,
stride 1 and one-pixel zero padding.

[Mapping contract](../vgg-conv1_1-mapping.md) · [Measured CSV](programs.csv) ·
[CPU states](states.csv) · [Command intervals](commands.csv) ·
[Proof receipt](proof.json) · [Source/command provenance](provenance.json)

## Whole-job results

A computes one filter at a time with MUL+ADD. B holds four sums in registers,
sharing each input load. C keeps B's reuse and uses the existing MAC instruction.
D uses blocking GEMV. CPU packs inputs and applies bias/ReLU in every variant.
The hardware is identical in all runs.

{chr(10).join(table)}

![Measured whole-job latency sweep](whole-job.png)

## Why the methods differ

**Tiling reduces repeated input reads.** B reduces patch reads from 34,560 to
8,640; weight reads stay at 34,560. At L=20, B is {r20['tiling_speedup']:.3f}x
faster than A. Four sums stay in registers without partial-sum spills;
64 filters divide evenly into tiles of four.

**MAC fusion reduces instruction overhead.** C removes exactly 34,560 CPU
instructions relative to B without changing operand reads. Measured savings
are 172,808, 172,824 and 172,884 cycles at L=1,5,20: five cycles per product,
plus one avoided instruction-cache miss (4+4*L cycles). At L=20 it reduces B's
job time by {(1-1/r20['fusion_speedup'])*100:.2f}%. Unchanged data-read waits
reduce fusion's relative benefit as latency rises.

**Offload reuses the entire patch privately.** D reads 27 shared-RAM patch
words per command, or 540 across 20 commands, and reuses them across filters.
Its 128-word private buffer exceeds the CPU register budget. D/C combines
storage, traffic and control advantages; it is not a pure arithmetic comparison.

{chr(10).join(traffic)}

Every variant also performs 390 input reads during packing, 540 patch writes,
1,280 bias reads and 1,280 raw-output reads. All have 3,104 RAM writes:
540 packed entries + 1,280 raw outputs + 1,280 final outputs + three phase
markers + one completion. Refills and literal/signature reads are separate.

Weights occupy 6,912 bytes but are read 20 times: 138,240 bytes. They account
for {34560/(34560+540)*100:.2f}% of D's accelerator operand reads. This remaining
traffic explains the falling offload speedup at higher latency. Avoiding it
requires a separate weight-residency/reuse model.

![Accepted RAM reads](ram-traffic.png)

## Packing and output processing count

The CPU nested-loop packer checks bounds at runtime and materializes all
20 patches (2,160 bytes): 390 entries read the image, 150 supply padding zeros.
All variants compute 34,560 products, including 9,600 padding-zero products,
then update the single output allocation in place during software bias/ReLU.

{chr(10).join(phase_table)}

For D at L=20, packing occupies {r20['offload_packing_fraction']*100:.2f}% and
bias/ReLU {r20['offload_post_fraction']*100:.2f}% of job time. Their combined share
at L=1 is {(r1['offload_packing_fraction']+r1['offload_post_fraction'])*100:.2f}%.
D's slightly longer postprocessing is one extra instruction-cache miss due to
code placement, with identical output-processing logic.

![Measured phase breakdown](phases.png)

## Proof and limits

Both datasets passed four variants at three latencies: **24 RTL runs**,
**92,160 raw/biased/final comparisons**, and 12,960 packed-entry checks.
The direct Python tensor reference shares no packing or serialized-weight
indexing with the mapped model. Independent RV32 execution matches every
accepted instruction address and cache hit/miss. The harness checks RAM
counts/order, descriptors, blocking, response ownership, vector freshness,
immutable input/weights/biases, completion and disjoint phase/state totals.
Two injected faults are rejected: a code write and a corrupted bias.

At position (1,1), the wrap case tests INT_MAX + bias 1 becoming INT_MIN and
ReLU zero; another filter tests INT_MIN + bias -1 becoming INT_MAX.
Checking biased words before ReLU prevents clipping from hiding errors.
Datasets differ by 114 cycles per matching configuration because their
negative-output counts differ by 19 conditional CPU instructions.

{regression}

Host generator/reference work took {proof['generator_and_reference_wall_seconds']:.4f} seconds in this
run, outside simulated cycles. Immutable operands occupy 7,408 bytes; complete
image text is 34,119-34,263 bytes including code and poisoned scratch/output
regions. These sizes are not physical transfer-time estimates. Initial
placement, upstream conversion, physical transfer and downstream consumption
are unmeasured. Native filter-first weights need no conversion.

These CPU baselines use the same packed-patch pipeline, rather than an optimized
direct convolution. A direct CPU version could avoid materialization and
padding-zero products; CPU kernels could also fuse bias/ReLU before their
first store. Those are useful next comparisons. Full-sized layers need a
separate RAM capacity, tiling and residency model. There is no clock-frequency,
area, energy or full-VGG speedup result. Production defaults and historical
measurements are unchanged.

## Reproduce

From the repository root in WSL Ubuntu:

~~~sh
make conv1-proof
make conv1-study
make conv1-audit
make conv1-plot
python3 scripts/analyze_conv1.py
make verify
~~~

Images, logs, exact traces and builds are generated under
obj_dir/verification/conv1/. Audit checks retained local evidence and source
identities; a fresh checkout must run the study first. Plotting needs matplotlib
and can reuse obj_dir/tiling-plot-packages/ when present. CSVs, receipts and
PNG/SVG graphs are saved here. The existing shared regression runs through
make verify; the new focused harness runs through conv1-study.
"""
    (OUT/"README.md").write_text(text)
    print("PASS: analysis.json and readable report derived from measured CSV")


if __name__ == "__main__":
    main()
