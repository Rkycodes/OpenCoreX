"""Run/check 16x16 and 32x32 complete-job scalar/tiled/digital GEMM evidence."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import run_scaling_study as scaling
from run_cache_study import CACHE_FIELDS, STATES, csv_text, run
from run_memory_latency_sweep import PROGRAM_FIELDS
from generate_gemm import generate, program, SIZES, MODES
from gemm_trace import trace, replay

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "obj_dir/verification/square_gemm"
RESULTS = ROOT / "docs/evaluation/gemm-results"
LATENCIES = (1, 2, 5, 10, 20)
EXTRA = ("ram_reads", "ram_writes", "other_ram_writes", "literal_reads", "signature_reads",
         "buffer_writes", "buffer_reads", "commands_started", "command_cycles", "begin_vectors")
DERIVED = ("cycles_per_output", "cycles_per_product", "streaming_tiled_ratio", "tiling_improvement_pct",
           "method_offload_ratio", "code_bytes", "command_overhead_cycles")


def primary(commands):
    predictions = {(mode, s): trace(mode, s) for s in SIZES for mode in MODES}
    scaling.BUILD = BUILD
    builds = {enabled: scaling.compile_tb("opencorex_gemm_tb", ROOT/"tb/benchmarks/opencorex_gemm_tb.sv",
              enabled, "primary", commands) for enabled in (0, 1)}
    rows, state_rows, command_rows = [], [], []
    for s in SIZES:
        for enabled in (0, 1):
            directory, exe = builds[enabled]
            for delay in LATENCIES:
                for number, mode in enumerate(MODES, 1):
                    command = [str(exe), f"+MODE={number}", f"+N={s}", f"+DELAY={delay}"]
                    commands.append(command)
                    output = run(command, directory/f"{mode}_{s}_{delay}.log")
                    assert f"PASS: opencorex_gemm_tb N={s}" in output
                    parsed, observed, states = scaling.parse(output)
                    addresses, traffic = predictions[mode, s]
                    events = replay(addresses)
                    assert observed == [(a, int(m) if enabled else 0) for a, m in events]
                    assert len(parsed["PROGRAM"]) == len(PROGRAM_FIELDS)
                    assert len(parsed["CACHE"]) == len(CACHE_FIELDS)
                    assert len(parsed["EXTRA"]) == len(EXTRA)
                    row = dict(zip(PROGRAM_FIELDS, parsed["PROGRAM"]))
                    row.update(zip(CACHE_FIELDS, parsed["CACHE"]))
                    row.update(zip(EXTRA, parsed["EXTRA"]))
                    row.update(order=s, mode=mode, cache_enabled=enabled)
                    for key in ("vector_reads", "matrix_reads", "cpu_muls", "cpu_accumulating_adds",
                                "offload_macs", "output_writes", "completion_writes", "cpu_other_reads",
                                "literal_reads", "signature_reads", "mmio_reads", "mmio_writes"):
                        assert row[key] == traffic[key], (key, row)
                    assert row["fetches"] == len(addresses)
                    assert row["ram_reads"] == (row["refill_reads"] if enabled else row["fetches"]) + \
                        row["vector_reads"]+row["matrix_reads"]+row["cpu_other_reads"]
                    assert row["ram_writes"] == s*s+1 and row["other_ram_writes"] == 0
                    assert row["buffer_writes"] == (s*s if mode == "offload" else 0)
                    assert row["buffer_reads"] == (s*s*(s-1) if mode == "offload" else 0)
                    assert row["commands_started"] == row["begin_vectors"] == (s if mode == "offload" else 0)
                    assert row["command_cycles"] == row["pim_busy_cycles"] == row["busy_blocked"]
                    assert len(states) == 16 and sum(count for _, count in states) == row["whole_cycles"]
                    state_rows += [dict(order=s, mode=mode, cache_enabled=enabled, read_delay=delay,
                                        state=STATES[state], cycles=count) for state, count in states]
                    assert row["cpu_fetch_response_wait"] == (row["hits"] + row["misses"]*(5+4*delay)
                                                              if enabled else row["fetches"]*(delay-1))
                    if enabled:
                        assert row["hits"]+row["misses"] == row["fetches"]
                        assert row["misses"] == sum(m for _, m in events)
                        assert row["refill_reads"] == 4*row["misses"]
                        bypass = next(r for r in rows if r["order"] == s and r["mode"] == mode and
                                      r["cache_enabled"] == 0 and r["read_delay"] == delay)
                        assert row["whole_cycles"]-bypass["whole_cycles"] == row["hits"]*(2-delay)+row["misses"]*(6+3*delay)
                    else:
                        assert row["hits"] == row["misses"] == row["refill_reads"] == 0
                    assert row["fetch_wait"] == (row["refill_reads"] if enabled else row["fetches"])*(delay-1)
                    operands = row["vector_reads"]+row["matrix_reads"]
                    assert row["cpu_data_wait"] == (row["cpu_other_reads"]+(operands if mode != "offload" else 0))*(delay-1)
                    assert row["pim_wait"] == (operands if mode == "offload" else 0)*(delay-1)
                    observed_commands = [list(map(int, line.split(",")[1:])) for line in output.splitlines() if line.startswith("ROW,")]
                    assert len(observed_commands) == (s if mode == "offload" else 0)
                    assert sum(c[3] for c in observed_commands) == row["command_cycles"]
                    for index, (number, start, final, execution) in enumerate(observed_commands):
                        assert number == index and final-start == execution and start < final
                        if index: assert start > observed_commands[index-1][2]
                        command_rows.append(dict(order=s, cache_enabled=enabled, read_delay=delay,
                            row=index, start_edge=start, final_output_edge=final, execution_cycles=execution))
                    rows.append(row)
                    print("GEMM", s, mode, enabled, delay, row["whole_cycles"], flush=True)
    for enabled, (directory, exe) in builds.items():
        for number, mode in enumerate(MODES, 1):
            flag = "+PIM_CODE_WRITE" if mode == "offload" else "+CODE_WRITE"
            command = [str(exe), f"+MODE={number}", "+N=16", "+DELAY=5", flag]
            commands.append(command)
            result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
            (directory/f"{mode}_code_write.log").write_text(result.stdout+result.stderr)
            assert result.returncode and "immutable executable code write" in result.stdout
    for row in rows:
        def cycles(mode):
            return next(r["whole_cycles"] for r in rows if r["order"] == row["order"] and r["mode"] == mode and
                        r["cache_enabled"] == row["cache_enabled"] and r["read_delay"] == row["read_delay"])
        stream, tile, off = (cycles(mode) for mode in MODES)
        s = row["order"]
        row.update(cycles_per_output=f'{row["whole_cycles"]/(s*s):.6f}',
                   cycles_per_product=f'{row["whole_cycles"]/(s*s*s):.6f}',
                   streaming_tiled_ratio=f"{stream/tile:.6f}",
                   tiling_improvement_pct=f"{100*(1-tile/stream):.6f}",
                   method_offload_ratio=f'{row["whole_cycles"]/off:.6f}',
                   code_bytes=4+4*len(program(row["mode"], s)),
                   command_overhead_cycles=row["whole_cycles"]-row["command_cycles"] if row["mode"] == "offload" else 0)
        first = next(r for r in rows if r["order"] == s and r["mode"] == row["mode"] and
                     r["cache_enabled"] == row["cache_enabled"] and r["read_delay"] == 1)
        assert row["whole_cycles"]-first["whole_cycles"] == row["fetch_wait"]+row["cpu_data_wait"]+row["pim_wait"]
    return rows, state_rows, command_rows, predictions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    BUILD.mkdir(parents=True, exist_ok=True)
    RESULTS.mkdir(parents=True, exist_ok=True)
    generate(args.check)
    commands = []
    rows, states, command_rows, predictions = primary(commands)
    files = {
        "programs.csv": csv_text(rows, ("order", "cache_enabled")+PROGRAM_FIELDS+CACHE_FIELDS+EXTRA+DERIVED),
        "states.csv": csv_text(states, ("order", "mode", "cache_enabled", "read_delay", "state", "cycles")),
        "commands.csv": csv_text(command_rows, ("order", "cache_enabled", "read_delay", "row", "start_edge", "final_output_edge", "execution_cycles"))}
    for (mode, s), (addresses, _) in predictions.items():
        data = csv_text([dict(fetch=i, address=f"0x{a:08x}", miss=int(m)) for i, (a, m) in enumerate(replay(addresses))],
                        ("fetch", "address", "miss"))
        files[f"{mode}-{s}-trace.csv.gz"] = gzip.compress(data.encode(), mtime=0)
    paths = sorted(list((ROOT/"rtl").glob("*/*.sv"))+list((ROOT/"programs/gemm/hex").glob("*.hex"))+
        [ROOT/f"scripts/{name}.py" for name in ("generate_gemm", "gemm_trace", "run_gemm_study", "generate_matvec_1x16_16x32",
         "scaling_trace", "run_scaling_study", "run_cache_study", "run_memory_latency_sweep")]+
        [ROOT/"tb/benchmarks/opencorex_gemm_tb.sv", ROOT/"tb/memory/latency_memory_responder.sv"])
    provenance = dict(base_commit="7c6f323753540135d4260d636bf8cc04adad4cc1",
        verilator=subprocess.check_output(["verilator", "--version"], text=True).strip(), commands=commands,
        source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths})
    if args.check:
        assert json.loads((RESULTS/"provenance.json").read_text()) == provenance, "measured source or command identity changed"
    else:
        (RESULTS/"provenance.json").write_text(json.dumps(provenance, indent=2)+"\n")
    for name, content in files.items():
        path = RESULTS/name
        data = content if isinstance(content, bytes) else content.encode()
        if args.check: assert path.read_bytes() == data, f"recorded evidence differs: {path}"
        else: path.write_bytes(data)
    print("PASS: 60 GEMM configurations, 6 code-write rejections, all outputs/unchanged inputs, cold row commands, independent replay and exact accounting")


if __name__ == "__main__":
    main()
