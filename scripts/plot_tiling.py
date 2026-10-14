"""Plot the recorded larger-vector study; requires matplotlib, no simulator."""
import csv
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import StrMethodFormatter

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "docs/evaluation/tiling-results"
OUT = RESULTS / "graphs"
KS, LS = (16, 32, 64, 128), (1, 2, 5, 10, 20)
rows = list(csv.DictReader((RESULTS / "programs.csv").open()))
data = {(int(r["vector_length"]), int(r["cache_enabled"]), r["mode"], int(r["read_delay"])): r for r in rows}
assert len(data) == len(rows) == 120
COLORS = ("#285da8", "#9466b3", "#23836f", "#c17916", "#b54343")
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11,
                     "axes.spines.top": False, "axes.spines.right": False,
                     "axes.titleweight": "bold", "svg.fonttype": "none"})
OUT.mkdir(parents=True, exist_ok=True)


def cycles(k, cache, mode, latency):
    return int(data[k, cache, mode, latency]["whole_cycles"])


def axis(ax, cache):
    ax.set_title("Cache enabled" if cache else "Cache bypass")
    ax.set_xlabel("Vector length K (32 outputs fixed)")
    ax.set_xticks(KS)
    ax.grid(axis="y", alpha=.2)
    ax.set_axisbelow(True)


def save(fig, name):
    for extension in ("png", "svg"):
        path = OUT / f"{name}.{extension}"
        fig.savefig(path, dpi=180, bbox_inches="tight", facecolor="white")
        if extension == "svg":
            path.write_text("\n".join(line.rstrip() for line in path.read_text().splitlines()) + "\n")
    plt.close(fig)


fig, axes = plt.subplots(1, 2, figsize=(12, 4.8), sharey=True, layout="constrained")
for cache, ax in enumerate(axes):
    for latency, color in zip(LS, COLORS):
        values = [100*(1-cycles(k, cache, "tiled", latency)/cycles(k, cache, "streaming", latency)) for k in KS]
        ax.plot(KS, values, "-o", color=color, label=f"L={latency}")
    axis(ax, cache)
    ax.set_ylim(39, 48)
axes[0].set_ylabel("CPU cycle reduction from tiling (%)")
axes[1].legend(frameon=False, ncols=2)
fig.suptitle("Fourfold fewer vector reads save 41–46% of whole-program CPU cycles", fontsize=14)
save(fig, "tiling-benefit")

fig, axes = plt.subplots(1, 2, figsize=(12, 4.8), sharey=True, layout="constrained")
for cache, ax in enumerate(axes):
    for latency, color in zip(LS, COLORS):
        values = [cycles(k, cache, "tiled", latency)/cycles(k, cache, "offload", latency) for k in KS]
        ax.plot(KS, values, "-o", color=color, label=f"L={latency}")
    axis(ax, cache)
    ax.axhline(1, color="#666666", linewidth=1)
axes[0].set_ylabel("Tiled CPU cycles / cold offload cycles")
axes[1].legend(frameon=False, ncols=2)
fig.suptitle("Digital offload retains an advantage; its K trend depends on latency and caching", fontsize=14)
fig.supxlabel("Offload has 128 private vector words; scalar CPU holds four sums and one vector element", fontsize=10)
save(fig, "remaining-offload-advantage")

fig, axes = plt.subplots(1, 2, figsize=(12, 4.8), sharey=True, layout="constrained")
for latency, ax in zip((1, 20), axes):
    for mode, color, label in (("streaming", COLORS[0], "Streaming CPU"),
                               ("tiled", COLORS[2], "Tiled CPU"), ("offload", COLORS[3], "Cold offload")):
        for cache, style in ((0, "--"), (1, "-")):
            ax.plot(KS, [cycles(k, cache, mode, latency) for k in KS], style+"o", color=color,
                    label=f"{label}, {'cache' if cache else 'bypass'}")
    axis(ax, 0)
    ax.set_title(f"Backing-read latency L={latency}")
    ax.yaxis.set_major_formatter(StrMethodFormatter("{x:,.0f}"))
axes[0].set_ylabel("Reset release through completion (cycles)")
axes[1].legend(frameon=False, fontsize=9)
fig.suptitle("Whole-program costs at the latency endpoints", fontsize=15)
save(fig, "whole-program-cycles")
print(f"PASS: three PNG/SVG figures from all 120 recorded rows: {OUT}")
