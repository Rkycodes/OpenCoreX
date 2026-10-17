"""Measure 64/128 square GEMM with exact binary replay and bounded host memory."""
import argparse
from array import array
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import gzip
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import sys
import run_scaling_study as scaling
from run_cache_study import CACHE_FIELDS, STATES, csv_text, run
from run_memory_latency_sweep import PROGRAM_FIELDS
from run_gemm_study import EXTRA as SMALL_EXTRA, DERIVED
from generate_gemm_large import generate, SIZES, MODES, program
from gemm_large_trace import trace, replay_events

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "obj_dir/verification/large_gemm"
RESULTS = ROOT / "docs/evaluation/gemm-large-results"
LATENCIES = (1, 2, 5, 10, 20)
EXTRA = SMALL_EXTRA + ("last_index_writes", "last_index_reads")


def encoded(addresses, enabled):
    if enabled:
        words = array("I", (a | (int(m) << 31) for a, m in replay_events(addresses)))
    else:
        words = array("I", addresses)
    assert words.itemsize == 4
    if sys.byteorder != "little": words.byteswap()
    return words


def compare_binary(path, words):
    expected = memoryview(words).cast("B")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for offset in range(0, len(expected), 1 << 20):
            length = min(1 << 20, len(expected)-offset)
            chunk = stream.read(length)
            assert len(chunk) == length and chunk == expected[offset:offset+length], f"fetch trace mismatch at byte {offset}: {path}"
            digest.update(chunk)
        assert not stream.read(1), f"extra fetch bytes: {path}"
    # Retain the shared compressed prediction and measured digest, rather than
    # tens of identical 70 MB raw copies. Failed traces remain for debugging.
    assert path.parent.resolve().is_relative_to(BUILD.resolve()) and path.name.endswith(".fetch.bin")
    path.unlink()
    return digest.hexdigest()


def execute(exe, directory, s, enabled, delay, mode, words, commands, label=""):
    number = MODES.index(mode)+1
    stem = f"{label}{mode}_{s}_{delay}"
    binary = directory/f"{stem}.fetch.bin"
    command = [str(exe), f"+MODE={number}", f"+N={s}", f"+DELAY={delay}", f"+TRACE_FILE={binary}"]
    commands.append(command)
    return command, directory/f"{stem}.log", binary


def validate(output, binary, words, traffic, s, enabled, delay, mode):
    assert f"PASS: opencorex_gemm_large_tb N={s}" in output
    parsed, fetches, states = scaling.parse(output)
    assert not fetches
    assert len(parsed["PROGRAM"]) == len(PROGRAM_FIELDS) and len(parsed["CACHE"]) == len(CACHE_FIELDS)
    assert len(parsed["EXTRA"]) == len(EXTRA)
    row = dict(zip(PROGRAM_FIELDS, parsed["PROGRAM"]))
    row.update(zip(CACHE_FIELDS, parsed["CACHE"]))
    row.update(zip(EXTRA, parsed["EXTRA"]))
    row.update(order=s, mode=mode, cache_enabled=enabled, trace_sha256=compare_binary(binary, words))
    for key in ("vector_reads", "matrix_reads", "cpu_muls", "cpu_accumulating_adds", "offload_macs",
                "output_writes", "completion_writes", "cpu_other_reads", "literal_reads", "signature_reads", "mmio_reads", "mmio_writes"):
        assert row[key] == traffic[key], (key, row)
    assert row["fetches"] == len(words)
    assert row["misses"] == ({"streaming":8, "tiled":12, "offload":8}[mode] if enabled else 0)
    assert row["hits"] == (len(words)-row["misses"] if enabled else 0)
    assert row["refill_reads"] == 4*row["misses"]
    assert row["ram_reads"] == (row["refill_reads"] if enabled else row["fetches"]) + row["vector_reads"]+row["matrix_reads"]+row["cpu_other_reads"]
    assert row["ram_writes"] == s*s+1 and row["other_ram_writes"] == 0
    assert row["buffer_writes"] == (s*s if mode == "offload" else 0)
    assert row["buffer_reads"] == (s*s*(s-1) if mode == "offload" else 0)
    assert row["commands_started"] == row["begin_vectors"] == (s if mode == "offload" else 0)
    assert row["command_cycles"] == row["pim_busy_cycles"] == row["busy_blocked"]
    assert row["last_index_writes"] == (128 if mode == "offload" and s == 128 else 0)
    assert row["last_index_reads"] == (128*127 if mode == "offload" and s == 128 else 0)
    assert len(states) == 16 and sum(n for _, n in states) == row["whole_cycles"]
    assert row["cpu_fetch_response_wait"] == (row["hits"]+row["misses"]*(5+4*delay) if enabled else row["fetches"]*(delay-1))
    assert row["fetch_wait"] == (row["refill_reads"] if enabled else row["fetches"])*(delay-1)
    operands = row["vector_reads"]+row["matrix_reads"]
    assert row["cpu_data_wait"] == (row["cpu_other_reads"]+(operands if mode != "offload" else 0))*(delay-1)
    assert row["pim_wait"] == (operands if mode == "offload" else 0)*(delay-1)
    intervals = [list(map(int, line.split(",")[1:])) for line in output.splitlines() if line.startswith("ROW,")]
    assert len(intervals) == (s if mode == "offload" else 0)
    assert sum(c[3] for c in intervals) == row["command_cycles"]
    for i, (index, start, final, execution) in enumerate(intervals):
        assert index == i and final-start == execution and start < final
        if i: assert start > intervals[i-1][2]
    return row, states, intervals


def baseline(commands, builds):
    saved = list(csv.DictReader((ROOT/"docs/evaluation/gemm-results/programs.csv").open()))
    rows = []
    for s in (16, 32):
        for mode in MODES:
            # Existing full CSV traces calibrate the binary transport independently
            # of the new large-workload interpreter.
            with gzip.open(ROOT/f"docs/evaluation/gemm-results/{mode}-{s}-trace.csv.gz", "rt") as stream:
                events = [(int(r["address"], 16), int(r["miss"])) for r in csv.DictReader(stream)]
            for enabled, (directory, exe) in builds.items():
                words = array("I", (a | ((m if enabled else 0) << 31) for a, m in events))
                if sys.byteorder != "little": words.byteswap()
                command, log, binary = execute(exe, directory, s, enabled, 1, mode, words, commands, "baseline_")
                output = run(command, log)
                parsed, _, states = scaling.parse(output)
                row = dict(zip(PROGRAM_FIELDS, parsed["PROGRAM"]))
                row.update(zip(CACHE_FIELDS, parsed["CACHE"]))
                row.update(zip(EXTRA, parsed["EXTRA"]))
                row.update(order=s, mode=mode, cache_enabled=enabled)
                reference = next(r for r in saved if int(r["order"]) == s and r["mode"] == mode and
                                 int(r["cache_enabled"]) == enabled and int(r["read_delay"]) == 1)
                for key in PROGRAM_FIELDS+CACHE_FIELDS+SMALL_EXTRA:
                    assert str(row[key]) == reference[key], (key, row, reference)
                assert sum(n for _, n in states) == row["whole_cycles"]
                assert f"PASS: opencorex_gemm_large_tb N={s}" in output
                row["trace_sha256"] = compare_binary(binary, words)
                rows.append(row)
                print("BASELINE", s, mode, enabled, row["whole_cycles"], flush=True)
    return rows


def negatives(commands, builds):
    for enabled, (directory, exe) in builds.items():
        tests = [(mode, f"+MODE={i}", "+N=64", "+PIM_CODE_WRITE" if mode == "offload" else "+CODE_WRITE",
                  "immutable executable code write") for i, mode in enumerate(MODES, 1)]
        tests += [(f"size_{s}", "+MODE=3", f"+N={s}", "+INVALID_SIZE", "invalid GEMM arguments") for s in (0, 129)]
        for label, mode, size, flag, expected in tests:
            binary = directory/f"negative_{label}.fetch.bin"
            command = [str(exe), mode, size, "+DELAY=5", flag, f"+TRACE_FILE={binary}"]
            commands.append(command)
            result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
            (directory/f"negative_{label}.log").write_text(result.stdout+result.stderr)
            assert result.returncode and expected in result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--baseline-only", action="store_true")
    args = parser.parse_args()
    assert 1 <= args.workers <= 4
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    BUILD.mkdir(parents=True, exist_ok=True)
    RESULTS.mkdir(parents=True, exist_ok=True)
    generate(args.check)
    commands = []
    scaling.BUILD = BUILD
    builds = {c: scaling.compile_tb("opencorex_gemm_large_tb", ROOT/"tb/benchmarks/opencorex_gemm_large_tb.sv", c, "primary", commands) for c in (0, 1)}
    baselines = baseline(commands, builds)
    if args.baseline_only:
        print("PASS: 12 small-job counter and exact binary-trace calibration runs")
        return
    rows, states, intervals, trace_rows = [], [], [], []
    files = {}
    for s in SIZES:
        predictions = {}
        for mode in MODES:
            print("INTERPRET", s, mode, flush=True)
            addresses, traffic = trace(mode, s)
            predictions[mode] = (addresses, encoded(addresses, True), traffic)
        for enabled, (directory, exe) in builds.items():
            expected = {mode: predictions[mode][1 if enabled else 0] for mode in MODES}
            if sys.byteorder != "little" and not enabled:
                expected = {mode: encoded(predictions[mode][0], False) for mode in MODES}
            for mode, words in expected.items():
                raw = memoryview(words).cast("B")
                trace_rows.append(dict(order=s, mode=mode, cache_enabled=enabled, fetches=len(words),
                                       sha256=hashlib.sha256(raw).hexdigest()))
                files[f"{mode}-{s}-cache{enabled}.fetch.bin.gz"] = gzip.compress(raw, mtime=0)
            jobs = []
            for delay in LATENCIES:
                for mode in MODES:
                    command, log, binary = execute(exe, directory, s, enabled, delay, mode, expected[mode], commands)
                    jobs.append((command, log, binary, delay, mode))
            def job(item):
                command, log, binary, delay, mode = item
                return validate(run(command, log), binary, expected[mode], predictions[mode][2], s, enabled, delay, mode)
            with ThreadPoolExecutor(max_workers=args.workers) as pool:
                futures = [pool.submit(job, item) for item in jobs]
                for future in as_completed(futures):
                    row, partition, command_intervals = future.result()
                    rows.append(row)
                    states += [dict(order=s, mode=row["mode"], cache_enabled=enabled, read_delay=row["read_delay"], state=STATES[index], cycles=count) for index, count in partition]
                    intervals += [dict(order=s, cache_enabled=enabled, read_delay=row["read_delay"], row=index,
                        start_edge=start, final_output_edge=final, execution_cycles=duration) for index, start, final, duration in command_intervals]
                    print("GEMM", s, row["mode"], enabled, row["read_delay"], row["whole_cycles"], flush=True)
    negatives(commands, builds)
    rows.sort(key=lambda r: (r["order"], r["cache_enabled"], r["read_delay"], MODES.index(r["mode"])))
    states.sort(key=lambda r: (r["order"], r["cache_enabled"], r["read_delay"], MODES.index(r["mode"]), STATES.index(r["state"])))
    intervals.sort(key=lambda r: (r["order"], r["cache_enabled"], r["read_delay"], r["row"]))
    for row in rows:
        def selected(mode, cache=None, delay=None):
            return next(r for r in rows if r["order"] == row["order"] and r["mode"] == mode and
                        r["cache_enabled"] == (row["cache_enabled"] if cache is None else cache) and
                        r["read_delay"] == (row["read_delay"] if delay is None else delay))
        stream, tiled, off = (selected(m)["whole_cycles"] for m in MODES)
        s = row["order"]
        row.update(cycles_per_output=f'{row["whole_cycles"]/(s*s):.6f}', cycles_per_product=f'{row["whole_cycles"]/(s*s*s):.6f}',
            streaming_tiled_ratio=f"{stream/tiled:.6f}", tiling_improvement_pct=f"{100*(1-tiled/stream):.6f}",
            method_offload_ratio=f'{row["whole_cycles"]/off:.6f}', code_bytes=4+4*len(program(row["mode"], s)),
            command_overhead_cycles=row["whole_cycles"]-row["command_cycles"] if row["mode"] == "offload" else 0)
        if row["cache_enabled"]:
            assert row["whole_cycles"]-selected(row["mode"], 0)["whole_cycles"] == row["hits"]*(2-row["read_delay"])+row["misses"]*(6+3*row["read_delay"])
        assert row["whole_cycles"]-selected(row["mode"], delay=1)["whole_cycles"] == row["fetch_wait"]+row["cpu_data_wait"]+row["pim_wait"]
    files.update({
        "programs.csv": csv_text(rows, ("order", "cache_enabled")+PROGRAM_FIELDS+CACHE_FIELDS+EXTRA+DERIVED+("trace_sha256",)),
        "states.csv": csv_text(states, ("order", "mode", "cache_enabled", "read_delay", "state", "cycles")),
        "commands.csv": csv_text(intervals, ("order", "cache_enabled", "read_delay", "row", "start_edge", "final_output_edge", "execution_cycles")),
        "traces.csv": csv_text(trace_rows, ("order", "mode", "cache_enabled", "fetches", "sha256")),
        "baseline.csv": csv_text(baselines, ("order", "cache_enabled")+PROGRAM_FIELDS+CACHE_FIELDS+EXTRA+("trace_sha256",))})
    paths = sorted(list((ROOT/"rtl").glob("*/*.sv"))+list((ROOT/"programs/gemm-large/hex").glob("*.hex"))+
        list((ROOT/"programs/gemm/hex").glob("*.hex"))+list((ROOT/"docs/evaluation/gemm-results").glob("*trace.csv.gz"))+
        [ROOT/"docs/evaluation/gemm-results/programs.csv", ROOT/"tb/benchmarks/opencorex_gemm_large_tb.sv", ROOT/"tb/memory/latency_memory_responder.sv"]+
        [ROOT/f"scripts/{n}.py" for n in ("generate_gemm_large", "gemm_large_trace", "run_gemm_large", "generate_gemm", "run_gemm_study", "scaling_trace", "generate_matvec_1x16_16x32", "run_scaling_study", "run_cache_study", "run_memory_latency_sweep")])
    provenance = dict(base_commit="6b2141e55c3d18d44f7b425876b711296b32a860", commands=commands,
        verilator=subprocess.check_output(["verilator", "--version"], text=True).strip(),
        source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths})
    if args.check: assert json.loads((RESULTS/"provenance.json").read_text()) == provenance, "source or commands changed"
    else: (RESULTS/"provenance.json").write_text(json.dumps(provenance, indent=2)+"\n")
    for name, content in files.items():
        data = content if isinstance(content, bytes) else content.encode()
        if args.check: assert (RESULTS/name).read_bytes() == data, name
        else: (RESULTS/name).write_bytes(data)
    print("PASS: 60 larger GEMM cases, 12 baseline calibrations, 6 code-write and 4 unsupported-size rejections, exact binary replay and cycle accounting")


if __name__ == "__main__":
    main()
