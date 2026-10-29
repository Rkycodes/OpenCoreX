"""Measure conv1 variants A-D in RTL, with exact independent RV32 fetch replay."""
import argparse
from array import array
from concurrent.futures import ThreadPoolExecutor
import csv
import hashlib
import json
from pathlib import Path
import platform
import resource
import subprocess
import sys

import generate_conv1 as gen
from conv1_trace import trace
from gemm_large_trace import replay_events
import run_scaling_study as scaling
from run_cache_study import csv_text, run

ROOT, BUILD = gen.ROOT, gen.BUILD
RESULTS = ROOT/"docs/evaluation/conv1-results"
MODE_NUMBER = {mode:i+1 for i,mode in enumerate(gen.MODES)}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parsed(output):
    metrics,states,commands = {},[],[]
    for line in output.splitlines():
        parts = line.split(",")
        if parts[0] == "METRIC":
            assert parts[1] not in metrics
            metrics[parts[1]] = int(parts[2])
        elif parts[0] == "STATE":
            states.append(tuple(map(int,parts[1:])))
        elif parts[0] == "COMMAND":
            commands.append(tuple(map(int,parts[1:])))
    assert "PASS: opencorex_conv1_tb" in output
    return metrics,states,commands


def arguments(executable, case, mode, latency, record):
    return [str(executable),f"+MODE={MODE_NUMBER[mode]}",f"+DELAY={latency}",
            f"+IMAGE={ROOT/record['image']}", f"+BIAS_PC={record['bias_pc']:x}"] + [
        f"+{flag}={gen.IMAGES/f'{case}_{name}.hex'}"
        for flag,name in (("RAW","raw"),("BIASED","biased"),("FINAL","final"),("PATCHES","patches"))]


def encoded(addresses, cache):
    words = array("I",(address | (0x80000000 if cache and miss else 0)
                       for address,miss in replay_events(addresses)))
    if sys.byteorder != "little":
        words.byteswap()
    return words.tobytes()


def audit(directory):
    gen.generate(True)
    receipt = json.loads((directory/"provenance.json").read_text())
    for path,expected in receipt["source_sha256"].items():
        assert digest(ROOT/path) == expected, ("source identity",path)
    for path,expected in receipt["artifact_sha256"].items():
        assert digest(ROOT/path) == expected, ("artifact identity",path)
    rows = list(csv.DictReader((directory/"programs.csv").open()))
    for row in rows:
        metrics,states,commands = parsed((ROOT/row["log"]).read_text())
        assert all(int(row[key]) == value for key,value in metrics.items())
        assert sum(n for _,n in states) == metrics["whole_cycles"]
        assert sum(metrics[key] for key in ("setup_cycles","packing_cycles","compute_cycles","post_cycles")) == metrics["whole_cycles"]
        assert digest(ROOT/row["trace"]) == row["trace_sha256"]
        assert sum(c[3] for c in commands) == metrics["busy_cycles"]
    print(f"PASS: audit of {len(rows)} measured runs, retained logs, traces and source identities")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", nargs="+", choices=gen.CASES, default=list(gen.CASES))
    parser.add_argument("--modes", nargs="+", choices=gen.MODES, default=list(gen.MODES))
    parser.add_argument("--latencies", type=int, nargs="+", choices=range(1,21),default=[1,5,20])
    parser.add_argument("--cache", type=int, choices=[0,1], default=1)
    parser.add_argument("--workers", type=int, choices=range(1,5),default=4)
    parser.add_argument("--output", type=Path,default=RESULTS)
    parser.add_argument("--audit", action="store_true")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.relative_to(ROOT)
    if not __debug__:
        raise RuntimeError("run without Python -O; proof assertions are required")
    if args.audit:
        audit(args.output)
        return
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    args.output.mkdir(parents=True,exist_ok=True)
    BUILD.mkdir(parents=True,exist_ok=True)
    manifest,generation_seconds = gen.generate()
    gen.generate(True)
    predictions = {}
    for case in args.cases:
        for mode in args.modes:
            record = manifest["records"][f"{case}_{mode}"]
            addresses,traffic = trace(case,mode,record)
            predictions[case,mode] = encoded(addresses,args.cache),traffic
    commands = []
    scaling.BUILD = BUILD
    directory,executable = scaling.compile_tb("opencorex_conv1_tb",
        ROOT/"tb/benchmarks/opencorex_conv1_tb.sv",args.cache,"rtl",commands)
    negative_receipts = []
    for flag,message in (("CODE_WRITE","unexpected RAM write"),("BAD_BIAS","biased intermediate mismatch")):
        record = manifest["records"]["small_mac"]
        command = arguments(executable,"small","mac",1,record)+[f"+{flag}"]
        commands.append(command)
        result = subprocess.run(command,cwd=ROOT,text=True,capture_output=True)
        log = directory/f"reject_{flag.lower()}.log"
        log.write_text(result.stdout+result.stderr)
        assert result.returncode != 0 and message in log.read_text(), (flag,log.read_text()[-2000:])
        negative_receipts.append(dict(fault=flag,message=message,log=str(log.relative_to(ROOT))))
    jobs = [(case,mode,latency) for case in args.cases for mode in args.modes for latency in args.latencies]

    def execute(job):
        case,mode,latency = job
        stem = f"{case}_{mode}_c{args.cache}_l{latency}"
        binary,log = directory/f"{stem}.fetch.bin",directory/f"{stem}.log"
        command = arguments(executable,case,mode,latency,manifest["records"][f"{case}_{mode}"])
        command.append(f"+TRACE={binary}")
        output = run(command,log)
        metrics,states,command_rows = parsed(output)
        expected,traffic = predictions[case,mode]
        assert binary.read_bytes() == expected, ("exact fetch/cache replay",stem)
        for key in ("fetches","input_reads","patch_reads","weight_reads","bias_reads","post_reads",
                    "literal_reads","signature_reads","patch_writes","raw_writes","final_writes",
                    "biased_checks","cpu_dot_muls","cpu_dot_macs","packing_muls","pim_macs",
                    "mmio_writes","mmio_reads","commands","phase_writes","completion_writes"):
            assert metrics[key] == traffic[key], (stem,key,metrics[key],traffic[key])
        assert [s for s,_ in states] == list(range(17))
        assert sum(n for _,n in states) == metrics["whole_cycles"]
        assert dict(states)[16] == metrics["cpu_dot_macs"]
        assert sum(metrics[key] for key in ("setup_cycles","packing_cycles","compute_cycles","post_cycles")) == metrics["whole_cycles"]
        assert sum(c[3] for c in command_rows) == metrics["busy_cycles"]
        data_reads = sum(metrics[key] for key in ("input_reads","patch_reads","weight_reads",
                            "bias_reads","post_reads","literal_reads","signature_reads"))
        assert metrics["ram_reads"] == data_reads + (metrics["refill_reads"] if args.cache else metrics["fetches"])
        assert metrics["ram_writes"] == 3104
        row = dict(case=case,mode=mode,read_latency=latency,cache_enabled=args.cache,**metrics,
                   outputs_checked=gen.OUTPUTS,trace_sha256=digest(binary),
                   log=str(log.relative_to(ROOT)),trace=str(binary.relative_to(ROOT)))
        print("MEASURED",case,mode,f"L={latency}",metrics["whole_cycles"],"cycles",flush=True)
        return row,states,command_rows,command

    rows,state_rows,busy_rows = [],[],[]
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for row,states,busy,command in pool.map(execute,jobs):
            rows.append(row); commands.append(command)
            identity = {k:row[k] for k in ("case","mode","read_latency","cache_enabled")}
            state_rows.extend(dict(**identity,state=s,cycles=n) for s,n in states)
            busy_rows.extend(dict(**identity,position=p,start_cycle=start,final_write_cycle=end,busy_cycles=n)
                             for p,start,end,n in busy)
            (args.output/"partial.json").write_text(json.dumps(rows,indent=2)+"\n")
    rows.sort(key=lambda r:(r["case"],r["read_latency"],gen.MODES.index(r["mode"])))
    # The common packer executes at identical PCs with a cold cache in every variant.
    for case in args.cases:
        for latency in args.latencies:
            selected = [r for r in rows if r["case"]==case and r["read_latency"]==latency]
            assert len({r["packing_cycles"] for r in selected}) == 1
            for row in selected:
                if row["mode"] == "mac" and "tiled" in args.modes:
                    tiled = next(r for r in selected if r["mode"]=="tiled")
                    assert tiled["fetches"]-row["fetches"] == 34560
                    assert tiled["patch_reads"] == row["patch_reads"]
                    assert tiled["weight_reads"] == row["weight_reads"]
    (args.output/"programs.csv").write_text(csv_text(rows,list(rows[0])))
    (args.output/"states.csv").write_text(csv_text(state_rows,list(state_rows[0])))
    busy_fields = ["case","mode","read_latency","cache_enabled","position","start_cycle","final_write_cycle","busy_cycles"]
    (args.output/"commands.csv").write_text(csv_text(busy_rows,busy_fields))
    proof = {key:value for key,value in manifest.items() if key != "records"}
    proof.update(rtl_runs=len(rows),rtl_stage_words_checked=len(rows)*gen.OUTPUTS*3,
                 rtl_packed_words_checked=len(rows)*540,
                 negative_checks=negative_receipts,images=manifest["records"],
                 generator_and_reference_wall_seconds=generation_seconds,
                 immutable_operand_bytes=240+6912+256)
    (args.output/"proof.json").write_text(json.dumps(proof,indent=2)+"\n")
    paths = sorted((ROOT/"rtl").glob("*/*.sv")) + [
        ROOT/path for path in ("scripts/conv1_reference.py","scripts/generate_conv1.py",
        "scripts/conv1_trace.py","scripts/run_conv1_study.py","scripts/generate_matvec_1x16_16x32.py",
        "scripts/run_scaling_study.py","scripts/run_cache_study.py","scripts/gemm_large_trace.py",
        "tb/benchmarks/opencorex_conv1_tb.sv","tb/memory/latency_memory_responder.sv")]
    artifact_paths = [p for p in args.output.iterdir() if p.name in
                      ("programs.csv","states.csv","commands.csv","proof.json")]
    artifact_paths += [ROOT/r["log"] for r in rows]+[ROOT/r["trace"] for r in rows]
    artifact_paths += [ROOT/r["log"] for r in negative_receipts]
    artifact_paths += list(gen.IMAGES.glob("*"))
    provenance = dict(
        base_commit=subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
        python=platform.python_version(),
        verilator=subprocess.check_output(["verilator","--version"],text=True).strip(),
        compiler=subprocess.check_output(["c++","--version"],text=True).splitlines()[0],
        arguments={**vars(args),"output":str(args.output)},commands=commands,
        source_sha256={str(p.relative_to(ROOT)):digest(p) for p in paths},
        artifact_sha256={str(p.relative_to(ROOT)):digest(p) for p in artifact_paths})
    (args.output/"provenance.json").write_text(json.dumps(provenance,indent=2)+"\n")
    (args.output/"partial.json").unlink()
    print(f"PASS: {len(rows)} RTL runs, all raw/biased/final words, exact fetch replay, "
          "traffic/phase/state accounting and two rejected faults",flush=True)


if __name__ == "__main__":
    main()
