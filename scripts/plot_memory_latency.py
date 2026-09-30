#!/usr/bin/env python3
"""Generate meeting figures solely from the measured sweep CSVs (Matplotlib 3.10.8)."""
import csv
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/evaluation/latency-results"


def rows(name):
    with (OUT / name).open() as f:
        return [{k: int(v) if k not in ("policy", "mode") else v
                 for k, v in row.items()} for row in csv.DictReader(f)]


def main():
    programs, commands = rows("programs.csv"), rows("commands.csv")
    plt.rcParams.update({"font.size": 11, "axes.spines.top": False,
                         "axes.spines.right": False, "svg.fonttype": "none", "svg.hashsalt": "OpenCoreX-memory-latency",
                         "savefig.facecolor": "white"})
    names = {"looped": "Looped CPU", "streaming": "Streaming CPU",
             "resident": "Resident CPU", "offload": "32-bit PIM offload"}
    colors = {"looped": "#64748b", "streaming": "#ca8a04",
              "resident": "#2563eb", "offload": "#047857"}
    fig, axes = plt.subplots(1, 2, figsize=(12.8, 5.5), sharey=True)
    for ax, policy, title in zip(axes, ("unified", "fixed_fetch"),
                                ("Uniform unified RAM: fetch and data = L",
                                 "Sensitivity only: fetch = 1, data = L")):
        for mode in names:
            data = [r for r in programs if r["policy"] == policy and r["mode"] == mode]
            ax.plot([r["read_delay"] for r in data], [r["whole_cycles"] for r in data],
                    marker="o", linewidth=2, color=colors[mode], label=names[mode])
        ax.set_title(title, fontsize=12, pad=12)
        ax.set_xlabel("Read response latency L (acceptance → consumption edges)")
        ax.set_xticks([1, 2, 5, 10, 20])
        ax.grid(axis="y", alpha=.2)
        ax.set_ylim(0, 132000)
        ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value/1000:.0f}k"))
    axes[0].set_ylabel("Whole-program cycles through completion store")
    axes[0].legend(frameon=False, loc="upper left")
    fig.suptitle("Matched memory latency: control flow and fetch assumptions matter", fontsize=16, y=.98)
    fig.text(.5, .015, "Same RAM operands; host placement excluded; single port / one outstanding read. Synthetic sensitivity, not calibrated DRAM.",
             ha="center", fontsize=10)
    fig.tight_layout(rect=(0, .055, 1, .94))
    for ext in ("svg", "png"):
        fig.savefig(OUT / f"whole-program.{ext}", dpi=180, metadata={"Date": None})
    plt.close(fig)

    data = [r for r in commands if r["policy"] == "unified" and r["mode"] == "cold_warm"]
    cold, warm = ([r for r in data if r["command"] == c] for c in (0, 1))
    delays = [r["read_delay"] for r in cold]
    gaps = [a["execution_cycles"]-b["execution_cycles"] for a,b in zip(cold,warm)]
    fig, axes = plt.subplots(1, 3, figsize=(14, 5.3))
    axes[0].plot(delays, [r["execution_cycles"] for r in cold], "o-", label="Cold: 16 vector reads", color="#2563eb")
    axes[0].plot(delays, [r["execution_cycles"] for r in warm], "s--", label="Warm: 0 vector reads", color="#047857")
    axes[0].set_title("PIM execution boundary", fontsize=12)
    axes[0].set_ylabel("START → final output cycles")
    axes[0].legend(frameon=False, fontsize=9)
    axes[1].plot(delays, gaps, "o-", color="#7c3aed")
    for x,y in zip(delays,gaps):
        axes[1].annotate(str(y), (x,y), xytext=(0,7), textcoords="offset points", ha="center", fontsize=10)
    axes[1].set_ylim(0, 350)
    axes[1].set_title("Warm execution saving = 1 + 16(L − 1)", fontsize=11)
    axes[1].set_ylabel("Cold minus warm cycles")
    for ax in axes[:2]:
        ax.set_xlabel("RAM read response latency L")
        ax.set_xticks(delays)
        ax.grid(axis="y", alpha=.2)
    r20 = [r for r in programs if r["policy"] == "unified" and r["read_delay"] == 20 and r["mode"] in names]
    fetch = [r["fetch_wait"] for r in r20]
    other = [r["cpu_data_wait"]+r["pim_wait"] for r in r20]
    x = range(len(r20))
    axes[2].bar(x, fetch, label="CPU instruction-fetch wait", color="#2563eb")
    axes[2].bar(x, other, bottom=fetch, label="CPU/PIM data-read wait", color="#94a3b8")
    axes[2].set_xticks(list(x), ["Looped", "Stream", "Resident", "Offload"], rotation=20)
    axes[2].set_title("Added RAM wait at L=20, unified policy", fontsize=11)
    axes[2].set_ylabel("Read wait cycles (L − 1 per accepted read)")
    axes[2].legend(frameon=False, fontsize=8)
    axes[2].yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value/1000:.0f}k"))
    fig.suptitle("Vector reuse saves external waits; matrix reads remain 512 per command", fontsize=16, y=.98)
    fig.text(.5,.015, "Cold and warm execution curves are identical under both fetch policies. Warm follows a verified cold fill, with no reset/invalidation.",
             ha="center", fontsize=10)
    fig.tight_layout(rect=(0,.05,1,.94))
    for ext in ("svg", "png"):
        fig.savefig(OUT / f"pim-reuse-and-fetch.{ext}", dpi=180, metadata={"Date": None})
    plt.close(fig)


if __name__ == "__main__":
    main()
