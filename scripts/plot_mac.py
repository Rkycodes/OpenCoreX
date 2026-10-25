"""Plot measured GEMM cycles per mathematical MAC (requires matplotlib)."""
import csv
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"docs/evaluation/mac-results"
rows=list(csv.DictReader((OUT/"programs.csv").open()))
fig,axes=plt.subplots(1,3,figsize=(13,4),sharey=True,layout="constrained")
colors=("#7b8796","#2876b8","#ba5330","#278266")
for ax,latency in zip(axes,(1,5,20)):
    for mode,label,color in zip(("streaming","tiled","mac","offload"),
        ("Streaming CPU","Tiled MUL + ADD","Tiled MAC","Digital offload"),colors):
        points=sorted((int(r["order"]),float(r["cycles_per_mac"])) for r in rows
                      if r["mode"]==mode and int(r["read_delay"])==latency and int(r["cache_enabled"])==1)
        ax.plot(*zip(*points),marker="o",label=label,color=color)
    ax.set_title(f"Backing-read latency L = {latency}")
    ax.set_xscale("log",base=2); ax.set_xticks((16,32,64,128),(16,32,64,128))
    ax.set_xlabel("Square matrix size N"); ax.grid(alpha=.2)
    ax.spines[["top","right"]].set_visible(False)
axes[0].set_ylabel("Whole-job cycles / mathematical MAC")
axes[0].set_ylim(bottom=0)
fig.legend(*axes[0].get_legend_handles_labels(),loc="outside lower center",ncol=4,frameon=False,fontsize=10)
fig.suptitle("OpenCoreX GEMM: measured RTL cycles, cold instruction cache")
for ext in ("png","svg"):
    fig.savefig(OUT/f"cycles-per-mac.{ext}",dpi=180,facecolor="white")
plt.close(fig)
print("PASS: cycles-per-mac.png and .svg rendered from measured CSV")
