#!/usr/bin/env python3
"""Run a deterministic CIFAR VGG forward pass as independently checked RTL tiles."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
from threading import Lock

import numpy as np

import run_cifar_chunked as conv
from cifar_storage_ledger import BLOCKS
from generate_conv1 import Assembler, CONSTANTS, DONE, KERNEL, SIGNATURE, hex_text
from generate_matvec_1x16_16x32 import (
    COMPLETION_SIGNATURE, add, addi, encode_r_type, jal, lw, sw,
)

ROOT = conv.ROOT
RAM_WORDS = 16 * 1024 * 1024 // 4
POLICY = "activation-retaining"
SEED = 0xC1FA
EXPECTED_MACS = 313_201_664
MASK = 0xFFFFFFFF
SIGN = 1 << 31
CONSTANT_WORDS = (0x800 - CONSTANTS) // 4
TOTAL_SECONDS = 6 * 3600
COMPILE_LOCK = Lock()


class Linear(conv.Workload):
    @property
    def terms(self):
        return self.channels


def and_(rd, rs1, rs2):
    return encode_r_type(funct7=0, rs2=rs2, rs1=rs1, funct3=7, rd=rd)


def copy_vector(a, work, memory):
    a.load(1, memory["input"][0])
    a.load(2, memory["patch"][0])
    a.emit(addi(3, 0, work.terms))
    a.label("copy_input")
    a.emit(lw(4, 1), sw(4, 2), addi(1, 1, 4), addi(2, 2, 4), addi(3, 3, -1))
    a.branch(3, 0, "copy_input")


def bias_relu(a, work, memory, relu):
    a.load(5, memory["output"][0])
    a.load(7, memory["post"][0])
    a.load(19, memory["bias"][0])
    if relu:
        a.load(23, SIGN)
    a.emit(addi(20, 0, work.positions), addi(21, 0, work.filters))
    a.label("post_position")
    a.emit(addi(6, 19, 0), addi(8, 21, 0))
    a.label("post_filter")
    a.emit(lw(11, 5), lw(12, 6), add(11, 11, 12))
    if relu:
        a.emit(and_(13, 11, 23))
        a.branch(13, 0, "post_store", equal=True)
        a.emit(addi(11, 0, 0))
        a.label("post_store")
    a.emit(sw(11, 7), addi(5, 5, 4), addi(6, 6, 4), addi(7, 7, 4), addi(8, 8, -1))
    a.branch(8, 0, "post_filter")
    a.emit(addi(20, 20, -1))
    a.branch(20, 0, "post_position")


def max_pool(a, work, memory):
    a.load(1, memory["post"][0])
    a.load(2, memory["pool"][0])
    a.load(8, SIGN)
    a.load(6, 4 * work.side * work.filters)
    a.emit(addi(7, 0, 4 * work.filters), addi(3, 0, work.side // 2))
    a.label("pool_row")
    a.emit(addi(4, 0, work.side // 2))
    a.label("pool_column")
    a.emit(addi(5, 0, work.filters))
    a.label("pool_channel")
    a.emit(lw(10, 1), add(12, 1, 7), add(13, 1, 6), add(14, 13, 7))
    for candidate in (12, 13, 14):
        skip = f"pool_keep_{candidate}"
        # Both operands are nonnegative signed words, so their difference cannot overflow.
        a.emit(lw(9, candidate), encode_r_type(funct7=32, rs2=9, rs1=10, funct3=0, rd=11), and_(11, 11, 8))
        a.branch(11, 0, skip, equal=True)
        a.emit(addi(10, 9, 0))
        a.label(skip)
    a.emit(sw(10, 2), addi(2, 2, 4), addi(1, 1, 4), addi(5, 5, -1))
    a.branch(5, 0, "pool_channel")
    a.emit(add(1, 1, 7), addi(4, 4, -1))
    a.branch(4, 0, "pool_column")
    a.emit(add(1, 1, 6), addi(3, 3, -1))
    a.branch(3, 0, "pool_row")


def signed(words):
    return ((np.asarray(words, dtype=np.int64) + SIGN) & MASK) - SIGN


def reference(image, weights, biases, pool):
    """Compute directly from tensor coordinates, independently of packed operand ordering."""
    if weights.ndim == 2:
        raw = (weights @ image.ravel()).reshape(1, 1, -1) & MASK
        return raw, (raw + biases) & MASK, None
    side = image.shape[1]
    padded = np.pad(image, ((0, 0), (1, 1), (1, 1)))
    raw = np.zeros((side, side, len(biases)), dtype=np.int64)
    for dy in range(3):
        for dx in range(3):
            raw += padded[:, dy:dy + side, dx:dx + side].transpose(1, 2, 0) @ weights[:, :, dy, dx].T
    raw &= MASK
    post = np.maximum(signed(raw + biases), 0)
    if not pool:
        return raw, post, None
    return raw, post, np.maximum.reduce([post[y::2, x::2] for y in (0, 1) for x in (0, 1)])


def pack_reference(image, work):
    if isinstance(work, Linear):
        return image.reshape(1, -1), work.channels
    padded = np.pad(image, ((0, 0), (1, 1), (1, 1)))
    windows = np.lib.stride_tricks.sliding_window_view(padded, (3, 3), axis=(1, 2))
    patches = windows.transpose(1, 2, 0, 3, 4).reshape(work.positions, work.terms)
    input_reads = int(np.lib.stride_tricks.sliding_window_view(
        np.pad(np.ones((work.side, work.side), dtype=np.int64), 1), (3, 3)
    ).sum()) * work.channels
    return patches, input_reads


def regions(work, pool):
    result = work.regions()
    end = max(base + 4 * words for base, words in result.values())
    for name, words in (("bias", work.filters), ("post", work.outputs),
                        ("pool", work.outputs // 4 if pool else 0)):
        result[name] = end, words
        end += 4 * words
    if end > 4 * RAM_WORDS:
        raise ValueError(f"{work.name} requires {end:,} bytes")
    return result


def write_words(path, words):
    with path.open("w") as stream:
        stream.writelines(f"{int(word) & MASK:08x}\n" for word in words.flat)


def build_tile(directory, work, image, weights, biases, pool):
    memory = regions(work, pool)
    raw, post, pooled = reference(image, weights, biases, pool)
    patches, input_reads = pack_reference(image, work)
    weight_matrix = weights.reshape(work.filters, work.terms)
    partials = np.stack([(patches[:, start:start + 128] @ weight_matrix[:, start:start + 128].T) & MASK
                         for start in range(0, work.terms, 128)])
    if not np.array_equal(partials.sum(axis=0).reshape(raw.shape) & MASK, raw):
        raise ValueError("packed partials disagree with independent tensor reference")
    for name, values in (("raw", raw), ("patches", patches), ("partials", partials),
                         ("post", post), ("pool", pooled)):
        if values is not None:
            write_words(directory / f"{name}.hex", values)

    a = Assembler(constant_words=CONSTANT_WORDS)
    a.phase(1)
    (copy_vector if isinstance(work, Linear) else conv.pack)(a, work, memory)
    a.phase(2)
    conv.compute(a, work, memory, weights_first=False, retain=False)
    a.phase(3)
    conv.combine(a, work, memory, weights_first=False)
    a.phase(4)
    bias_relu(a, work, memory, relu=not isinstance(work, Linear))
    a.phase(5)
    if pool:
        max_pool(a, work, memory)
    a.phase(6)
    a.emit(lw(31, 0, SIGNATURE), sw(31, 0, DONE))
    a.label("failure")
    a.jump("failure")
    code = a.finish()
    layout = [(0, [jal(0, KERNEL), 0, 0, 0]),
              (SIGNATURE, [COMPLETION_SIGNATURE, 0, 0]),
              (CONSTANTS, a.constants), (KERNEL, code + [0] * (-len(code) % 4))]
    layout += [(memory[name][0], [int(value) for value in data.flat])
               for name, data in (("input", image), ("weights", weights), ("bias", biases))]
    # Initialize working memory with sentinels to catch missing stores.
    layout += [(base, [0xDEADBEEF] * words) for name, (base, words) in memory.items()
               if name not in ("input", "weights", "bias", "filter_output") and words]
    (directory / f"{POLICY}.hex").write_text(hex_text(layout, ram_bytes=4 * RAM_WORDS))

    constants = work.constants(RAM_WORDS)
    constants.update(CONST_WORDS=CONSTANT_WORDS, BIAS=memory["bias"][0], POST=memory["post"][0],
                     POOL=memory["pool"][0], POST_WORDS=work.outputs, POOL_WORDS=memory["pool"][1])
    template = conv.TEMPLATE.read_text()
    for key, value in constants.items():
        template = template.replace(f"@{key}@", str(value))
    tb = directory / f"{conv.TOP}.sv"
    tb.write_text(template)
    commands = []
    with COMPILE_LOCK:
        conv.scaling.BUILD = directory
        conv.scaling.compile_tb(conv.TOP, tb, 1, "rtl", commands)
    return input_reads, pooled if pool else post, memory, commands


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def tensor_hash(tensor):
    words = np.asarray(tensor, dtype="<i8")
    return hashlib.sha256(repr(words.shape).encode() + words.tobytes()).hexdigest()


def atomic_json(path, value):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, indent=2) + "\n")
    temp.replace(path)


def run_simulator(command, directory, timeout):
    log_path = directory / "simulator.log"
    stats = directory / "resource.txt"
    with log_path.open("w") as log:
        process = subprocess.Popen(
            ["/usr/bin/time", "-o", str(stats), "-f", "%e %M", *command],
            cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
        )
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
    output = log_path.read_text()
    if code:
        raise RuntimeError(output[-2200:])
    elapsed, rss = stats.read_text().split()
    return output, float(elapsed), int(rss)


def source_files():
    scripts = ("run_cifar_inference.py", "run_cifar_chunked.py", "cifar_storage_ledger.py",
               "generate_conv1.py", "generate_cifar_conv1.py", "generate_matvec_1x16_16x32.py",
               "run_scaling_study.py")
    return [*(ROOT / "scripts" / name for name in scripts),
            *sorted((ROOT / "rtl").glob("*/*.sv")), conv.TEMPLATE,
            ROOT / "tb/memory/latency_memory_responder.sv"]


def read_result(path, shape):
    return np.array([int(word, 16) for word in path.read_text().splitlines()],
                    dtype=np.int64).reshape(shape)


def tile(root, work, image, weights, biases, pool, identity, deadline):
    dest = root / work.name
    dest.mkdir(exist_ok=True)
    signature = dict(input_sha256=tensor_hash(image), weights_sha256=tensor_hash(weights),
                     bias_sha256=tensor_hash(biases), sources_sha256=identity, pool=pool,
                     workload=vars(work), ram_mib=16, delay=1)
    result_shape = (work.side // 2, work.side // 2, work.filters) if pool else (
        work.side, work.side, work.filters)
    receipt_path = dest / "receipt.json"
    if receipt_path.is_file():
        prior = json.loads(receipt_path.read_text())
        result_path = dest / prior["result"]
        log_path = result_path.with_name("simulator.log")
        if (prior["signature"] == signature and result_path.is_file() and log_path.is_file()
                and digest(result_path) == prior["result_sha256"]
                and digest(log_path) == prior["log_sha256"]):
            print(f"REUSE {work.name}", flush=True)
            return read_result(result_path, result_shape), prior
        raise ValueError(f"checkpoint mismatch for {work.name}; use a fresh run ID")

    attempts = []
    try:
        if time.monotonic() >= deadline:
            raise TimeoutError("run budget expired before tile build")
        input_reads, expected, memory, builds = build_tile(dest, work, image, weights, biases, pool)
        for nominal_limit in (1500, 3000):
            remaining = deadline - time.monotonic()
            if remaining <= 1:
                raise TimeoutError("run budget expired before tile simulation")
            attempt = dest / f"attempt-{len(attempts) + 1}"
            attempt.mkdir(exist_ok=True)
            result_path = attempt / "result.hex"
            command = conv.simulator_command(dest, POLICY, 1)
            command += [f"+POST_EXPECTED={dest / 'post.hex'}", f"+RESULT={result_path}"]
            if pool:
                command.append(f"+POOL_EXPECTED={dest / 'pool.hex'}")
            timeout = min(nominal_limit, remaining)
            record = dict(command=command, timeout_seconds=round(timeout, 2))
            attempts.append(record)
            try:
                output, elapsed, rss = run_simulator(command, attempt, timeout)
            except subprocess.TimeoutExpired:
                record["status"] = "TIMEOUT"
                continue
            record["status"] = "PASS"
            break
        else:
            raise TimeoutError("tile simulation timed out twice")

        metrics = conv.summarize(output, work, POLICY, 1, input_reads)
        result = read_result(result_path, result_shape)
        if not np.array_equal(result, expected):
            raise ValueError("captured RTL result disagrees with the independent oracle")
        receipt = dict(signature=signature, build_commands=builds, attempts=attempts, metrics=metrics,
                       elapsed_seconds=elapsed, peak_rss_kib=rss,
                       ram_workspace_bytes=max(base + 4 * words for base, words in memory.values()),
                       images=conv.hashes(dest.glob("*.hex")),
                       result=str(result_path.relative_to(dest)), result_sha256=digest(result_path),
                       log_sha256=digest(attempt / "simulator.log"))
        atomic_json(receipt_path, receipt)
        print(f"PASS {work.name}: {metrics['pim_macs']:,} MACs, {metrics['cycles']:,} cycles", flush=True)
        return result, receipt
    except Exception as exc:
        atomic_json(dest / "failure.json", dict(signature=signature, attempts=attempts, error=str(exc)))
        raise


def model():
    rng = np.random.Generator(np.random.PCG64(SEED))
    initial = rng.integers(-4, 5, (3, 32, 32), dtype=np.int64)
    channels = 3
    layers = []
    for block, filters in enumerate(BLOCKS, 1):
        for index, count in enumerate(filters, 1):
            weights = rng.integers(-2, 3, (count, channels, 3, 3), dtype=np.int64)
            biases = rng.integers(-8, 9, count, dtype=np.int64)
            layers.append((f"conv{block}_{index}", weights, biases, index == len(filters)))
            channels = count
    layers.append(("classifier", rng.integers(-2, 3, (10, channels), dtype=np.int64),
                   rng.integers(-8, 9, 10, dtype=np.int64), False))
    return initial, layers


def run_layer(name, weights, biases, pool, image, root, identity, deadline, executor):
    side = image.shape[1]
    logical_filters, channels = weights.shape[:2]
    work_type = Linear if weights.ndim == 2 else conv.Workload
    jobs = []
    for start in range(0, logical_filters, 128):
        end = min(start + 128, logical_filters)
        work = work_type(f"{name}-{start:03d}", side, channels, logical_filters, side, 1,
                         filters=end - start, max_cycles=800_000_000)
        jobs.append(executor.submit(tile, root, work, image, weights[start:end], biases[start:end],
                                    pool, identity, deadline))
    results, receipts = zip(*(job.result() for job in jobs))
    assembled = np.concatenate(results, axis=2)
    _, post, pooled = reference(image, weights, biases, pool)
    if not np.array_equal(assembled, pooled if pool else post):
        raise ValueError(f"channel stitching mismatch in {name}")
    return assembled, receipts


def smoke(root, identity, deadline, executor, initial, layers):
    x = np.array([[[9, 3, 2, 9], [4, 1, 2, 1], [2, 1, 2, 1], [9, 3, 3, SIGN - 1]],
                  [[0, 0, 5, 5], [0, 0, 1, 0], [-SIGN, 0, 0, 0], [0, 0, 0, 0]]],
                 dtype=np.int64)
    kernels = np.zeros((4, 2, 3, 3), dtype=np.int64)
    kernels[0, 0, 1, 1] = kernels[2, 0, 1, 1] = 1
    kernels[1, 1, 1, 1] = kernels[3, 1, 1, 1] = 1
    rng = np.random.default_rng(SEED)
    directed = ("smoke-pool", kernels, np.array([0, 0, 1, -1]), True, x)
    deep = ("smoke-deep", layers[12][1][:1], layers[12][2][:1], True,
            rng.integers(-4, 5, (512, 2, 2), dtype=np.int64))
    fc = ("smoke-classifier", layers[-1][1], layers[-1][2], False,
          rng.integers(-4, 5, (512, 1, 1), dtype=np.int64))
    conv1 = ("conv1_1", *layers[0][1:], initial)
    for name, weights, bias, pool, image in (directed, deep, fc, conv1):
        run_layer(name, weights, bias, pool, image, root, identity, deadline, executor)


def layer_record(name, output, receipts):
    metrics = ("cycles", "bias_relu_cycles", "pool_cycles", "ram_reads", "ram_writes", "pim_macs")
    return dict(layer=name, output_shape=list(output.shape), output_sha256=tensor_hash(output),
                tiles=[r["signature"]["workload"]["name"] for r in receipts],
                rtl_totals={key: sum(r["metrics"][key] for r in receipts) for key in metrics},
                simulator_seconds_sum=round(sum(r["elapsed_seconds"] for r in receipts), 2),
                simulator_peak_rss_kib=max(r["peak_rss_kib"] for r in receipts))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--smoke-only", action="store_true")
    parser.add_argument("--workers", type=int, choices=range(1, 5), default=4)
    parser.add_argument("--deadline", type=datetime.fromisoformat,
                        help="optional absolute cutoff with an explicit UTC offset")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.run_id):
        parser.error("invalid run ID")
    if args.deadline is not None and args.deadline.utcoffset() is None:
        parser.error("--deadline requires a UTC offset")
    if not __debug__:
        parser.error("assertions must be enabled")

    root = ROOT / "obj_dir/verification/cifar_inference" / args.run_id
    root.mkdir(parents=True, exist_ok=args.resume)
    deadline = time.monotonic() + min(TOTAL_SECONDS, (args.deadline.timestamp() - time.time())
                                      if args.deadline is not None else TOTAL_SECONDS)
    sources = conv.hashes(source_files())
    identity = hashlib.sha256(json.dumps(sources, sort_keys=True).encode()).hexdigest()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    manifest = dict(revision=revision, sources=sources, seed=SEED, numpy=np.__version__,
                    tool=conv.baseline.version(["verilator", "--version"]),
                    compiler=conv.baseline.version(["c++", "--version"]),
                    ram_mib=16, delay=1, policy=POLICY)
    manifest_path = root / "manifest.json"
    if manifest_path.is_file() and json.loads(manifest_path.read_text()) != manifest:
        raise ValueError("run manifest changed; use a fresh run ID")
    atomic_json(manifest_path, manifest)
    initial, layers = model()
    progress = dict(status="RUNNING", layers=[], pending=[layer[0] for layer in layers])
    status = root / "progress.json"
    atomic_json(status, progress)
    try:
        with ThreadPoolExecutor(max_workers=args.workers) as executor:
            smoke(root, identity, deadline, executor, initial, layers)
            if args.smoke_only:
                progress["status"] = "SMOKE_PASS"
            else:
                data = initial
                for name, weights, biases, pool in layers:
                    if conv.hashes(source_files()) != sources:
                        raise ValueError("inference sources changed during the run")
                    output, receipts = run_layer(name, weights, biases, pool, data, root,
                                                 identity, deadline, executor)
                    progress["layers"].append(layer_record(name, output, receipts))
                    progress["pending"].pop(0)
                    atomic_json(status, progress)
                    data = signed(output).transpose(2, 0, 1)
                macs = sum(record["rtl_totals"]["pim_macs"] for record in progress["layers"])
                if macs != EXPECTED_MACS:
                    raise ValueError(f"MAC coverage mismatch: {macs} != {EXPECTED_MACS}")
                progress.update(status="PASS", total_macs=macs, logits=data.ravel().tolist())
    except Exception as exc:
        progress.update(status="INCOMPLETE", failure=str(exc))
        atomic_json(status, progress)
        raise
    atomic_json(status, progress)
    print(f"{progress['status']}: {status}", flush=True)


if __name__ == "__main__":
    main()
