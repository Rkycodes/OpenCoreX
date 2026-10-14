"""Plot recorded scaling measurements; requires matplotlib (no simulator run)."""
import csv
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import StrMethodFormatter

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "docs/evaluation/scaling-results"
OUT = RESULTS / "graphs"
NS = (32, 64, 128)
LS = (1, 2, 5, 10, 20)
COLORS = ("#2563a6", "#d97706", "#16816a")
rows = list(csv.DictReader((RESULTS / "programs.csv").open()))
assert len(rows) == 60
data = {(int(r["output_count"]), int(r["cache_enabled"]), r["mode"],
         int(r["read_delay"])): r for r in rows}
assert len(data) == 60
def value(n, cache, mode, latency, field="whole_cycles"):
    return int(data[n, cache, mode, latency][field])
def ratio(n, cache, latency):
    return value(n, cache, "resident", latency) / value(n, cache, "offload", latency)
for n in NS:
    for cache in (0, 1):
        for latency in LS:
            assert abs(ratio(n, cache, latency) -
                       float(data[n, cache, "resident", latency]["cpu_offload_ratio"])) < 1e-6
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11,
                     "axes.spines.top": False, "axes.spines.right": False,
                     "axes.titleweight": "bold", "svg.fonttype": "none",
                     "savefig.facecolor": "white"})
OUT.mkdir(parents=True, exist_ok=True)
def grid(ax):
    ax.grid(axis="y", alpha=.2)
    ax.set_axisbelow(True)
def latency_axis(ax):
    ax.set_xticks(LS)
    ax.set_xlabel("Backing-read latency L (cycles)")
    grid(ax)
def save(fig, name):
    for ext in ("png", "svg"):
        fig.savefig(OUT / f"{name}.{ext}", dpi=200, bbox_inches="tight")
        if ext == "svg":
            path = OUT / f"{name}.{ext}"
            path.write_text("\n".join(line.rstrip() for line in path.read_text().splitlines()) + "\n")
    plt.close(fig)

fig, axes = plt.subplots(1, 3, figsize=(14, 4.5), sharey=True, layout="constrained")
for ax, n in zip(axes, NS):
    ax.plot(LS, [ratio(n, 0, l) for l in LS], "--o", color=COLORS[0], label="Cache bypass")
    ax.plot(LS, [ratio(n, 1, l) for l in LS], "-s", color=COLORS[2], label="Cache enabled")
    ax.axhline(1, color="#555555", linewidth=1)
    ax.set_title(f"{n} outputs")
    latency_axis(ax)
axes[0].set_ylabel("CPU cycles / offload cycles")
axes[0].legend(frameon=False)
fig.suptitle("Offload advantage after instruction caching", fontsize=16)
save(fig, "offload-advantage")

fig, axes = plt.subplots(1, 3, figsize=(14, 4.5), sharey=True, layout="constrained")
for ax, n in zip(axes, NS):
    for mode, color, label, marker in (
        ("resident", COLORS[0], "Scalar CPU", "o"),
        ("offload", COLORS[1], "Digital offload", "s")):
        savings = [100 * (value(n, 0, mode, l) - value(n, 1, mode, l)) /
                   value(n, 0, mode, l) for l in LS]
        ax.plot(LS, savings, marker=marker, color=color, label=label)
    ax.axhline(0, color="#555555", linewidth=1)
    ax.set_title(f"{n} outputs")
    latency_axis(ax)
axes[0].set_ylabel("Cycle reduction versus bypass (%)")
axes[0].legend(frameon=False)
fig.suptitle("When does the instruction cache help?", fontsize=16)
fig.supxlabel("Positive = fewer cycles; negative = cache overhead exceeds avoided waits", fontsize=10)
save(fig, "cache-benefit")

fig, axes = plt.subplots(1, 3, figsize=(14, 4.5), sharey=True, layout="constrained")
for ax, n in zip(axes, NS):
    for mode, color, label in (("resident", COLORS[0], "Scalar CPU"),
                               ("offload", COLORS[1], "Digital offload")):
        for cache, style, marker in ((0, "--", "o"), (1, "-", "s")):
            ax.plot(LS, [value(n, cache, mode, l) for l in LS],
                    linestyle=style, marker=marker, color=color,
                    label=f"{label}, {'cache' if cache else 'bypass'}")
    ax.set_title(f"{n} outputs")
    ax.yaxis.set_major_formatter(StrMethodFormatter("{x:,.0f}"))
    latency_axis(ax)
axes[0].set_ylabel("Whole-program cycles")
axes[0].legend(frameon=False, fontsize=9)
fig.suptitle("Absolute execution cost across all 60 configurations", fontsize=16)
save(fig, "whole-program-cycles")

fig, axes = plt.subplots(1, 2, figsize=(11, 4.5), layout="constrained")
for ax, per_output in zip(axes, (False, True)):
    for mode, color, label in (("resident", COLORS[0], "Scalar CPU"),
                               ("offload", COLORS[1], "Digital offload")):
        ax.plot(NS, [value(n, 1, mode, 20)/(n if per_output else 1) for n in NS],
                "-o", color=color, label=label)
    ax.set_xticks(NS)
    ax.set_xlabel("Output count N")
    ax.set_ylabel("Cycles per output" if per_output else "Whole-program cycles")
    ax.yaxis.set_major_formatter(StrMethodFormatter("{x:,.0f}"))
    ax.set_title("Cost per output" if per_output else "Total execution cost")
    grid(ax)
axes[0].legend(frameon=False)
fig.suptitle("At L=20: fixed costs amortize while the absolute gap grows", fontsize=15)
fig.supxlabel("Cache enabled; vector length 16, one MAC lane, fixed 1 MiB RAM", fontsize=10)
save(fig, "output-scaling")
print(f"Created four figures in PNG and SVG: {OUT}")
