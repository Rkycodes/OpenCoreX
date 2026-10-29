"""Plot measured conv1 RTL results. Uses matplotlib; never substitutes estimates."""
import csv
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
try:
    import matplotlib
except ModuleNotFoundError:
    # Reuse the repository's existing ignored plotting installation if available.
    sys.path.insert(0,str(ROOT/"obj_dir/tiling-plot-packages"))
    import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = ROOT/"docs/evaluation/conv1-results"
MODES = ("streaming","tiled","mac","offload")
LABELS = ("A: streaming","B: tiled","C: tiled MAC","D: GEMV")
COLORS = ("#66778b","#2478b5","#bb5c35","#21876d")
CASES = ("small","wrap")
plt.rcParams.update({"font.size":10,"svg.hashsalt":"OpenCoreX-conv1","axes.titleweight":"bold"})


def save(fig,name):
    for extension in ("png","svg"):
        kwargs = {"metadata":{"Date":None}} if extension == "svg" else {}
        target = OUT/f"{name}.{extension}"
        fig.savefig(target,dpi=180,facecolor="white",**kwargs)
        if extension == "svg":
            target.write_text("\n".join(line.rstrip() for line in target.read_text().splitlines())+"\n")
    plt.close(fig)


def main():
    rows = list(csv.DictReader((OUT/"programs.csv").open()))
    assert len(rows) == 24, "Expected both cases, all four variants and L=1,5,20"
    index = {(r["case"],r["mode"],int(r["read_latency"])):r for r in rows}
    assert len(index) == 24 and all(r["cache_enabled"]=="1" for r in rows)
    def value(case,mode,latency,key):
        return int(index[case,mode,latency][key])
    fig,axes = plt.subplots(1,2,figsize=(11,4.8),layout="constrained",sharey=True)
    for ax,case in zip(axes,CASES):
        for mode,label,color in zip(MODES,LABELS,COLORS):
            ax.plot((1,5,20),[value(case,mode,l,"whole_cycles")/1000 for l in (1,5,20)],
                    marker="o",lw=2,label=label,color=color)
        ax.set_title("Small mixed signs" if case=="small" else "Full-width + directed overflow")
        ax.set_xlabel("Uniform RAM read latency (cycles)")
        ax.set_xticks((1,5,20)); ax.set_ylim(bottom=0); ax.grid(alpha=.2)
        ax.spines[["top","right"]].set_visible(False)
    axes[0].set_ylabel("Measured whole-job cycles (thousands)")
    fig.legend(*axes[0].get_legend_handles_labels(),loc="outside lower center",ncol=4,frameon=False)
    fig.suptitle("4x5x3 input, 64 filters: CPU packing + computation + CPU bias/ReLU\n"
                 "Cold instruction cache per job; host placement excluded",fontsize=12)
    save(fig,"whole-job")

    fig,axes = plt.subplots(1,2,figsize=(11,5),layout="constrained",sharey=True)
    phases = ("setup_cycles","packing_cycles","compute_cycles","post_cycles")
    phase_labels = ("Setup","CPU packing","Computation / launch / status","CPU bias + ReLU")
    phase_colors = ("#aab6c3","#d7a854","#3d7ca8","#479682")
    for ax,case in zip(axes,CASES):
        bottom = [0.0]*4
        for key,label,color in zip(phases,phase_labels,phase_colors):
            heights = [value(case,mode,20,key)/1000 for mode in MODES]
            ax.bar(range(4),heights,bottom=bottom,color=color,label=label,width=.65)
            bottom = [a+b for a,b in zip(bottom,heights)]
        for x,total in enumerate(bottom):
            ax.text(x,total+max(bottom)*.015,f"{total:,.0f}",ha="center",fontsize=9)
        ax.set_title("Small mixed signs" if case=="small" else "Full-width + directed overflow")
        ax.set_xticks(range(4),("A","B","C","D")); ax.set_xlabel("Variant")
        ax.set_ylim(0,max(bottom)*1.12); ax.spines[["top","right"]].set_visible(False)
    axes[0].set_ylabel("Measured cycles (thousands)")
    fig.legend(*axes[0].get_legend_handles_labels(),loc="outside lower center",ncol=2,frameon=False)
    fig.suptitle("Whole-job phase accounting at RAM read latency L=20\n"
                 "Every phase and marker is included; host placement excluded",fontsize=12)
    save(fig,"phases")

    fig,ax = plt.subplots(figsize=(9,5),layout="constrained")
    categories = (("input_reads","literal_reads","signature_reads"),("patch_reads",),
                  ("weight_reads",),("bias_reads","post_reads"),("refill_reads",))
    names = ("Input + control","Packed patch","Weights","Bias + raw output","Instruction refills")
    colors = ("#b3b9c4","#d7a854","#3d7ca8","#479682","#ad729c")
    bottom = [0.0]*4
    for keys,label,color in zip(categories,names,colors):
        heights = [sum(value("wrap",mode,20,key) for key in keys)/1000 for mode in MODES]
        ax.bar(range(4),heights,bottom=bottom,color=color,label=label,width=.65)
        bottom = [a+b for a,b in zip(bottom,heights)]
    for x,total in enumerate(bottom):
        ax.text(x,total+1,f"{total:,.2f}",ha="center",fontsize=9)
    ax.set_xticks(range(4),LABELS); ax.set_ylim(0,max(bottom)*1.13)
    ax.set_ylabel("Accepted 32-bit RAM reads (thousands)")
    ax.spines[["top","right"]].set_visible(False)
    fig.legend(*ax.get_legend_handles_labels(),loc="outside lower center",ncol=3,frameon=False)
    fig.suptitle("RAM traffic: full-width case, L=20, instruction cache enabled\n"
                 "Same 34,560 weight reads and 3,104 RAM writes in every variant",fontsize=12)
    save(fig,"ram-traffic")
    print("PASS: three PNG/SVG figures generated from 24 measured RTL rows")


if __name__ == "__main__":
    main()
