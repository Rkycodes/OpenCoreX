"""Measure weight-buffered conv1 separately; preserve and verify A-D evidence."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import csv
import hashlib
import json
from pathlib import Path
import platform
import resource
import subprocess

import generate_conv1_weight_reuse as gen
from conv1_weight_reuse_trace import trace
import run_conv1_study as original
import run_scaling_study as scaling
from run_cache_study import csv_text,run

ROOT,BUILD = gen.ROOT,gen.BUILD
RESULTS = ROOT/"docs/evaluation/conv1-weight-reuse-results"
BASELINE = ROOT/"docs/evaluation/conv1-results"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def baseline_identity():
    provenance = json.loads((BASELINE/"provenance.json").read_text())
    for path,expected in provenance["source_sha256"].items():
        assert digest(ROOT/path)==expected,("A-D source changed",path)
    for name in ("programs.csv","states.csv","commands.csv","proof.json"):
        path=BASELINE/name
        assert digest(path)==provenance["artifact_sha256"][str(path.relative_to(ROOT))]
    return provenance


def parsed(output):
    metrics,states,commands = {},[],[]
    for line in output.splitlines():
        fields=line.split(",")
        if fields[0]=="METRIC":
            assert fields[1] not in metrics
            metrics[fields[1]]=int(fields[2])
        elif fields[0]=="STATE": states.append(tuple(map(int,fields[1:])))
        elif fields[0]=="COMMAND": commands.append(tuple(map(int,fields[1:])))
    assert "PASS: opencorex_conv1_weight_reuse_tb" in output
    return metrics,states,commands


def arguments(executable,case,latency,record):
    return [str(executable),"+MODE=5",f"+DELAY={latency}",
        f"+IMAGE={ROOT/record['image']}",f"+BIAS_PC={record['bias_pc']:x}"]+[
        f"+{flag}={gen.IMAGES/f'{case}_{name}.hex'}" for flag,name in
        (("RAW","raw"),("BIASED","biased"),("FINAL","final"),("PATCHES","patches"))]


def audit(directory):
    baseline_identity()
    gen.generate(True)
    receipt=json.loads((directory/"provenance.json").read_text())
    for group in ("source_sha256","artifact_sha256"):
        for path,expected in receipt[group].items():
            assert digest(ROOT/path)==expected,(group,path)
    for row in csv.DictReader((directory/"programs.csv").open()):
        metrics,states,commands=parsed((ROOT/row["log"]).read_text())
        assert all(int(row[k])==v for k,v in metrics.items())
        assert sum(v for _,v in states)==metrics["whole_cycles"]
        assert sum(metrics[k] for k in ("setup_cycles","packing_cycles","compute_cycles","post_cycles"))==metrics["whole_cycles"]
        assert sum(c[3] for c in commands)==metrics["busy_cycles"]
        assert digest(ROOT/row["trace"])==row["trace_sha256"]
    print("PASS: weight-reuse measurements, source/log/trace identities and unchanged A-D evidence")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases",nargs="+",choices=gen.CASES,default=list(gen.CASES))
    parser.add_argument("--latencies",type=int,nargs="+",choices=range(1,21),default=[1,5,20])
    parser.add_argument("--workers",type=int,choices=range(1,5),default=3)
    parser.add_argument("--output",type=Path,default=RESULTS)
    parser.add_argument("--audit",action="store_true")
    args=parser.parse_args()
    args.output=args.output.resolve(); args.output.relative_to(ROOT)
    if not __debug__: raise RuntimeError("proof assertions require Python without -O")
    if args.audit:
        audit(args.output)
        return
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    baseline=baseline_identity()
    manifest,generation_seconds=gen.generate()
    gen.generate(True)
    predictions={case:trace(case,manifest["records"][case]) for case in args.cases}
    encoded={case:original.encoded(addresses,1) for case,(addresses,_) in predictions.items()}
    args.output.mkdir(parents=True,exist_ok=True)
    commands=[]
    scaling.BUILD=BUILD
    directory,executable=scaling.compile_tb("opencorex_conv1_weight_reuse_tb",
        ROOT/"tb/benchmarks/opencorex_conv1_weight_reuse_tb.sv",1,"rtl",commands)
    negatives=[]
    for flag,message in (("CODE_WRITE","unexpected RAM write"),("BAD_BIAS","biased intermediate mismatch"),
                         ("BAD_GATHER","postprocessing raw read")):
        command=arguments(executable,"small",1,manifest["records"]["small"])+[f"+{flag}"]
        commands.append(command)
        result=subprocess.run(command,cwd=ROOT,text=True,capture_output=True)
        path=directory/f"reject_{flag.lower()}.log"
        path.write_text(result.stdout+result.stderr)
        assert result.returncode and message in path.read_text(),(flag,path.read_text()[-3000:])
        negatives.append(dict(fault=flag,message=message,log=str(path.relative_to(ROOT))))
    baseline_rows=list(csv.DictReader((BASELINE/"programs.csv").open()))

    def execute(job):
        case,latency=job
        stem=f"{case}_weights_c1_l{latency}"
        binary,log=directory/f"{stem}.fetch.bin",directory/f"{stem}.log"
        command=arguments(executable,case,latency,manifest["records"][case])+[f"+TRACE={binary}"]
        metrics,states,busy=parsed(run(command,log))
        assert binary.read_bytes()==encoded[case],("exact fetch/cache replay",stem)
        traffic=predictions[case][1]
        for key in ("fetches","input_reads","patch_reads","weight_reads","bias_reads","post_reads",
                    "literal_reads","signature_reads","patch_writes","raw_writes","final_writes",
                    "biased_checks","cpu_dot_muls","cpu_dot_macs","packing_muls","pim_macs",
                    "mmio_writes","mmio_reads","commands","phase_writes","completion_writes"):
            assert metrics[key]==traffic[key],(stem,key,metrics[key],traffic[key])
        assert [s for s,_ in states]==list(range(17)) and sum(n for _,n in states)==metrics["whole_cycles"]
        assert dict(states)[16]==0
        assert sum(metrics[k] for k in ("setup_cycles","packing_cycles","compute_cycles","post_cycles"))==metrics["whole_cycles"]
        assert sum(c[3] for c in busy)==metrics["busy_cycles"]
        data_reads=sum(metrics[k] for k in ("input_reads","patch_reads","weight_reads",
            "bias_reads","post_reads","literal_reads","signature_reads"))
        assert metrics["ram_reads"]==data_reads+metrics["refill_reads"]
        assert metrics["ram_writes"]==3104
        d=next(r for r in baseline_rows if r["case"]==case and r["mode"]=="offload" and
               int(r["read_latency"])==latency and r["cache_enabled"]=="1")
        assert metrics["packing_cycles"]==int(d["packing_cycles"])
        row=dict(case=case,mode="weights",read_latency=latency,cache_enabled=1,**metrics,
            outputs_checked=1280,trace_sha256=digest(binary),
            log=str(log.relative_to(ROOT)),trace=str(binary.relative_to(ROOT)))
        print("MEASURED",case,f"L={latency}",metrics["whole_cycles"],
              "cycles; saved D:",d["whole_cycles"],flush=True)
        return row,states,busy,command

    rows,state_rows,command_rows=[],[],[]
    jobs=[(case,latency) for case in args.cases for latency in args.latencies]
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for row,states,busy,command in pool.map(execute,jobs):
            rows.append(row); commands.append(command)
            identity={k:row[k] for k in ("case","mode","read_latency","cache_enabled")}
            state_rows.extend(dict(**identity,state=s,cycles=n) for s,n in states)
            command_rows.extend(dict(**identity,filter_index=f,start_cycle=start,
                final_write_cycle=end,busy_cycles=n) for f,start,end,n in busy)
            (args.output/"partial.json").write_text(json.dumps(rows,indent=2)+"\n")
    rows.sort(key=lambda r:(r["case"],r["read_latency"]))
    (args.output/"programs.csv").write_text(csv_text(rows,list(rows[0])))
    (args.output/"states.csv").write_text(csv_text(state_rows,list(state_rows[0])))
    (args.output/"commands.csv").write_text(csv_text(command_rows,list(command_rows[0])))
    proof=dict(rtl_runs=len(rows),rtl_stage_words_checked=len(rows)*1280*3,
        rtl_gathered_raw_reads_checked=len(rows)*1280,rtl_packed_words_checked=len(rows)*540,
        negative_checks=negatives,images=manifest["records"],baseline_image_identity=manifest["baseline_image_identity"],
        generator_and_reference_wall_seconds=generation_seconds,
        extra_raw_output_bytes=5120,software_reordering="fused with bias/ReLU; no extra RAM copy pass")
    (args.output/"proof.json").write_text(json.dumps(proof,indent=2)+"\n")
    new_sources=[ROOT/p for p in ("scripts/generate_conv1_weight_reuse.py",
        "scripts/conv1_weight_reuse_trace.py","scripts/run_conv1_weight_reuse.py",
        "tb/benchmarks/opencorex_conv1_weight_reuse_tb.sv")]
    artifacts=[args.output/name for name in ("programs.csv","states.csv","commands.csv","proof.json")]
    artifacts += [ROOT/r[k] for r in rows for k in ("log","trace")]
    artifacts += [ROOT/r["log"] for r in negatives]+list(gen.IMAGES.glob("*"))
    artifacts += [BASELINE/name for name in ("programs.csv","proof.json","provenance.json")]
    provenance=dict(base_commit=subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
        python=platform.python_version(),
        verilator=subprocess.check_output(["verilator","--version"],text=True).strip(),
        compiler=subprocess.check_output(["c++","--version"],text=True).splitlines()[0],
        arguments={**vars(args),"output":str(args.output)},commands=commands,
        source_sha256={**baseline["source_sha256"],**{str(p.relative_to(ROOT)):digest(p) for p in new_sources}},
        artifact_sha256={str(p.relative_to(ROOT)):digest(p) for p in artifacts})
    (args.output/"provenance.json").write_text(json.dumps(provenance,indent=2)+"\n")
    (args.output/"partial.json").unlink()
    print(f"PASS: {len(rows)} weight-buffered RTL runs, exact replay, complete output/traffic checks and three rejected faults")


if __name__=="__main__":
    main()
