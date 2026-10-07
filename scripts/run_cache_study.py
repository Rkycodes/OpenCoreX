"""Build/check the 20-run October 19 instruction-cache study."""
import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import subprocess
from cache_trace import trace, replay
from run_memory_latency_sweep import PROGRAM_FIELDS

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "obj_dir/verification/cache_study"
RESULTS = ROOT / "docs/evaluation/cache-results"
CACHE_FIELDS = ("hits", "misses", "refill_reads", "cpu_muls", "cpu_accumulating_adds", "offload_macs", "cpu_other_reads", "cpu_fetch_response_wait", "pim_busy_cycles")
STATES = ("FETCH", "FETCH_CAPTURE", "DECODE", "R_EXEC", "I_EXEC", "ALU_WRITEBACK", "MEM_ADDR",
          "MEM_READ", "MEM_READ_CAPTURE", "MEM_WRITEBACK", "MEM_WRITE", "BRANCH_TARGET",
          "BRANCH_COMPARE", "JUMP_TARGET", "JUMP_COMPLETE", "ERROR")

def run(command, log):
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"{command}: {log.read_text()[-12000:]}")
    return result.stdout

def csv_text(rows, fields):
    out = io.StringIO()
    writer = csv.DictWriter(out, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return out.getvalue()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    BUILD.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "rtl/system/opencorex_pim_subsystem.sv").read_text()
    replacements = {
        "module opencorex_pim_subsystem #(": "module cache_study_subsystem #(",
        "    input logic reset,": "    input logic reset,\n    input int read_delay, fetch_delay,",
        "    synchronous_memory_adapter adapter_inst (":
            "    latency_memory_responder adapter_inst (\n        .read_delay, .fetch_delay, .is_fetch(1'b0),",
    }
    for old, new in replacements.items():
        assert source.count(old) == 1, old
        source = source.replace(old, new)
    generated = BUILD / "cache_study_subsystem.sv"
    generated.write_text(source)
    package = ROOT / "rtl/pim/pim_pkg.sv"
    rtl = [package] + [p for p in sorted((ROOT / "rtl").glob("*/*.sv")) if p != package]
    baseline = list(csv.DictReader((ROOT / "docs/evaluation/latency-results/programs.csv").open()))
    rows, state_rows, commands = [], [], []
    for enabled in (0, 1):
        directory = BUILD / str(enabled)
        directory.mkdir(exist_ok=True)
        command = ["verilator", "--binary", "--timing", "-Wall", "-j", "4",
                   "--top-module", "opencorex_cache_study_tb", f"-GCACHE_ENABLE=1'b{enabled}",
                   "--Mdir", str(directory)]
        command += [str(p) for p in rtl] + [str(generated),
            str(ROOT / "tb/memory/latency_memory_responder.sv"),
            str(ROOT / "tb/benchmarks/opencorex_cache_study_tb.sv")]
        run(command, directory / "build.log")
        commands.append(command)
        negative_command=[str(directory / "Vopencorex_cache_study_tb"),
                          "+MODE=2", "+DELAY=5", "+CODE_WRITE"]
        negative=subprocess.run(negative_command,cwd=ROOT,text=True,capture_output=True)
        (directory/"code-write-rejection.log").write_text(negative.stdout+negative.stderr)
        assert negative.returncode and "immutable executable code write" in negative.stdout
        commands.append(negative_command)
        for delay in (1, 2, 5, 10, 20):
            for mode, number in (("resident", 2), ("offload", 3)):
                command = [str(directory / "Vopencorex_cache_study_tb"),
                           f"+MODE={number}", f"+DELAY={delay}"]
                commands.append(command)
                output = run(command, directory / f"{mode}_{delay}.log")
                assert "PASS: opencorex_cache_study_tb" in output
                parsed = {}
                observed = []
                states = []
                for line in output.splitlines():
                    kind = line.split(",")[0]
                    if kind in ("PROGRAM", "CACHE"):
                        assert kind not in parsed
                        parsed[kind] = [int(v) for v in line.split(",")[1:]]
                    elif kind == "FETCH":
                        addr, miss = map(int, line.split(",")[1:])
                        observed.append((addr, bool(miss)))
                    elif kind == "STATE":
                        states.append(tuple(map(int, line.split(",")[1:])))
                expected = replay(trace(mode))
                assert [a for a, _ in observed] == [a for a, _ in expected]
                if enabled:
                    assert observed == expected
                fields = PROGRAM_FIELDS
                assert len(parsed["PROGRAM"]) == len(fields)
                row = dict(zip(fields, parsed["PROGRAM"]))
                row.update(zip(CACHE_FIELDS, parsed["CACHE"]))
                row["mode"] = mode
                row["cache_enabled"] = enabled
                rows.append(row)
                assert len(states) == 16 and sum(n for _, n in states) == row["whole_cycles"]
                for state, count in states:
                    state_rows.append(dict(mode=mode, cache_enabled=enabled,
                        read_delay=delay, state=STATES[state], cycles=count))
                old = next(r for r in baseline if r["policy"] == "unified"
                           and r["mode"] == mode and int(r["read_delay"]) == delay)
                for key in ("fetches", "vector_reads", "matrix_reads", "output_writes",
                            "completion_writes", "mmio_writes", "mmio_reads"):
                    assert row[key] == int(old[key]), (key, row, old)
                assert row["pim_busy_cycles"] == row["busy_blocked"]
                assert row["cpu_other_reads"] == (1 if mode == "resident" else 2)
                assert row["cpu_fetch_response_wait"] == (
                    row["hits"] + row["misses"]*(5+4*delay) if enabled
                    else row["fetches"]*(delay-1))
                if not enabled:
                    for key in PROGRAM_FIELDS[1:]:
                        assert row[key] == int(old[key]), (key, row, old)
                else:
                    bypass = next(r for r in rows if r["mode"] == mode
                                  and r["cache_enabled"] == 0 and r["read_delay"] == delay)
                    assert row["whole_cycles"] - bypass["whole_cycles"] == (
                        row["hits"] * (2-delay) + row["misses"] * (6+3*delay))
                    assert row["fetch_wait"] == row["refill_reads"] * (delay-1)
                print(mode, "cache", enabled, "L", delay, "cycles", row["whole_cycles"], flush=True)
    files = {"programs.csv": csv_text(rows, ("cache_enabled",) + PROGRAM_FIELDS + CACHE_FIELDS),
             "states.csv": csv_text(state_rows, ("mode", "cache_enabled", "read_delay", "state", "cycles"))}
    for mode in ("resident", "offload"):
        files[f"{mode}-trace.csv"] = csv_text(
            [dict(fetch=i, address=f"0x{a:08x}", miss=int(m)) for i,(a,m) in enumerate(replay(trace(mode)))],
            ("fetch", "address", "miss"))
    summary = ["# October 19 instruction-cache results", "",
        "Measured whole-program cycles; reset through accepted completion store. All 20 cases pass.",
        "Programs/operands unchanged. Registered lookup and full four-word refill are included.", "",
        "| L | CPU bypass | Offload bypass | CPU cache | Offload cache | Bypass ratio | Cache ratio | Bypass gap | Cache gap | Gap reduction |",
        "|---|---|---|---|---|---|---|---|---|---|"]
    for delay in (1,2,5,10,20):
        def get(mode, enabled):
            return next(r["whole_cycles"] for r in rows if r["mode"]==mode and
                        r["cache_enabled"]==enabled and r["read_delay"]==delay)
        cb, ob, cc, oc = get("resident",0),get("offload",0),get("resident",1),get("offload",1)
        summary.append(f"| {delay} | {cb} | {ob} | {cc} | {oc} | {cb/ob:.3f} | {cc/oc:.3f} | {cb-ob} | {cc-oc} | {(cb-ob)-(cc-oc)} |")
    summary += ["", "Independent RV32 trace replay agrees with every accepted fetch:",
        "resident 1,752 fetches / 21 misses / 1,731 hits / 84 refill words;",
        "offload 25 fetches / 7 misses / 18 hits / 28 refill words.",
        "The resident's 21 misses are first visits to distinct lines; the repeated loop has no later misses.",
        "Every run retains 16 vector reads, 512 matrix reads and 32 output writes.",
        "CPU uses 512 MULs plus 512 accumulating ADDs; offload uses 512 MACs.", "",
        "## Cycle accounting and interpretation", "",
        "For this no-contention, blocking study, a hit has acceptance-to-response latency 2;",
        "a full miss has latency 6+4L. Relative to bypass, measured whole-program change is",
        "hits*(2-L) + misses*(6+3L). Exact equality is checked in all enabled runs.",
        "At L=1 the cache adds lookup/refill overhead despite reducing instruction RAM traffic.",
        "At larger L repeated hits avoid backing waits, while compulsory full-line refills remain.",
        "Fetch-state response occupancy includes registered lookup and refill service;",
        "backing fetch_wait counts only delayed backing responses, so the counters overlap.",
        "CPU-state cycles are disjoint and sum to whole-program cycles. cpu_blocked includes",
        "request backpressure; busy_blocked is an overlapping subset. PIM waits overlap CPU busy.",
        "The CPU still executes separate scalar arithmetic, loads, address/control instructions",
        "and multicycle state transitions. The offload still streams all 512 matrix words.",
        "These counts support a residual-cost explanation, not a causal estimate for fused MAC.", "",
        "## Reproduction and limits", "",
        "Run `make cache-study` to regenerate; `python3 scripts/run_cache_study.py --check`",
        "requires exact agreement with tracked counters/traces. `make verify` includes that check.",
        "Commands, Verilator version and source hashes are in provenance.json;",
        "individual build/run logs are under obj_dir/verification/cache_study.",
        "The parent Git HEAD alone does not identify uncommitted changes: use the source hashes.",
        "Host placement and downstream consumption are excluded. Latencies are synthetic;",
        "no energy, area, calibrated DRAM or physical clock-time conclusions follow.",
        "No scaling, associativity, D8 or CIM results are claimed.", ""]
    summary += ["## Measured residual breakdown at L=20", "",
        "Disjoint whole-program groups derived from controller states; busy request",
        "clocks are removed from FETCH and shown separately.", "",
        "| Group | Resident CPU | Offload CPU/program |",
        "|---|---|---|"]
    groups = [
        ("Fetch request and response", ("FETCH","FETCH_CAPTURE")),
        ("Decode", ("DECODE",)),
        ("ALU execution and writeback", ("R_EXEC","I_EXEC","ALU_WRITEBACK")),
        ("Data/MMIO address, access and writeback",
         ("MEM_ADDR","MEM_READ","MEM_READ_CAPTURE","MEM_WRITEBACK","MEM_WRITE")),
        ("Branch/jump", ("BRANCH_TARGET","BRANCH_COMPARE","JUMP_TARGET","JUMP_COMPLETE"))]
    totals = [0,0]
    for label, names in groups:
        counts=[]
        for index, mode in enumerate(("resident","offload")):
            value=sum(r["cycles"] for r in state_rows if r["mode"]==mode and
                r["cache_enabled"]==1 and r["read_delay"]==20 and r["state"] in names)
            if label.startswith("Fetch"):
                value-=next(r["busy_blocked"] for r in rows if r["mode"]==mode and
                    r["cache_enabled"]==1 and r["read_delay"]==20)
            counts.append(value)
            totals[index]+=value
        summary.append(f"| {label} | {counts[0]} | {counts[1]} |")
    busy=next(r["busy_blocked"] for r in rows if r["mode"]=="offload" and
              r["cache_enabled"]==1 and r["read_delay"]==20)
    totals[1]+=busy
    assert totals==[23385,14955]
    summary += [f"| CPU blocked during offload | 0 | {busy} |",
        f"| Total | {totals[0]} | {totals[1]} |", "",
        "The 8,430-cycle residual is the difference of these complete paths.",
        "Its latency slope is 55 cycles per added backing-response cycle:",
        "resident has 84 refill + 529 data reads; offload has 28 refill + 530 data reads.",
        "The residual also includes cold spatial-refill costs and the selected lookup policy;",
        "it is not a pure measure of arithmetic or control advantage.", ""]
    files["README.md"] = "\n".join(summary)
    source_paths = sorted(list((ROOT/"rtl").glob("*/*.sv")) +
        [ROOT/"scripts/cache_trace.py", ROOT/"scripts/run_cache_study.py",
         ROOT/"scripts/run_memory_latency_sweep.py", ROOT/"tb/memory/latency_memory_responder.sv",
         ROOT/"tb/benchmarks/opencorex_cache_study_tb.sv",
         ROOT/"tb/benchmarks/opencorex_cached_cpu_tb.sv",
         ROOT/"tb/memory/instruction_cache_tb.sv", ROOT/"scripts/verify.sh"] +
        list((ROOT/"programs/hex").glob("*.hex")))
    provenance = dict(parent_head=subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
        verilator=subprocess.check_output(["verilator","--version"],text=True).strip(),
        commands=commands, source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                                         for p in source_paths})
    RESULTS.mkdir(parents=True,exist_ok=True)
    if not args.check:
        (RESULTS/"provenance.json").write_text(json.dumps(provenance,indent=2)+"\n")
    else:
        saved=json.loads((RESULTS/"provenance.json").read_text())
        assert saved["source_sha256"] == provenance["source_sha256"], "source changed; regenerate evidence"
    for name, data in files.items():
        path=RESULTS/name
        if args.check:
            assert path.read_text()==data, f"results differ: {path}"
        else:
            path.write_text(data)
    print("PASS: 20 cache-study cases, independent traces, baseline and cycle accounting")

if __name__ == "__main__":
    main()
