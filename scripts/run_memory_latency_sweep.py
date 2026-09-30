#!/usr/bin/env python3
"""Run matched response-latency experiments using unmodified production RTL."""
import argparse
import csv
import io
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "obj_dir/verification/memory_latency"
SOURCES = ROOT / "obj_dir/verification/latency_sources"
RESULTS = ROOT / "docs/evaluation/latency-results"
MODES = ("looped", "streaming", "resident", "offload", "cold_warm")
PROGRAM_FIELDS = ("mode", "read_delay", "fetch_delay", "whole_cycles", "fetches",
                  "vector_reads", "matrix_reads", "output_writes", "completion_writes",
                  "mmio_writes", "mmio_reads", "cpu_blocked", "busy_blocked",
                  "fetch_wait", "cpu_data_wait", "pim_wait")
COMMAND_FIELDS = ("mode", "read_delay", "fetch_delay", "command", "start_edge", "final_edge",
                  "execution_cycles", "cpu_blocked", "setup_cycles", "completion_cycles",
                  "vector_reads", "matrix_reads", "output_writes", "buffer_writes",
                  "buffer_reads", "macs", "pim_wait")


def build():
    unit = ROOT / "obj_dir/verification/latency_responder_unit"
    unit.mkdir(parents=True, exist_ok=True)
    unit_command = ["verilator", "--binary", "--timing", "-Wall", "-j", "4",
                    "--top-module", "latency_memory_responder_tb", "--Mdir", str(unit),
                    str(ROOT / "rtl/memory/memory.sv"),
                    str(ROOT / "tb/memory/latency_memory_responder.sv"),
                    str(ROOT / "tb/memory/latency_memory_responder_tb.sv")]
    print("UNIT BUILD:", " ".join(unit_command), flush=True)
    with (unit / "build.log").open("w") as log:
        result = subprocess.run(unit_command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((unit / "build.log").read_text())
        raise SystemExit(result.returncode)
    subprocess.run([str(unit / "Vlatency_memory_responder_tb")], cwd=ROOT, check=True)
    SOURCES.mkdir(parents=True, exist_ok=True)
    BUILD.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "rtl/system/opencorex_pim_subsystem.sv").read_text()
    # Mechanical substitution keeps the full production topology, signal names,
    # parameter values and module instances; fail rather than silently drift.
    changes = {
        "module opencorex_pim_subsystem #(": "module latency_pim_subsystem #(",
        "    input logic reset,": "    input logic reset,\n    input int read_delay, fetch_delay,",
        "    synchronous_memory_adapter adapter_inst (":
        "    latency_memory_responder adapter_inst (\n"
        "        .read_delay, .fetch_delay,\n"
        "        .is_fetch(ram_req_valid && ram_req_ready && core_inst.MemRead && !core_inst.MemAddrSource),",
    }
    for old, new in changes.items():
        assert source.count(old) == 1, f"production topology changed: {old}"
        source = source.replace(old, new)
    generated = SOURCES / "latency_pim_subsystem.sv"
    generated.write_text(source)
    package = ROOT / "rtl/pim/pim_pkg.sv"
    rtl = [package] + [p for p in sorted((ROOT / "rtl").glob("*/*.sv")) if p != package]
    command = ["verilator", "--binary", "--timing", "-Wall", "-j", "4",
               "--top-module", "opencorex_memory_latency_tb", "--Mdir", str(BUILD)]
    command += [str(p) for p in rtl]
    command += [str(generated), str(ROOT / "tb/memory/latency_memory_responder.sv"),
                str(ROOT / "tb/benchmarks/opencorex_memory_latency_tb.sv")]
    print("BUILD:", " ".join(command), flush=True)
    with (BUILD / "build.log").open("w") as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((BUILD / "build.log").read_text())
        raise SystemExit(result.returncode)


def csv_text(rows, fields):
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=("policy",) + fields, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="rerun all cases and require exact agreement with tracked CSVs")
    args = parser.parse_args()
    build()
    program_rows, command_rows = [], []
    executable = BUILD / "Vopencorex_memory_latency_tb"
    for fixed_fetch in (0, 1):
        policy = "unified" if fixed_fetch == 0 else "fixed_fetch"
        for delay in (1, 2, 5, 10, 20):
            for mode in range(5):
                command = [str(executable), f"+MODE={mode}", f"+DELAY={delay}",
                           f"+FIXED_FETCH={fixed_fetch}"]
                result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
                log = BUILD / f"{policy}_{delay}_{MODES[mode]}.log"
                log.write_text(result.stdout + result.stderr)
                if result.returncode or "PASS: opencorex_memory_latency_tb" not in result.stdout:
                    print(log.read_text())
                    raise SystemExit(f"Failed: {' '.join(command)}")
                counts = {"PROGRAM": 0, "COMMAND": 0}
                for line in result.stdout.splitlines():
                    kind = line.split(",", 1)[0]
                    if kind not in counts:
                        continue
                    counts[kind] += 1
                    fields = PROGRAM_FIELDS if kind == "PROGRAM" else COMMAND_FIELDS
                    values = [int(v) for v in line.split(",")[1:]]
                    assert len(values) == len(fields), line
                    row = dict(zip(fields, values))
                    assert row["mode"] == mode and row["read_delay"] == delay
                    assert row["fetch_delay"] == (1 if fixed_fetch else delay)
                    row["mode"] = MODES[mode]
                    row["policy"] = policy
                    (program_rows if kind == "PROGRAM" else command_rows).append(row)
                    print(policy, line, flush=True)
                assert counts == {"PROGRAM": 1, "COMMAND": 2 if mode == 4 else 1 if mode == 3 else 0}
    RESULTS.mkdir(parents=True, exist_ok=True)
    for name, rows, fields in (("programs.csv", program_rows, PROGRAM_FIELDS),
                               ("commands.csv", command_rows, COMMAND_FIELDS)):
        path = RESULTS / name
        data = csv_text(rows, fields)
        if args.check:
            assert path.read_text() == data, f"results differ: {path}"
        else:
            path.write_text(data)
    print("PASS: all 50 program configurations / 30 PIM commands; 32 outputs checked per execution")


if __name__ == "__main__":
    main()
