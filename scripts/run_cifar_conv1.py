"""Run checked CIFAR Conv1_1 RTL programs and save counters and provenance."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import csv
import hashlib
import json
from pathlib import Path
import platform
import resource
import subprocess

import generate_cifar_conv1 as gen
import run_scaling_study as scaling
from run_cache_study import run

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "obj_dir/verification/cifar_conv1"
TOP = "opencorex_cifar_conv1_tb"
JOBS = [(policy, 1) for policy in gen.POLICIES] + [
    (policy, 5) for policy in gen.POLICIES[2:]
]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_csv(path, rows):
    with path.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=rows[0], lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def summarize(policy, latency, output):
    metrics, intervals, edges = {}, [], []
    for line in output.splitlines():
        kind, *fields = line.split(",")
        if kind == "METRIC":
            key, value = fields
            assert key not in metrics, key
            metrics[key] = int(value)
        elif kind == "COMMAND":
            intervals.append(tuple(map(int, fields)))
        elif kind == "EDGE":
            edges.append(fields)
    assert f"PASS: {TOP}" in output

    positions, filters, terms, tile = gen.POSITIONS, gen.FILTERS, gen.TERMS, gen.TILE
    outputs, macs = gen.OUTPUTS, gen.OUTPUTS * terms
    weight_first = policy.startswith("weight-")
    command_count = {
        "cpu-streaming": 0, "pim-per-dot": outputs, "activation-retaining": positions,
        "weight-reload": outputs // tile, "weight-retaining": outputs // tile,
    }[policy]
    cold = filters if policy == "weight-retaining" else command_count
    loads = cold * terms
    gather = outputs if weight_first else 0
    cpu = policy == "cpu-streaming"
    expected = dict(
        commands=command_count, cold_commands=cold, mmio_reads=command_count,
        mmio_writes=0 if cpu else 3 + 4 * command_count,
        cpu_muls=macs if cpu else 0, pim_macs=0 if cpu else macs,
        input_reads=gen.CHANNELS * (3 * gen.SIZE - 2)**2,
        activation_reads=loads if policy == "activation-retaining" else macs,
        weight_reads=loads if weight_first else macs,
        buffer_loads=loads, buffer_reuses=0 if cpu else macs - loads,
        patch_writes=positions * terms, output_writes=outputs,
        gather_reads=gather, gather_writes=gather, outputs_checked=outputs,
    )
    for key, value in expected.items():
        assert metrics[key] == value, (policy, latency, key, metrics[key], value)
    assert metrics["cycles"] == sum(metrics[k] for k in
        ("setup_cycles", "packing_cycles", "compute_cycles", "output_phase_cycles"))
    assert metrics["cycles"] == metrics["cpu_wait_cycles"] + metrics["cpu_non_wait_cycles"]
    assert metrics["cpu_blocked_cycles"] <= metrics["cpu_wait_cycles"]
    assert metrics["ram_reads"] == sum(metrics[k] for k in
        ("input_reads", "activation_reads", "weight_reads", "fetch_reads", "control_reads", "gather_reads"))
    assert metrics["ram_writes"] == 4 + outputs + gather + positions * terms
    assert len(intervals) == command_count
    previous_end = -1
    for index, (actual_index, start, end, duration) in enumerate(intervals):
        assert index == actual_index and previous_end < start < end and end - start == duration
        previous_end = end
    assert sum(duration for _, _, _, duration in intervals) == metrics["pim_cycles"]

    row = dict(workload="CIFAR Conv1_1", policy=policy, precision="INT32", ram_latency=latency,
               **metrics, psum_reads=0, psum_writes=0,
               ram_bytes=4 * (metrics["ram_reads"] + metrics["ram_writes"]), correctness="PASS")
    timing = [dict(zip(("edge_from_start", "ram_read", "pim_response", "ram_write", "buffer_load",
                       "buffer_read", "mac_start", "mac_done", "term", "address_hex"), fields))
              for fields in edges]
    return row, timing


def version(command):
    return subprocess.check_output(command, cwd=ROOT, text=True).splitlines()[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=BUILD / "results")
    parser.add_argument("--workers", type=int, choices=range(1, 5), default=3)
    args = parser.parse_args()
    if not __debug__:
        parser.error("run without Python -O so traffic and timing assertions are active")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    output_dir = args.output.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    images = BUILD / "images"
    gen.generate(images)
    scaling.BUILD = BUILD
    commands = []
    tb = ROOT / f"tb/benchmarks/{TOP}.sv"
    build, executable = scaling.compile_tb(TOP, tb, 1, "rtl", commands)

    def measure(job):
        policy, latency = job
        command = [str(executable), f"+MODE={gen.POLICIES.index(policy)}", f"+DELAY={latency}",
                   f"+IMAGE={images / (policy + '.hex')}", f"+RAW={images / 'raw.hex'}",
                   f"+PATCHES={images / 'patches.hex'}"]
        log = build / f"{policy}-L{latency}.log"
        row, timing = summarize(policy, latency, run(command, log))
        print(f"PASS {policy}, L={latency}: {row['cycles']:,} cycles", flush=True)
        return row, timing, command, log

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        runs = list(pool.map(measure, JOBS))
    rows = [row for row, _, _, _ in runs]
    write_csv(output_dir / "programs.csv", rows)
    edges = next(timing for row, timing, _, _ in runs
                 if row["policy"] == "activation-retaining" and row["ram_latency"] == 1)
    write_csv(output_dir / "timing.csv", edges)
    sources = sorted((ROOT / "rtl").glob("*/*.sv")) + [tb, ROOT / "Makefile",
        ROOT / "tb/memory/latency_memory_responder.sv"] + [
        ROOT / "scripts" / name for name in (
            "run_cifar_conv1.py", "generate_cifar_conv1.py", "conv1_reference.py", "generate_conv1.py",
            "generate_matvec_1x16_16x32.py", "run_scaling_study.py", "run_cache_study.py",
            "run_memory_latency_sweep.py",
        )
    ]
    artifacts = [*sorted(images.glob("*.hex")), *(log for _, _, _, log in runs),
                 output_dir / "programs.csv", output_dir / "timing.csv"]
    manifest = dict(
        revision=version(["git", "rev-parse", "HEAD"]),
        tracked_changes=subprocess.check_output(
            ["git", "status", "--short", "--untracked-files=no"], cwd=ROOT, text=True
        ).splitlines(),
        python=platform.python_version(), verilator=version(["verilator", "--version"]),
        compiler=version(["c++", "--version"]),
        configuration=dict(input_hwc=[32, 32, 3], output_hwc=[32, 32, 64], kernel=[3, 3],
                           stride=1, zero_padding=1, seed="0xc1fa", bias=0, relu=False,
                           ram_words=262144, ram_ports=1, max_outstanding_reads=1,
                           buffer_words=128, max_outputs=128, mac_lanes=1, instruction_cache=True),
        commands=commands + [command for _, _, command, _ in runs],
        source_sha256={str(path.relative_to(ROOT)): sha256(path) for path in sources},
        artifact_sha256={str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path):
                         sha256(path) for path in artifacts},
    )
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
