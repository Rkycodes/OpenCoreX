"""Run/check 120 larger-vector cases with compatibility and independent replay."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import run_scaling_study as scaling
from run_cache_study import CACHE_FIELDS, STATES, csv_text, run
from run_memory_latency_sweep import PROGRAM_FIELDS
from generate_tiling import SIZES, MODES, generate, program
from tiling_trace import trace, replay

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "obj_dir/verification/vector_tiling"
RESULTS = ROOT / "docs/evaluation/tiling-results"
LATENCIES = (1, 2, 5, 10, 20)
EXTRA_FIELDS = scaling.EXTRA_FIELDS + ("literal_reads", "signature_reads", "buffer_writes",
                                       "last_buffer_writes", "last_buffer_reads")
DERIVED = ("cycles_per_output", "cycles_per_product", "streaming_tiled_ratio",
           "tiling_saved_cycles", "tiling_improvement_pct", "cpu_offload_ratio",
           "code_bytes", "ram_reads", "ram_writes", "other_ram_writes",
           "setup_cycles", "execution_cycles", "completion_cycles", "literal_reads", "signature_reads")


def compile_tb(top, path, enabled, label, commands):
    # Reuse the established source-topology transformation and compiler helper;
    # its output stays in this study's build directory, never historical evidence.
    scaling.BUILD = BUILD
    return scaling.compile_tb(top, path, enabled, label, commands)


def compatibility(commands):
    source = (ROOT / "tb/benchmarks/opencorex_scaling_tb.sv").read_text()
    assert source.count(".BUFFER_WORDS(16)") == 1
    source = source.replace(".BUFFER_WORDS(16)", ".BUFFER_WORDS(128)")
    tb = BUILD / "opencorex_scaling_tb.sv"
    tb.write_text(source)
    old = list(csv.DictReader((ROOT / "docs/evaluation/scaling-results/programs.csv").open()))
    old_states = list(csv.DictReader((ROOT / "docs/evaluation/scaling-results/states.csv").open()))
    rows = []
    for enabled in (0, 1):
        directory, exe = compile_tb("opencorex_scaling_tb", tb, enabled, "buffer_compat", commands)
        for delay in LATENCIES:
            command = [str(exe), "+MODE=3", "+N=32", f"+DELAY={delay}"]
            commands.append(command)
            output = run(command, directory / f"offload_16_{delay}.log")
            parsed, fetches, states = scaling.parse(output)
            row = dict(zip(PROGRAM_FIELDS, parsed["PROGRAM"]))
            row.update(zip(CACHE_FIELDS, parsed["CACHE"]))
            row.update(mode="offload", cache_enabled=enabled, output_count=32)
            reference = next(r for r in old if r["mode"] == "offload" and
                             int(r["cache_enabled"]) == enabled and int(r["read_delay"]) == delay and
                             int(r["output_count"]) == 32)
            for key in PROGRAM_FIELDS + CACHE_FIELDS:
                assert str(row[key]) == reference[key], (key, row, reference)
            for state, count in states:
                saved = next(r for r in old_states if r["mode"] == "offload" and
                             int(r["cache_enabled"]) == enabled and int(r["read_delay"]) == delay and
                             int(r["output_count"]) == 32 and r["state"] == STATES[state])
                assert count == int(saved["cycles"])
            from scaling_trace import trace as old_trace
            assert fetches == [(a, int(m) if enabled else 0) for a, m in replay(old_trace("offload", 32))]
            assert "PASS: opencorex_scaling_tb" in output
            rows.append(row)
            print("BUFFER COMPAT", enabled, delay, row["whole_cycles"], flush=True)
    return rows


def limits(commands):
    directory = BUILD / "limits"
    directory.mkdir(exist_ok=True)
    package = ROOT / "rtl/pim/pim_pkg.sv"
    rtl = [package] + [p for p in sorted((ROOT / "rtl").glob("*/*.sv")) if p != package]
    command = ["verilator", "--binary", "--timing", "-Wall", "-j", "4",
               "--top-module", "opencorex_tiling_limits_tb", "--Mdir", str(directory)]
    command += [str(p) for p in rtl] + [str(ROOT / "tb/benchmarks/opencorex_tiling_limits_tb.sv")]
    commands.append(command)
    run(command, directory / "build.log")
    exe = directory / "Vopencorex_tiling_limits_tb"
    command = [str(exe)]
    commands.append(command)
    output = run(command, directory / "run.log")
    assert "PASS: opencorex_tiling_limits_tb" in output
    rows = [dict(zip(("vector_length", "error_code", "operand_reads", "output_writes"),
                     map(int, line.split(",")[1:]))) for line in output.splitlines() if line.startswith("LIMIT,")]
    assert rows == [dict(vector_length=129, error_code=5, operand_reads=0, output_writes=0),
                    dict(vector_length=0, error_code=5, operand_reads=0, output_writes=0),
                    dict(vector_length=128, error_code=0, operand_reads=4224, output_writes=32)]
    return rows


def primary(commands):
    traces, traffic = {}, {}
    for k in SIZES:
        for mode in MODES:
            addresses, traffic[mode, k] = trace(mode, k)
            traces[mode, k] = replay(addresses)
    builds = {enabled: compile_tb("opencorex_tiling_tb", ROOT / "tb/benchmarks/opencorex_tiling_tb.sv",
              enabled, "primary", commands) for enabled in (0, 1)}
    rows, state_rows, phases = [], [], []
    # Complete K=16, then a K=32 pilot, before larger-vector cases.
    for k in SIZES:
        for enabled in (0, 1):
            directory, exe = builds[enabled]
            for delay in LATENCIES:
                for number, mode in enumerate(MODES, 1):
                    command = [str(exe), f"+MODE={number}", f"+K={k}", f"+DELAY={delay}"]
                    commands.append(command)
                    output = run(command, directory / f"{mode}_{k}_{delay}.log")
                    assert f"PASS: opencorex_tiling_tb K={k}" in output
                    parsed, observed, states = scaling.parse(output)
                    expected = traces[mode, k]
                    assert observed == [(a, int(m) if enabled else 0) for a, m in expected]
                    assert len(parsed["PROGRAM"]) == len(PROGRAM_FIELDS)
                    assert len(parsed["CACHE"]) == len(CACHE_FIELDS)
                    row = dict(zip(PROGRAM_FIELDS, parsed["PROGRAM"]))
                    row.update(zip(CACHE_FIELDS, parsed["CACHE"]))
                    row.update(mode=mode, vector_length=k, cache_enabled=enabled)
                    for key in ("vector_reads", "matrix_reads", "cpu_other_reads", "cpu_muls",
                                "cpu_accumulating_adds", "offload_macs", "output_writes",
                                "completion_writes", "mmio_reads", "mmio_writes"):
                        assert row[key] == traffic[mode, k][key], (key, row)
                    assert row["fetches"] == len(expected)
                    assert row["pim_busy_cycles"] == row["busy_blocked"]
                    assert row["cpu_fetch_response_wait"] == (row["hits"] + row["misses"]*(5+4*delay)
                                                              if enabled else row["fetches"]*(delay-1))
                    if enabled:
                        assert row["hits"] + row["misses"] == row["fetches"]
                        assert row["misses"] == sum(m for _, m in expected)
                        assert row["refill_reads"] == 4*row["misses"]
                        bypass = next(r for r in rows if r["mode"] == mode and r["vector_length"] == k and
                                      r["read_delay"] == delay and r["cache_enabled"] == 0)
                        assert row["whole_cycles"] - bypass["whole_cycles"] == (
                            row["hits"]*(2-delay) + row["misses"]*(6+3*delay))
                        assert row["fetch_wait"] == row["refill_reads"]*(delay-1)
                    else:
                        assert row["hits"] == row["misses"] == row["refill_reads"] == 0
                        assert row["fetch_wait"] == row["fetches"]*(delay-1)
                    cpu_reads = row["cpu_other_reads"] + (row["vector_reads"] + 32*k if mode != "offload" else 0)
                    assert row["cpu_data_wait"] == cpu_reads*(delay-1)
                    assert row["pim_wait"] == ((33*k) if mode == "offload" else 0)*(delay-1)
                    assert len(states) == 16 and sum(count for _, count in states) == row["whole_cycles"]
                    state_rows += [dict(vector_length=k, mode=mode, cache_enabled=enabled, read_delay=delay,
                                        state=STATES[state], cycles=count) for state, count in states]
                    assert len(parsed["EXTRA"]) == len(EXTRA_FIELDS)
                    extra = dict(zip(EXTRA_FIELDS, parsed["EXTRA"]))
                    assert extra["literal_reads"] == traffic[mode, k]["literal_reads"]
                    assert extra["signature_reads"] == traffic[mode, k]["signature_reads"]
                    assert extra["ram_reads"] == (row["refill_reads"] if enabled else row["fetches"]) + \
                        row["vector_reads"] + 32*k + row["cpu_other_reads"]
                    assert extra["ram_writes"] == 33 and extra["other_ram_writes"] == 0
                    assert sum(extra[key] for key in ("setup_cycles", "execution_cycles", "completion_cycles")) == row["whole_cycles"]
                    if mode == "offload":
                        assert extra["execution_cycles"] == row["pim_busy_cycles"]
                        assert extra["buffer_reads"] == 31*k
                        assert extra["buffer_writes"] == k
                        assert extra["last_buffer_writes"] == (1 if k == 128 else 0)
                        assert extra["last_buffer_reads"] == (31 if k == 128 else 0)
                    else:
                        assert extra["buffer_reads"] == extra["buffer_writes"] == 0
                    row.update({key: extra[key] for key in DERIVED if key in extra})
                    phases.append(dict(vector_length=k, mode=mode, cache_enabled=enabled, read_delay=delay, **extra))
                    rows.append(row)
                    print("PRIMARY", k, mode, enabled, delay, row["whole_cycles"], flush=True)
    # Negative checks exercise executable-write rejection from both requesters.
    for enabled, (directory, exe) in builds.items():
        for number, mode in enumerate(MODES, 1):
            flag = "+PIM_CODE_WRITE" if mode == "offload" else "+CODE_WRITE"
            command = [str(exe), f"+MODE={number}", "+K=16", "+DELAY=5", flag]
            commands.append(command)
            result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
            (directory / f"{mode}_code_write.log").write_text(result.stdout + result.stderr)
            assert result.returncode and "immutable executable code write" in result.stdout
    for row in rows:
        def get(mode):
            return next(r for r in rows if r["mode"] == mode and r["vector_length"] == row["vector_length"] and
                        r["cache_enabled"] == row["cache_enabled"] and r["read_delay"] == row["read_delay"])
        stream, tiled, off = (get(m)["whole_cycles"] for m in MODES)
        row.update(cycles_per_output=f'{row["whole_cycles"]/32:.6f}',
                   cycles_per_product=f'{row["whole_cycles"]/(32*row["vector_length"]):.6f}',
                   streaming_tiled_ratio=f"{stream/tiled:.6f}", tiling_saved_cycles=stream-tiled,
                   tiling_improvement_pct=f"{100*(stream-tiled)/stream:.6f}",
                   cpu_offload_ratio=f'{row["whole_cycles"]/off:.6f}',
                   code_bytes=4 + 4*len(program(row["mode"], row["vector_length"])))
        first = next(r for r in rows if r["vector_length"] == row["vector_length"] and r["mode"] == row["mode"] and
                     r["cache_enabled"] == row["cache_enabled"] and r["read_delay"] == 1)
        assert row["whole_cycles"] - first["whole_cycles"] == row["fetch_wait"] + row["cpu_data_wait"] + row["pim_wait"]
    return rows, state_rows, phases, traces


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    BUILD.mkdir(parents=True, exist_ok=True)
    RESULTS.mkdir(parents=True, exist_ok=True)
    generate(args.check)
    commands = []
    compat = compatibility(commands)
    rows, states, phases, traces = primary(commands)
    limit_rows = limits(commands)
    files = {
        "programs.csv": csv_text(rows, ("vector_length", "cache_enabled") + PROGRAM_FIELDS + CACHE_FIELDS + DERIVED),
        "states.csv": csv_text(states, ("vector_length", "mode", "cache_enabled", "read_delay", "state", "cycles")),
        "phases.csv": csv_text(phases, ("vector_length", "mode", "cache_enabled", "read_delay") + EXTRA_FIELDS),
        "buffer-compatibility.csv": csv_text(compat, ("output_count", "cache_enabled") + PROGRAM_FIELDS + CACHE_FIELDS),
        "limits.csv": csv_text(limit_rows, ("vector_length", "error_code", "operand_reads", "output_writes"))}
    for (mode, k), events in traces.items():
        files[f"{mode}-{k}-trace.csv"] = csv_text(
            [dict(fetch=i, address=f"0x{a:08x}", miss=int(m)) for i, (a, m) in enumerate(events)],
            ("fetch", "address", "miss"))
    paths = sorted(list((ROOT / "rtl").glob("*/*.sv")) +
        [ROOT / f"scripts/{name}.py" for name in ("generate_tiling", "tiling_trace", "run_tiling_study",
         "generate_matvec_1x16_16x32", "scaling_trace", "run_scaling_study", "run_cache_study", "run_memory_latency_sweep")] +
        [ROOT / f"tb/benchmarks/{name}.sv" for name in ("opencorex_tiling_tb", "opencorex_tiling_limits_tb", "opencorex_scaling_tb")] +
        [ROOT / "tb/memory/latency_memory_responder.sv"] + list((ROOT / "programs/tiling/hex").glob("*.hex")) +
        [ROOT / "programs/scaling/hex/offload_32.hex", ROOT / "programs/scaling/hex/expected_32.hex"])
    provenance = dict(base_commit="cc81ed5f43b5ee930db5735cf10aabee51c8399c",
        verilator=subprocess.check_output(["verilator", "--version"], text=True).strip(),
        source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}, commands=commands)
    if args.check:
        saved = json.loads((RESULTS / "provenance.json").read_text())
        assert saved == provenance, "measured source or commands changed"
    else:
        (RESULTS / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    for name, value in files.items():
        path = RESULTS / name
        if args.check:
            assert path.read_text() == value, f"evidence differs: {path}"
        else:
            path.write_text(value)
    print("PASS: 120 primary, 10 buffer-only compatibility, 3 vector limits, 6 code-write rejections; independent replay and exact accounting")


if __name__ == "__main__":
    main()
