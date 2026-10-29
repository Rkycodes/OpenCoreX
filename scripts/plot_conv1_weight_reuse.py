"""Plot and explain measured weight reuse without overwriting the A-D study."""
import csv
import hashlib
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
try:
    import matplotlib
except ModuleNotFoundError:
    sys.path.insert(0,str(ROOT/"obj_dir/tiling-plot-packages"))
    import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT=ROOT/"docs/evaluation/conv1-weight-reuse-results"
BASE=ROOT/"docs/evaluation/conv1-results"
plt.rcParams.update({"font.size":10,"svg.hashsalt":"OpenCoreX-conv1-weight-reuse","svg.fonttype":"none"})


def save(fig,name):
    for ext in ("png","svg"):
        path=OUT/f"{name}.{ext}"
        options={"metadata":{"Date":None}} if ext=="svg" else {}
        fig.savefig(path,dpi=180,facecolor="white",**options)
        if ext=="svg":
            path.write_text("\n".join(line.rstrip() for line in path.read_text().splitlines())+"\n")
    plt.close(fig)


def main():
    e_rows=list(csv.DictReader((OUT/"programs.csv").open()))
    d_rows=[r for r in csv.DictReader((BASE/"programs.csv").open()) if r["mode"]=="offload"]
    assert len(e_rows)==len(d_rows)==6
    indices={mode:{(r["case"],int(r["read_latency"])):r for r in rows}
             for mode,rows in (("D",d_rows),("E",e_rows))}
    def n(mode,case,latency,key):
        return int(indices[mode][case,latency][key])
    comparisons=[]
    table=["| Case | RAM latency | D cycles | E cycles | Extra cycles | E increase |",
           "|---|---:|---:|---:|---:|---:|"]
    for row in e_rows:
        case,latency=row["case"],int(row["read_latency"])
        d,e=n("D",case,latency,"whole_cycles"),int(row["whole_cycles"])
        assert e-d==13348+1193*(latency-1)
        assert n("E",case,latency,"ram_reads")-n("D",case,latency,"ram_reads")==1193
        assert n("E",case,latency,"fetches")-n("D",case,latency,"fetches")==2113
        assert n("E",case,latency,"packing_cycles")==n("D",case,latency,"packing_cycles")
        comparison=dict(case=case,read_latency=latency,d_cycles=d,e_cycles=e,
            extra_cycles=e-d,e_increase_percent=100*(e/d-1),
            compute_delta=n("E",case,latency,"compute_cycles")-n("D",case,latency,"compute_cycles"),
            output_phase_delta=n("E",case,latency,"post_cycles")-n("D",case,latency,"post_cycles"))
        comparisons.append(comparison)
        table.append(f"| {case} | {latency} | {d:,} | {e:,} | {e-d:,} | {100*(e/d-1):.2f}% |")
    (OUT/"comparison.json").write_text(json.dumps(comparisons,indent=2)+"\n")

    fig,axes=plt.subplots(1,2,figsize=(11,4.8),layout="constrained")
    for mode,label,color in (("D","D: buffer activations","#21876d"),("E","E: buffer weights","#ba5b35")):
        axes[0].plot((1,5,20),[n(mode,"wrap",l,"whole_cycles")/1000 for l in (1,5,20)],
            marker="o",lw=2,label=label,color=color)
    axes[0].set_ylabel("Measured whole-job cycles (thousands)")
    axes[0].set_xlabel("Uniform RAM read latency (cycles)")
    axes[0].set_xticks((1,5,20)); axes[0].set_ylim(bottom=0); axes[0].legend(frameon=False)
    axes[0].set_title("Full-width case")
    for offset,case,color in ((-.18,"small","#6f8297"),(.18,"wrap","#ba5b35")):
        values=[next(r["e_increase_percent"] for r in comparisons if r["case"]==case and r["read_latency"]==l)
                for l in (1,5,20)]
        axes[1].bar([x+offset for x in range(3)],values,width=.34,label=case,color=color)
    axes[1].set_xticks(range(3),("1","5","20")); axes[1].set_ylim(0,4)
    axes[1].set_xlabel("Uniform RAM read latency (cycles)")
    axes[1].set_ylabel("E cycle increase over D (%)"); axes[1].legend(frameon=False)
    axes[1].set_title("Both datasets: weight reuse costs more")
    for ax in axes:
        ax.spines[["top","right"]].set_visible(False); ax.grid(axis="y",alpha=.15)
    fig.suptitle("64 filters, 20 positions: changing which operand stays local\n"
                 "CPU packing + launch/status + output processing included; host placement excluded",fontsize=12)
    save(fig,"whole-job")

    fig,ax=plt.subplots(figsize=(8,4.8),layout="constrained")
    patches=[n(m,"wrap",20,"patch_reads") for m in ("D","E")]
    weights=[n(m,"wrap",20,"weight_reads") for m in ("D","E")]
    ax.bar((0,1),patches,width=.55,color="#d6a752",label="Activations / packed patches")
    ax.bar((0,1),weights,bottom=patches,width=.55,color="#3d7ca8",label="Weights")
    for i,(p,w) in enumerate(zip(patches,weights)):
        ax.text(i,p+w+600,f"{p+w:,} total",ha="center")
        if p>2000: ax.text(i,p/2,f"{p:,}",ha="center",va="center")
        if w>2000: ax.text(i,p+w/2,f"{w:,}",ha="center",va="center",color="white")
    ax.set_xticks((0,1),("D: buffer one patch","E: buffer one filter"))
    ax.set_ylabel("Accepted GEMV operand reads (32-bit words)")
    ax.set_ylim(0,42000); ax.spines[["top","right"]].set_visible(False)
    fig.legend(*ax.get_legend_handles_labels(),loc="outside lower center",ncol=2,frameon=False)
    fig.suptitle("Weight reads fall 20x; activation reads rise 64x\n"
                 "Measured on unchanged RTL; 1,188 more operand reads in E",fontsize=12)
    save(fig,"operand-traffic")

    fig,ax=plt.subplots(figsize=(8,4.8),layout="constrained")
    selected=[next(r for r in comparisons if r["case"]=="wrap" and r["read_latency"]==l) for l in (1,5,20)]
    compute=[r["compute_delta"] for r in selected]
    output=[r["output_phase_delta"] for r in selected]
    ax.bar(range(3),compute,width=.6,label="Computation / launch / status",color="#3d7ca8")
    ax.bar(range(3),output,bottom=compute,width=.6,label="Gather + bias/ReLU output phase",color="#479682")
    for i,r in enumerate(selected):
        ax.text(i,r["extra_cycles"]+600,f"+{r['extra_cycles']:,}",ha="center")
    ax.set_xticks(range(3),("1","5","20")); ax.set_xlabel("Uniform RAM read latency (cycles)")
    ax.set_ylabel("Additional E cycles relative to D"); ax.set_ylim(0,41000)
    ax.spines[["top","right"]].set_visible(False)
    fig.legend(*ax.get_legend_handles_labels(),loc="outside lower center",ncol=1,frameon=False)
    fig.suptitle("Where E's extra time goes: full-width case\n"
                 "Setup and CPU packing are identical; reordering is fused into output processing",fontsize=12)
    save(fig,"extra-cycles")

    phase=["| L=20, wrap case | Setup | Packing | Computation | Output processing | Whole job |",
           "|---|---:|---:|---:|---:|---:|"]
    for mode in ("D","E"):
        phase.append("| "+mode+" | "+" | ".join(f"{n(mode,'wrap',20,key):,}" for key in
            ("setup_cycles","packing_cycles","compute_cycles","post_cycles","whole_cycles"))+" |")
    verification=("Full make verify passed; see [receipt](verification.json)."
                  if (OUT/"verification.json").exists() else "Full make verify is still running.")
    proof=json.loads((OUT/"proof.json").read_text())
    report=f"""# Conv1_1 weight reuse: fewer weight reads, more total work

For this 4x5 input, **buffering weights takes 3.11-3.12% more cycles** than
buffering activations. Weight reads fall 20x, but activation reads rise 64x,
and E launches 64 commands instead of 20. Both use unchanged accelerator RTL.
This is a measured dataflow comparison for 64 filters and 20 positions.

[Mapping and costs](../vgg-conv1_1-weight-reuse.md) ·
[Original A-D study](../conv1-results/README.md) · [E measurements](programs.csv) ·
[Computed comparisons](comparison.json) · [Proof](proof.json) ·
[Source/command provenance](provenance.json)

## Whole-job comparison

D retains one 27-value patch while streaming 64 filters. E retains one
filter's 27 weights while streaming 20 patches. All tensors, arithmetic,
padding, software bias/ReLU and runtime patch packing match the original study.
Timing includes reset release through accepted completion. Host placement is excluded.

{chr(10).join(table)}

![Measured D/E timing](whole-job.png)

## Reuse trades one stream for another

| Shared-RAM activity | D: activation reuse | E: weight reuse |
|---|---:|---:|
| Patch reads during GEMV | 540 | 34,560 |
| Weight reads during GEMV | 34,560 | 1,728 |
| GEMV operand reads | 35,100 | 36,288 |
| Commands and status reads | 20 | 64 |
| MMIO writes | 140 | 448 |
| All RAM reads, including instruction refills | 38,160 | 39,353 |
| All RAM writes | 3,104 | 3,104 |
| CPU instructions, wrap case | 24,211 | 26,324 |
| Data allocation, excluding code/control/private buffer | 14,688 bytes | 19,808 bytes |

E saves 32,832 weight reads but adds 34,020 activation reads: 1,188 more
GEMV reads. One extra instruction-cache miss adds four refill reads, and
one additional literal read brings the total RAM difference to 1,193.
The 128-word private vector buffer is identical in both methods; E stores
one filter locally, not all 64 filters.

![Measured operand traffic](operand-traffic.png)

For K input terms, P positions and F filters, D reads K*P + K*P*F operands;
E reads K*F + K*P*F. Their difference is K*(F-P). Here that is
27*(64-20)=1,188. Weight reuse saves operands when P exceeds F, but this is
an analytical traffic crossover, not a measured performance result for larger
images. Command limits, output layout and capacity still matter.

## Output conversion is counted, without a separate copy pass

E writes raw values filter-first into a separate 5,120-byte allocation.
The CPU gathers them in position-first order while adding bias and applying
ReLU. It performs the same 1,280 raw reads, 1,280 bias reads and 1,280 final
stores as D; extra work is address/control instructions, not another RAM copy.
Biases are deliberately read per output in both methods.

E executes 2,113 more CPU instructions: 792 from 44 additional command-loop
iterations, and 1,321 from gathering/output setup. This includes 1,280 extra
source/destination pointer updates, 40 position-loop instructions and one load.
Output-phase differences include cache/code-placement effects and therefore
are not a standalone conversion benchmark.

{chr(10).join(phase)}

At L=1 E adds 5,412 compute-phase cycles and 7,936 output-phase cycles.
At L=20 the differences are 27,984 and 8,031 cycles. Packing and setup match.
Across both datasets the exact measured identity is
E-D = 13,348 + 1,193*(L-1): additional RAM latency accounts for the growing
absolute gap while base instruction/control work accounts for the intercept.

![Additional cycles by phase](extra-cycles.png)

## Proof, provenance and limits

Six E RTL runs passed across both datasets and L=1,5,20: 23,040 raw/biased/final
comparisons, 7,680 gathered-raw checks and 3,240 packed-entry checks.
Independent RV32 execution matches every accepted instruction/cache event.
The harness checks raw filter-first stores, gathered addresses and values,
canonical final outputs, memory ownership, CPU blocking, descriptors, status,
buffer residency and immutable inputs/weights/biases. Code-write, corrupted-bias
and wrong-gather faults are all rejected. Both mappings use the same independent
direct Python tensor reference, including directed overflow before ReLU.

Original A-D source and image identities and saved measurement hashes are
checked before comparison. Its evidence files and scripts are unchanged.
E results and logs are stored separately. {verification}

The CPU packer is byte-identical through its phase marker, ensuring equal
runtime packing. E uses the existing 128-word/128-output benchmark parameters;
production defaults are unchanged. Host generator/reference work took
{proof['generator_and_reference_wall_seconds']:.4f} seconds here, excluded from RTL cycles.
Initial placement, physical transfers, upstream conversion and downstream
consumption remain unmeasured. These results say nothing about full-VGG
performance, frequency, area or energy.

Next useful experiment: vary spatial positions around the 64-filter traffic
crossover while keeping explicit output-conversion and capacity accounting.
Beyond 128 positions, E must split output commands and model filter reuse
across those commands; larger-layer claims require that separate study.

## Reproduce

From the repository root in WSL:

~~~sh
make conv1-weight-reuse-proof
make conv1-weight-reuse-study
make conv1-weight-reuse-audit
make conv1-weight-reuse-plot
make verify
~~~

A-D data is already recorded in the original results directory. E verifies
those source/measurement identities and does not rerun or overwrite A-D results.
Generated images, logs and exact traces live under
obj_dir/verification/conv1_weight_reuse/. Auditing requires those retained local
artifacts; a fresh checkout should run the study first. Plotting uses matplotlib
and can reuse the existing obj_dir/tiling-plot-packages/ installation.
"""
    (OUT/"README.md").write_text(report)
    artifacts=list(OUT.glob("*.png"))+list(OUT.glob("*.svg"))+[OUT/"README.md",OUT/"comparison.json"]
    receipt=dict(matplotlib=matplotlib.__version__,
        script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        source_csv_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in (OUT/"programs.csv",BASE/"programs.csv")},
        report_artifact_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in artifacts})
    (OUT/"report-provenance.json").write_text(json.dumps(receipt,indent=2)+"\n")
    print("PASS: three D/E comparison figures, measured analysis and report provenance")


if __name__=="__main__":
    main()
