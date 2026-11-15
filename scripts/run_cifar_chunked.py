"""Run checked, matched chunked convolution schedules on the Friday RTL."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import random
import resource
import subprocess
import sys

import generate_cifar_conv1 as friday
import generate_matvec_1x16_16x32 as rv
import run_cifar_conv1 as baseline
import run_scaling_study as scaling
from conv1_reference import convolve
from generate_conv1 import Assembler, CONSTANTS, DONE, KERNEL, MASK, SIGNATURE, hex_text
from run_cache_study import run

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "obj_dir/verification/cifar_chunked"
TOP = "opencorex_chunked_conv_tb"
TEMPLATE = ROOT / f"tb/benchmarks/{TOP}.sv.in"
POLICIES = friday.POLICIES[2:]
SEED = 0xc1fa
RAM_WORDS = 262144
VECTOR_WORDS = 128
FILTERS = 32


@dataclass(frozen=True)
class Workload:
    name: str
    side: int
    channels: int
    logical_filters: int
    rows: int
    tile: int

    @property
    def positions(self):
        return self.rows * self.side

    @property
    def terms(self):
        return 9 * self.channels

    @property
    def outputs(self):
        return self.positions * FILTERS

    @property
    def lengths(self):
        return [min(VECTOR_WORDS, self.terms - k)
                for k in range(0, self.terms, VECTOR_WORDS)]

    def constants(self):
        return dict(SIDE=self.side, CHANNELS=self.channels, FILTERS=FILTERS,
                    TERMS=self.terms, POSITIONS=self.positions, TILE=self.tile,
                    CHUNKS=len(self.lengths), **{k.upper(): v[0] for k, v in self.regions().items()})

    def regions(self):
        cursor = 0x6000
        regions = {}
        for name, words in [
            ("input", self.side**2 * self.channels),
            ("patch", self.positions * self.terms),
            ("weights", FILTERS * self.terms),
            ("partial", self.outputs * len(self.lengths)),
            ("filter_output", self.outputs),
            ("output", self.outputs),
        ]:
            regions[name] = (cursor, words)
            cursor += words * 4
        assert cursor <= 4 * RAM_WORDS, hex(cursor)
        assert self.positions % self.tile == 0 and self.positions > self.tile
        assert 0 < self.tile <= VECTOR_WORDS and FILTERS <= self.logical_filters
        return regions


LAYERS = {
    "conv2_1": Workload("Conv2_1", 16, 64, 128, 16, 128),
    "conv1_2": Workload("Conv1_2", 32, 64, 64, 4, 64),
    "conv2_2": Workload("Conv2_2", 16, 128, 128, 7, 56),
}


def make_data(work):
    rng = random.Random(SEED)
    image = [[[rv.to_s32(rng.getrandbits(32)) for _ in range(work.side)]
              for _ in range(work.side)] for _ in range(work.channels)]
    weights = [[[[rv.to_s32(rng.getrandbits(32)) for _ in range(3)]
                 for _ in range(3)] for _ in range(work.channels)] for _ in range(FILTERS)]
    # At the top-left position these products wrap twice across different chunks.
    image[0][0][0] = image[-1][0][0] = -2**31
    weights[0] = [[[0] * 3 for _ in range(3)] for _ in range(work.channels)]
    weights[0][0][1][1] = weights[0][-1][1][1] = -1
    raw, _, _ = convolve(image, weights, [0] * FILTERS)
    raw = raw[:work.outputs]
    raw_words = [word for channel in image for row in channel for word in row]
    weight_words = [word for f in weights for channel in f for row in channel for word in row]
    patches = [
        image[c][y + dy][x + dx] & MASK
        if 0 <= y + dy < work.side and 0 <= x + dx < work.side else 0
        for y in range(work.rows) for x in range(work.side) for c in range(work.channels)
        for dy in (-1, 0, 1) for dx in (-1, 0, 1)
    ]
    partial = []
    for chunk, length in enumerate(work.lengths):
        start = chunk * VECTOR_WORDS
        plane = []
        for p in range(work.positions):
            activations = patches[p * work.terms + start:p * work.terms + start + length]
            for f in range(FILTERS):
                base = f * work.terms + start
                plane.append(sum(a * w for a, w in zip(
                    activations, weight_words[base:base + length])) & MASK)
        partial.append(plane)
    assert raw[0] == 0 and partial[0][0] == partial[-1][0] == 0x80000000
    assert [sum(words) & MASK for words in zip(*partial)] == raw
    input_reads = sum(
        0 <= y + dy < work.side and 0 <= x + dx < work.side
        for y in range(work.rows) for x in range(work.side)
        for dy in (-1, 0, 1) for dx in (-1, 0, 1)
    ) * work.channels
    return raw_words, weight_words, patches, raw, friday.flatten(partial), input_reads


def pack(a, work, memory):
    a.load(1, memory["input"][0])
    a.load(2, memory["patch"][0])
    a.emit(rv.addi(13, 0, -1), rv.addi(14, 0, work.side), rv.addi(16, 0, 3),
           rv.addi(17, 0, work.channels), rv.addi(18, 0, work.side**2),
           rv.addi(19, 0, 4), rv.addi(20, 0, work.rows), rv.addi(3, 0, 0))
    loops = ((3, 20, "y"), (4, 14, "x"), (5, 17, "channel"),
             (6, 16, "row"), (7, 16, "col"))
    for (_, _, label), (next_register, _, _) in zip(loops, loops[1:]):
        a.label(f"pack_{label}")
        a.emit(rv.addi(next_register, 0, 0))
    a.label("pack_col")
    a.emit(rv.add(8, 3, 6), rv.addi(8, 8, -1), rv.add(9, 4, 7), rv.addi(9, 9, -1))
    for coordinate in (8, 9):
        for bound in (13, 14):
            a.branch(coordinate, bound, "pad", equal=True)
    a.emit(rv.mul(10, 5, 18), rv.mul(11, 8, 14), rv.add(10, 10, 11),
           rv.add(10, 10, 9), rv.mul(10, 10, 19), rv.add(10, 10, 1), rv.lw(12, 10))
    a.jump("store_patch")
    a.label("pad")
    a.emit(rv.addi(12, 0, 0))
    a.label("store_patch")
    a.emit(rv.sw(12, 2), rv.addi(2, 2, 4))
    for register, bound, label in reversed(loops):
        a.emit(rv.addi(register, register, 1))
        a.branch(register, bound, f"pack_{label}")


def compute(a, work, memory, weights_first, retain):
    stride = 4 * work.terms
    a.load(1, 0x40000000)
    a.load(23, stride)
    a.emit(rv.sw(23, 1, 12), rv.addi(24, 0, 10),
           rv.addi(2, 0, work.tile if weights_first else FILTERS), rv.sw(2, 1, 20))
    if weights_first:
        a.load(22, stride * work.tile)
    else:
        a.emit(rv.addi(25, 0, 1))
    for c, length in enumerate(work.lengths):
        start = 4 * c * VECTOR_WORDS
        a.emit(rv.addi(2, 0, length), rv.sw(2, 1, 4))
        a.load(7, memory["partial"][0] + 4 * c * work.outputs)
        vector, matrix = ("weights", "patch") if weights_first else ("patch", "weights")
        a.load(5, memory[vector][0] + start)
        a.load(19, memory[matrix][0] + start)
        a.emit(rv.addi(20, 0, FILTERS if weights_first else work.positions))
        a.label(f"outer_{c}")
        a.emit(rv.addi(6, 19, 0))
        if weights_first:
            a.emit(rv.addi(21, 0, work.positions // work.tile), rv.addi(25, 0, 1))
            a.label(f"tile_{c}")
        friday.launch(a)
        if weights_first:
            a.emit(rv.addi(25, 0, 3 if retain else 1), rv.add(6, 6, 22),
                   rv.addi(7, 7, 4 * work.tile), rv.addi(21, 21, -1))
            a.branch(21, 0, f"tile_{c}")
        else:
            a.emit(rv.addi(7, 7, 4 * FILTERS))
        a.emit(rv.add(5, 5, 23), rv.addi(20, 20, -1))
        a.branch(20, 0, f"outer_{c}")


def combine(a, work, memory, weights_first):
    a.load(5, memory["partial"][0])
    a.load(7, memory["filter_output" if weights_first else "output"][0])
    a.load(20, work.outputs)
    a.load(22, 4 * work.outputs)
    a.label("combine_output")
    a.emit(rv.addi(6, 5, 0), rv.addi(21, 0, len(work.lengths)), rv.addi(11, 0, 0))
    a.label("combine_chunk")
    a.emit(rv.lw(12, 6), rv.add(11, 11, 12), rv.add(6, 6, 22), rv.addi(21, 21, -1))
    a.branch(21, 0, "combine_chunk")
    a.emit(rv.sw(11, 7), rv.addi(5, 5, 4), rv.addi(7, 7, 4), rv.addi(20, 20, -1))
    a.branch(20, 0, "combine_output")


def generate_images(directory, work):
    memory = work.regions()
    image, weights, patches, raw, partial, input_reads = make_data(work)
    for name, words in (("patches", patches), ("raw", raw), ("partials", partial)):
        (directory / f"{name}.hex").write_text("".join(f"{word:08x}\n" for word in words))
    friday.POSITIONS, friday.FILTERS = work.positions, FILTERS
    friday.FILTER_OUTPUT, friday.OUTPUT = memory["filter_output"][0], memory["output"][0]
    for policy in POLICIES:
        weights_first = policy.startswith("weight-")
        a = Assembler()
        a.phase(1)
        pack(a, work, memory)
        a.phase(2)
        compute(a, work, memory, weights_first, policy == "weight-retaining")
        a.phase(3)
        combine(a, work, memory, weights_first)
        a.phase(4)
        if weights_first:
            friday.gather(a)
        a.emit(rv.lw(31, 0, SIGNATURE), rv.sw(31, 0, DONE))
        a.label("failure")
        a.jump("failure")
        code = a.finish()
        regions = [(0, [rv.jal(0, KERNEL), 0, 0, 0]),
                   (SIGNATURE, [rv.COMPLETION_SIGNATURE, 0, 0]),
                   (CONSTANTS, a.constants), (KERNEL, code + [0] * (-len(code) % 4))]
        for name, (base, words) in memory.items():
            data = {"input": image, "weights": weights}.get(name)
            if data is None:
                data = [0xa5a5a5a5 if name == "patch" else 0xdeadbeef] * words
            assert len(data) == words
            regions.append((base, data))
        (directory / f"{policy}.hex").write_text(hex_text(regions))
    return input_reads


def summarize(output, work, policy, latency, input_reads):
    metrics = {}
    last_end = -1
    intervals = 0
    command_cycles = 0
    for line in output.splitlines():
        kind, *fields = line.split(",")
        if kind == "METRIC":
            key, value = fields
            assert key not in metrics
            metrics[key] = int(value)
        elif kind == "COMMAND":
            index, start, end, duration = map(int, fields)
            assert index == intervals and last_end < start < end and end - start == duration
            last_end = end
            intervals += 1
            command_cycles += duration
    assert f"PASS: {TOP}" in output
    weight_first = policy.startswith("weight-")
    cmds_per_chunk = (work.outputs // work.tile if weight_first else work.positions)
    loads = (FILTERS if policy == "weight-retaining" else cmds_per_chunk) * work.terms
    commands = cmds_per_chunk * len(work.lengths)
    macs = work.outputs * work.terms
    psums = work.outputs * len(work.lengths)
    gather = work.outputs if weight_first else 0
    expected = dict(commands=commands, cold_commands=loads * len(work.lengths) // work.terms,
                    mmio_reads=commands, mmio_writes=2 + len(work.lengths) + 4 * commands,
                    input_reads=input_reads, patch_writes=work.positions * work.terms,
                    activation_reads=macs if weight_first else loads,
                    weight_reads=loads if weight_first else macs,
                    buffer_loads=loads, buffer_reuses=macs - loads, pim_macs=macs,
                    psum_reads=psums, psum_writes=psums,
                    gather_reads=gather, gather_writes=gather,
                    output_writes=work.outputs, final_output_writes=work.outputs, outputs_checked=work.outputs)
    for key, value in expected.items():
        assert metrics[key] == value, (work.name, policy, latency, key, metrics[key], value)
    assert metrics["cycles"] == sum(metrics[key] for key in
        ("setup_cycles", "packing_cycles", "compute_cycles", "combine_cycles", "output_phase_cycles"))
    assert metrics["cycles"] == metrics["cpu_wait_cycles"] + metrics["cpu_non_wait_cycles"]
    assert metrics["cpu_blocked_cycles"] <= metrics["cpu_wait_cycles"]
    assert metrics["ram_reads"] == sum(metrics[key] for key in
        ("input_reads", "activation_reads", "weight_reads", "fetch_reads", "control_reads",
         "gather_reads", "psum_reads"))
    assert metrics["ram_writes"] == 5 + psums + work.outputs + gather + metrics["patch_writes"]
    assert intervals == commands and command_cycles == metrics["pim_cycles"]
    return dict(workload=work.name, policy=policy, precision="INT32", ram_latency=latency,
                **metrics, ram_bytes=4 * (metrics["ram_reads"] + metrics["ram_writes"]),
                correctness="PASS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("layer", choices=LAYERS)
    parser.add_argument("--delay", type=int, choices=(1, 5), nargs="+", default=[1])
    args = parser.parse_args()
    if not __debug__:
        parser.error("assertions must be enabled")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    work = LAYERS[args.layer]
    scaling.BUILD = BUILD / args.layer
    directory = scaling.BUILD / "results"
    directory.mkdir(parents=True, exist_ok=True)
    input_reads = generate_images(directory, work)
    template = TEMPLATE.read_text()
    for key, value in work.constants().items():
        template = template.replace(f"@{key}@", str(value))
    tb = directory / f"{TOP}.sv"
    tb.write_text(template)
    commands = []
    _, executable = scaling.compile_tb(TOP, tb, 1, "rtl", commands)

    def measure(job):
        policy, latency = job
        command = [str(executable), f"+MODE={friday.POLICIES.index(policy)}", f"+DELAY={latency}",
                   f"+IMAGE={directory / (policy + '.hex')}", f"+RAW={directory / 'raw.hex'}",
                   f"+PATCHES={directory / 'patches.hex'}", f"+PARTIALS={directory / 'partials.hex'}"]
        log = directory / f"{policy}-L{latency}.log"
        row = summarize(run(command, log), work, policy, latency, input_reads)
        print(f"PASS {work.name} {policy} L={latency}: {row['cycles']:,} cycles", flush=True)
        return row, command, log

    for latency in args.delay:
        with ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(measure, [(policy, latency) for policy in POLICIES]))
        csv_path = directory / f"programs-L{latency}.csv"
        baseline.write_csv(csv_path, [row for row, _, _ in results])
        paths = [Path(__file__).resolve(), TEMPLATE, tb, csv_path,
                 *sorted(directory.glob("*.hex")), *(log for _, _, log in results),
                 *sorted((ROOT / "rtl").glob("*/*.sv")), ROOT / "tb/memory/latency_memory_responder.sv",
                 *(ROOT / "scripts" / name for name in (
                     "generate_cifar_conv1.py", "conv1_reference.py", "generate_conv1.py",
                     "generate_matvec_1x16_16x32.py", "run_cifar_conv1.py", "run_scaling_study.py",
                     "run_cache_study.py", "run_memory_latency_sweep.py")),
                 scaling.BUILD / "cache_study_subsystem.sv", executable.parent / "build.log"]
        manifest = dict(
            revision=baseline.version(["git", "rev-parse", "HEAD"]),
            tracked_changes=subprocess.check_output(
                ["git", "status", "--short", "--untracked-files=no"], cwd=ROOT, text=True
            ).splitlines(),
            tools=dict(python=sys.version, verilator=baseline.version(["verilator", "--version"]),
                       compiler=baseline.version(["c++", "--version"])),
            configuration=dict(input_hwc=[work.side, work.side, work.channels],
                logical_output_hwc=[work.side, work.side, work.logical_filters],
                measured_rows=list(range(work.rows)), measured_columns=list(range(work.side)),
                measured_filters=list(range(FILTERS)), terms=work.terms, chunk_lengths=work.lengths,
                weight_position_tile=work.tile, activation_filter_tile=FILTERS,
                seed=hex(SEED), kernel=[3, 3], stride=1, zero_padding=1, bias=0, relu=False,
                precision="INT32 modulo 2^32", delay=latency, ram_words=RAM_WORDS, ram_ports=1,
                max_outstanding_reads=1, buffer_words=VECTOR_WORDS, max_outputs=128,
                mac_lanes=1, instruction_cache=True),
            regions={name: dict(base=hex(base), words=words, end_exclusive=hex(base + 4 * words))
                     for name, (base, words) in work.regions().items()},
            commands=commands + [command for _, command, _ in results],
            sha256={str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in paths},
        )
        (directory / f"manifest-L{latency}.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
