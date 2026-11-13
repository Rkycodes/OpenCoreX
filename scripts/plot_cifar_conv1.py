"""Plot the measured CIFAR Conv1_1 retention schedules."""

import argparse
import csv
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RESULTS = Path(__file__).resolve().parents[1] / "docs/evaluation/cifar-conv1-results"
POLICIES = {
    "pim-per-dot": "PIM per dot",
    "activation-retaining": "Retain activations",
    "weight-reload": "Reload weights per tile",
    "weight-retaining": "Retain weights across tiles",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("measurements", type=Path, nargs="?", default=RESULTS / "programs.csv")
    args = parser.parse_args()
    with args.measurements.open() as source:
        rows = {row["policy"]: row for row in csv.DictReader(source) if row["ram_latency"] == "1"}
    assert all(rows[p]["correctness"] == "PASS" for p in POLICIES)
    for row in rows.values():
        row["setup_and_packing"] = int(row["setup_cycles"]) + int(row["packing_cycles"])
    labels = list(POLICIES.values())
    fig, (cycles, reads) = plt.subplots(1, 2, figsize=(11, 4), layout="constrained")
    fig.suptitle("CIFAR VGG-16 Conv1_1  |  INT32, one-cycle RAM reads", fontweight="bold")
    panels = (
        (cycles, "Whole-job cycles (millions)",
         (("setup_and_packing", "CPU setup and patch packing", "#659bc3"),
          ("compute_cycles", "Compute and command handling", "#285a7b"),
          ("output_phase_cycles", "Output phase", "#d88a40"))),
        (reads, "Convolution operand reads (million words)",
         (("activation_reads", "Packed activations", "#659bc3"),
          ("weight_reads", "Weights", "#285a7b"))),
    )
    for ax, title, components in panels:
        totals = [0.0] * len(labels)
        for column, label, color in components:
            values = [int(rows[policy][column]) / 1e6 for policy in POLICIES]
            ax.barh(labels, values, left=totals, label=label, color=color)
            totals = [total + value for total, value in zip(totals, values)]
        for index, total in enumerate(totals):
            ax.text(total + max(totals) * 0.025, index, f"{total:.2f}", va="center", fontsize=9)
        ax.set_xlim(0, max(totals) * 1.2)
        ax.set_xlabel(title)
        ax.invert_yaxis()
        ax.tick_params(axis="y", length=0)
        ax.spines[["top", "right", "left"]].set_visible(False)
        ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.17), frameon=False, fontsize=8)
    reads.tick_params(axis="y", labelleft=False)
    fig.savefig(args.measurements.with_name("retention.png"), dpi=180)
    plt.close(fig)


if __name__ == "__main__":
    main()
