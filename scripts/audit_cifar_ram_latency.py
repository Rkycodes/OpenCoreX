#!/usr/bin/env python3
"""Audit the matched 1 MiB CIFAR sweep and reproduce its figures and energy estimates."""
import argparse
import csv
import hashlib
import json
from itertools import product
from pathlib import Path

POLICIES = ("activation-retaining", "weight-reload", "weight-retaining")
LAYERS = {"Conv1_2": (4096, 576), "Conv2_1": (8192, 576), "Conv2_2": (3584, 1152)}
PHASES = ("setup_cycles", "packing_cycles", "compute_cycles", "combine_cycles",
          "output_phase_cycles")
READS = ("input_reads", "activation_reads", "weight_reads", "fetch_reads",
         "control_reads", "psum_reads", "gather_reads")
WRITES = ("patch_writes", "psum_writes", "output_writes", "gather_writes")
SCENARIOS = {
    "reference": (1.5, .25, .05, .002),
    "low-write-cost": (.25, .25, .05, .002),
    "high-write-cost": (4, .25, .05, .002),
    "low-mac-cost": (1.5, .025, .05, .002),
    "high-mac-cost": (1.5, 2.5, .05, .002),
    "low-cpu-cost": (1.5, .25, 0, .002),
    "high-cpu-cost": (1.5, .25, 1, .002),
    "zero-static-cost": (1.5, .25, .05, 0),
    "high-static-cost": (1.5, .25, .05, .1),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_csv(path, rows):
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def read_run(run, results, sources, manifests):
    with (run / "programs.csv").open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    case_paths = {(path.parent.name, path.stem): path for path in run.glob("*/*-L*.json")}
    for row in rows:
        layer, policy, delay = row["workload"], row["policy"], int(row["ram_latency"])
        key = (layer, delay, policy)
        require(layer in LAYERS and policy in POLICIES and 1 <= delay <= 5, f"Unknown case {key}")
        require(row["correctness"] == "PASS" and int(row["applied_delay"]) == delay,
                f"Unverified case {key}")
        endpoint = "PASS" if delay in (1, 5) else "N/A"
        require(row["historical_match"] == endpoint and not row["failure"],
                f"Historical comparison failed for {key}")
        receipt_path = case_paths[layer.lower(), f"{policy}-L{delay}"]
        receipt = json.loads(receipt_path.read_text())
        manifest_path = receipt_path.with_name("manifest.json")
        manifest_hash = sha256(manifest_path)
        if manifest_hash not in manifests:
            manifest = json.loads(manifest_path.read_text())
            require(manifest["configuration"]["ram_words"] == 262144,
                    f"Expected 1 MiB in {manifest_path}")
            manifests[manifest_hash] = manifest
        require(list(receipt["manifest_sha256"].values()) == [manifest_hash],
                f"Manifest hash mismatch for {key}")
        log_hash = sha256(receipt_path.with_suffix(".log"))
        require(list(receipt["log_sha256"].values()) == [log_hash], f"Log hash mismatch for {key}")
        require({field: str(receipt["result"][field]) for field in row} == row,
                f"CSV disagrees with case receipt for {key}")
        audit_counters(row, key)
        require(key not in results or results[key] == row, f"Replays disagree for {key}")
        results[key] = row
        sources.append(dict(workload=layer, delay=delay, policy=policy, run=run.name,
                            manifest_sha256=manifest_hash, command=receipt["command"],
                            log_sha256=log_hash))


def audit_counters(row, key):
    counts = {field: int(row[field]) for field in (*PHASES, *READS, *WRITES, "cycles",
              "ram_reads", "ram_writes", "ram_bytes", "outputs_checked", "pim_macs",
              "cpu_non_wait_cycles", "cpu_wait_cycles")}
    outputs, terms = LAYERS[key[0]]
    require(counts["cycles"] == sum(counts[field] for field in PHASES), f"Phase sum for {key}")
    require(counts["cycles"] == counts["cpu_non_wait_cycles"] + counts["cpu_wait_cycles"],
            f"CPU cycle split for {key}")
    require(counts["ram_reads"] == sum(counts[field] for field in READS), f"Read sum for {key}")
    require(counts["ram_writes"] == 5 + sum(counts[field] for field in WRITES), f"Write sum for {key}")
    require(counts["ram_bytes"] == 4 * (counts["ram_reads"] + counts["ram_writes"]),
            f"Byte sum for {key}")
    require(counts["outputs_checked"] == outputs and counts["pim_macs"] == outputs * terms,
            f"Workload mismatch for {key}")


def energy_table(results):
    for (layer, delay), scenario in product(product(LAYERS, range(1, 6)), SCENARIOS):
        write, mac, cpu, static = SCENARIOS[scenario]
        energies = {}
        for policy in POLICIES:
            row = results[layer, delay, policy]
            dynamic = (int(row["ram_reads"]) + write * int(row["ram_writes"])
                       + mac * int(row["pim_macs"]) + cpu * int(row["cpu_non_wait_cycles"]))
            energies[policy] = dynamic, static * int(row["cycles"])
        reference = sum(energies[POLICIES[0]])
        minimum = min(map(sum, energies.values()))
        for policy, (dynamic, leakage) in energies.items():
            yield dict(workload=layer, delay=delay, scenario=scenario, policy=policy,
                       read_coefficient=1, write_coefficient=write, mac_coefficient=mac,
                       cpu_coefficient=cpu, static_coefficient=static,
                       dynamic_units=f"{dynamic:.3f}", static_units=f"{leakage:.3f}",
                       total_over_activation=f"{(dynamic + leakage) / reference:.8f}",
                       lowest_energy=dynamic + leakage == minimum)


def audit_delay_growth(results):
    for layer, policy in product(LAYERS, POLICIES):
        first = results[layer, 1, policy]
        for delay in range(2, 6):
            row = results[layer, delay, policy]
            key = (layer, delay, policy)
            require(all(row[field] == first[field] for field in (*READS, *WRITES)),
                    f"RAM traffic changed with delay for {key}")
            require(int(row["cycles"]) - int(first["cycles"])
                    == (delay - 1) * int(first["ram_reads"]),
                    f"Cycle growth does not match extra read waits for {key}")


def plot(results, output):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams.update({"axes.spines.top": False, "axes.spines.right": False,
                         "svg.hashsalt": "OpenCoreX-cifar-audit", "font.size": 10})
    fig, (trends, gaps) = plt.subplots(2, 3, figsize=(11.3, 5.6),
                                      height_ratios=(2, 1), sharex="col",
                                      layout="constrained")
    delays = range(1, 6)
    colors = ("#136ea0", "#757575", "#c45024")
    for layer, trend, gap_axis in zip(LAYERS, trends, gaps):
        activation = [int(results[layer, delay, POLICIES[0]]["cycles"]) for delay in delays]
        for policy, style, color in zip(POLICIES, ("o-", "x--", "s-"), colors):
            cycles = [int(results[layer, delay, policy]["cycles"]) for delay in delays]
            trend.plot(delays, [count / 1e6 for count in cycles],
                       style, color=color, label=policy)
            gap_axis.plot(delays, [(count - baseline) / 1000
                                  for count, baseline in zip(cycles, activation)],
                          style if policy != POLICIES[0] else "-", color=color)
        trend.set_title(layer)
        trend.grid(axis="y", alpha=.25)
        gap_axis.set(xlabel="RAM read delay (cycles)", xticks=list(delays))
        gap_axis.grid(axis="y", alpha=.25)
    trends[0].set_ylabel("Whole-job cycles (millions)")
    gaps[0].set_ylabel("vs. activation (kcycles)")
    trends[0].legend(frameon=False, fontsize=8)
    fig.suptitle("Matched 1 MiB CIFAR convolution slices")
    fig.savefig(output / "cycles-vs-delay.svg", metadata={"Date": None})
    plt.close(fig)

    fig, axes = plt.subplots(1, 3, figsize=(11.3, 3.8), layout="constrained", sharey=True)
    labels = ("Setup", "Packing", "Compute", "CPU combine", "Output / gather")
    palette = ("#929da4", "#9478aa", "#136ea0", "#54a873", "#c45024")
    for layer, axis in zip(LAYERS, axes):
        def gap(delay, field):
            return (int(results[layer, delay, POLICIES[2]][field])
                    - int(results[layer, delay, POLICIES[0]][field])) / 1000

        transitions = [(lo, lo + 1) for lo in range(1, 5)
                       if (gap(lo, "cycles") > 0) != (gap(lo + 1, "cycles") > 0)]
        shown = sorted({delay for pair in transitions for delay in pair}) or [1, 5]
        positive = [0.0] * len(shown)
        negative = [0.0] * len(shown)
        for phase, label, color in zip(PHASES, labels, palette):
            values = [gap(delay, phase) for delay in shown]
            axis.bar(shown, values, width=.55, color=color, label=label,
                     bottom=[up if value >= 0 else down
                             for value, up, down in zip(values, positive, negative)])
            positive = [up + max(0, value) for up, value in zip(positive, values)]
            negative = [down + min(0, value) for down, value in zip(negative, values)]
        axis.scatter(shown, [gap(delay, "cycles") for delay in shown], c="#171717",
                     marker="D", s=24, zorder=3, label="Whole-job difference")
        axis.axhline(0, color="#171717", linewidth=.7)
        axis.set(title=layer, xlabel="RAM read delay (cycles)", xticks=shown)
        axis.grid(axis="y", alpha=.2)
    axes[0].set_ylabel("Weight retention minus activation (kcycles)")
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="outside upper center", frameon=False, ncol=6, fontsize=8)
    fig.savefig(output / "crossover-phases.svg", metadata={"Date": None})
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("runs", nargs="+", type=Path)
    args = parser.parse_args()
    results, sources, manifests = {}, [], {}
    for run in args.runs:
        read_run(run, results, sources, manifests)
    matrix = list(product(LAYERS, range(1, 6), POLICIES))
    missing = [key for key in matrix if key not in results]
    require(not missing, f"Missing expected cases: {missing}")
    audit_delay_growth(results)
    args.output.mkdir(parents=True, exist_ok=True)
    write_csv(args.output / "programs.csv", [results[key] for key in matrix])
    write_csv(args.output / "energy-sensitivity.csv", list(energy_table(results)))
    provenance = dict(manifests=manifests, cases=sources)
    (args.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    plot(results, args.output)
    print(f"Verified {len(results)} unique cases across {len(sources)} case receipts.")


if __name__ == "__main__":
    main()
