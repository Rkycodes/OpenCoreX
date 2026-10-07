"""Controlled output-count scaling; historical cache study remains untouched."""
import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import resource
import subprocess
from run_cache_study import CACHE_FIELDS, STATES, csv_text, run
from run_memory_latency_sweep import PROGRAM_FIELDS

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "obj_dir/verification/output_scaling"
RESULTS = ROOT / "docs/evaluation/scaling-results"
LATENCIES = (1, 2, 5, 10, 20)
RAM_WORDS = 262144

def generated_top():
    source = (ROOT / "rtl/system/opencorex_pim_subsystem.sv").read_text()
    changes = {
        "module opencorex_pim_subsystem #(": "module cache_study_subsystem #(",
        "    input logic reset,": "    input logic reset,\n    input int read_delay, fetch_delay,",
        "    synchronous_memory_adapter adapter_inst (":
            "    latency_memory_responder adapter_inst (\n        .read_delay, .fetch_delay, .is_fetch(1'b0),",
    }
    for old,new in changes.items():
        assert source.count(old)==1, old
        source=source.replace(old,new)
    path=BUILD/"cache_study_subsystem.sv"
    path.write_text(source)
    return path

def compile_tb(top, tb, enabled, label, commands):
    directory=BUILD/f"{label}_{enabled}"
    directory.mkdir(parents=True,exist_ok=True)
    package=ROOT/"rtl/pim/pim_pkg.sv"
    rtl=[package]+[p for p in sorted((ROOT/"rtl").glob("*/*.sv")) if p!=package]
    command=["verilator","--binary","--timing","-Wall","-j","4",
             "--top-module",top,f"-GCACHE_ENABLE=1'b{enabled}","--Mdir",str(directory)]
    command += [str(p) for p in rtl]+[str(generated_top()),
        str(ROOT/"tb/memory/latency_memory_responder.sv"),str(tb)]
    commands.append(command)
    run(command,directory/"build.log")
    return directory,directory/f"V{top}"

def parse(output):
    result={}
    fetches=[]
    states=[]
    for line in output.splitlines():
        parts=line.split(",")
        if parts[0] in ("PROGRAM","CACHE","COMMAND","EXTRA"):
            assert parts[0] not in result
            result[parts[0]]=[int(v) for v in parts[1:]]
        elif parts[0]=="FETCH":
            fetches.append(tuple(map(int,parts[1:])))
        elif parts[0]=="STATE":
            states.append(tuple(map(int,parts[1:])))
    return result,fetches,states

def compatibility(commands):
    source=(ROOT/"tb/benchmarks/opencorex_cache_study_tb.sv").read_text()
    changes={
        "memory #(.WORDS(1024))":f"memory #(.WORDS({RAM_WORDS}))",
        "#(.ICACHE_ENABLE(CACHE_ENABLE))":f"#(.ICACHE_ENABLE(CACHE_ENABLE), .RAM_WORDS({RAM_WORDS}))",
    }
    for old,new in changes.items():
        assert source.count(old)==1,old
        source=source.replace(old,new)
    tb=BUILD/"opencorex_cache_study_tb.sv"
    tb.write_text(source)
    original=list(csv.DictReader((ROOT/"docs/evaluation/cache-results/programs.csv").open()))
    original_states=list(csv.DictReader((ROOT/"docs/evaluation/cache-results/states.csv").open()))
    rows=[]
    for enabled in (0,1):
        directory,exe=compile_tb("opencorex_cache_study_tb",tb,enabled,"capacity",commands)
        for delay in LATENCIES:
            for mode,number in (("resident",2),("offload",3)):
                command=[str(exe),f"+MODE={number}",f"+DELAY={delay}"]
                commands.append(command)
                output=run(command,directory/f"{mode}_{delay}.log")
                assert "PASS: opencorex_cache_study_tb" in output
                parsed,fetches,states=parse(output)
                row=dict(zip(PROGRAM_FIELDS,parsed["PROGRAM"]))
                row.update(zip(CACHE_FIELDS,parsed["CACHE"]))
                row.update(mode=mode,cache_enabled=enabled)
                expected=next(r for r in original if r["mode"]==mode and
                    int(r["cache_enabled"])==enabled and int(r["read_delay"])==delay)
                for key in expected:
                    assert str(row[key])==expected[key],(key,row,expected)
                for state,count in states:
                    expected_state=next(r for r in original_states if r["mode"]==mode and
                        int(r["cache_enabled"])==enabled and int(r["read_delay"])==delay and
                        r["state"]==STATES[state])
                    assert count==int(expected_state["cycles"])
                from cache_trace import trace, replay
                predicted=replay(trace(mode))
                assert fetches==[(a,int(m) if enabled else 0) for a,m in predicted]
                rows.append(row)
                print("CAPACITY",mode,enabled,delay,row["whole_cycles"],flush=True)
    return rows


def limit_checks(commands):
    directory=BUILD/"limits"
    directory.mkdir(exist_ok=True)
    package=ROOT/"rtl/pim/pim_pkg.sv"
    rtl=[package]+[p for p in sorted((ROOT/"rtl").glob("*/*.sv")) if p!=package]
    command=["verilator","--binary","--timing","-Wall","-j","4",
        "--top-module","opencorex_scaling_limits_tb","--Mdir",str(directory)]
    command += [str(p) for p in rtl]+[str(ROOT/"tb/benchmarks/opencorex_scaling_limits_tb.sv")]
    commands.append(command)
    run(command,directory/"build.log")
    command=[str(directory/"Vopencorex_scaling_limits_tb")]
    commands.append(command)
    output=run(command,directory/"run.log")
    assert "PASS: opencorex_scaling_limits_tb" in output
    rows=[]
    for line in output.splitlines():
        if line.startswith("LIMIT,"):
            rows.append(dict(zip(("output_count","error_code","operand_reads","output_writes"),
                                 map(int,line.split(",")[1:]))))
    assert len(rows)==3
    return rows

EXTRA_FIELDS=("start_edge","final_output_edge","execution_cycles","setup_cycles","completion_cycles","buffer_reads","ram_reads","ram_writes","other_ram_writes")

def primary(commands):
    from scaling_trace import trace,replay
    rows,state_rows,command_rows=[],[],[]
    traces={(mode,n):replay(trace(mode,n)) for n in (32,64,128) for mode in ("resident","offload")}
    for enabled in (0,1):
        directory,exe=compile_tb("opencorex_scaling_tb",ROOT/"tb/benchmarks/opencorex_scaling_tb.sv",
                                 enabled,"primary",commands)
        # Both requester paths must reject code writes, including accelerator writes.
        negatives=[
            ("cpu-code",["+MODE=2","+N=32","+DELAY=5","+CODE_WRITE"],"immutable executable code write"),
            ("pim-code",["+MODE=3","+N=32","+DELAY=5","+PIM_CODE_WRITE"],"immutable executable code write"),
        ]
        for label,arguments,message in negatives:
            command=[str(exe)]+arguments
            commands.append(command)
            result=subprocess.run(command,cwd=ROOT,text=True,capture_output=True)
            (directory/f"{label}.log").write_text(result.stdout+result.stderr)
            assert result.returncode and message in result.stdout
        for n in (32,64,128):
            for delay in LATENCIES:
                for mode,number in (("resident",2),("offload",3)):
                    command=[str(exe),f"+MODE={number}",f"+N={n}",f"+DELAY={delay}"]
                    commands.append(command)
                    output=run(command,directory/f"{mode}_{n}_{delay}.log")
                    assert f"PASS: opencorex_scaling_tb N={n}" in output
                    parsed,observed,states=parse(output)
                    expected=traces[mode,n]
                    assert observed==[(a,int(m) if enabled else 0) for a,m in expected]
                    assert len(parsed["PROGRAM"])==len(PROGRAM_FIELDS)
                    assert len(parsed["CACHE"])==len(CACHE_FIELDS)
                    row=dict(zip(PROGRAM_FIELDS,parsed["PROGRAM"]))
                    row.update(zip(CACHE_FIELDS,parsed["CACHE"]))
                    row.update(mode=mode,output_count=n,cache_enabled=enabled)
                    assert row["vector_reads"]==16 and row["matrix_reads"]==16*n
                    assert row["output_writes"]==n and row["completion_writes"]==1
                    assert row["fetches"]==len(expected)
                    assert row["cpu_muls"]==row["cpu_accumulating_adds"]==(16*n if mode=="resident" else 0)
                    assert row["offload_macs"]==(16*n if mode=="offload" else 0)
                    assert row["cpu_other_reads"]==(5 if mode=="resident" else 6)
                    assert row["mmio_writes"]==(7 if mode=="offload" else 0)
                    assert row["mmio_reads"]==(1 if mode=="offload" else 0)
                    assert row["pim_busy_cycles"]==row["busy_blocked"]
                    assert row["cpu_fetch_response_wait"]==(
                        row["hits"]+row["misses"]*(5+4*delay) if enabled else row["fetches"]*(delay-1))
                    if enabled:
                        assert row["hits"]+row["misses"]==row["fetches"]
                        assert row["misses"]==sum(m for _,m in expected)
                        assert row["refill_reads"]==4*row["misses"]
                        bypass=next(r for r in rows if r["mode"]==mode and r["output_count"]==n and
                            r["read_delay"]==delay and r["cache_enabled"]==0)
                        assert row["whole_cycles"]-bypass["whole_cycles"]==(
                            row["hits"]*(2-delay)+row["misses"]*(6+3*delay))
                        assert row["fetch_wait"]==row["refill_reads"]*(delay-1)
                    else:
                        assert row["hits"]==row["misses"]==row["refill_reads"]==0
                        assert row["fetch_wait"]==row["fetches"]*(delay-1)
                    assert row["cpu_data_wait"]==(16+16*n+5 if mode=="resident" else 6)*(delay-1)
                    assert row["pim_wait"]==(16+16*n if mode=="offload" else 0)*(delay-1)
                    assert len(states)==16 and sum(count for _,count in states)==row["whole_cycles"]
                    state_rows += [dict(output_count=n,mode=mode,cache_enabled=enabled,
                        read_delay=delay,state=STATES[state],cycles=count) for state,count in states]
                    assert len(parsed["EXTRA"])==len(EXTRA_FIELDS)
                    extra=dict(zip(EXTRA_FIELDS,parsed["EXTRA"]))
                    assert extra["ram_reads"]==(row["refill_reads"] if enabled else row["fetches"])+16+16*n+row["cpu_other_reads"]
                    assert extra["ram_writes"]==n+1 and extra["other_ram_writes"]==0
                    row.update({key:extra[key] for key in ("ram_reads","ram_writes","other_ram_writes")})
                    if mode=="offload":
                        assert extra["execution_cycles"]==row["pim_busy_cycles"]
                        assert extra["setup_cycles"]+extra["execution_cycles"]+extra["completion_cycles"]==row["whole_cycles"]
                        assert extra["buffer_reads"]==16*n-16
                        command_rows.append(dict(output_count=n,cache_enabled=enabled,
                                                 read_delay=delay,**extra))
                    rows.append(row)
                    print("PRIMARY",n,mode,enabled,delay,row["whole_cycles"],flush=True)
    for row in rows:
        n,enabled,delay=row["output_count"],row["cache_enabled"],row["read_delay"]
        def cycles(mode,cache):
            return next(r["whole_cycles"] for r in rows if r["output_count"]==n and
                        r["mode"]==mode and r["cache_enabled"]==cache and r["read_delay"]==delay)
        cpu,off=cycles("resident",enabled),cycles("offload",enabled)
        row.update(cycles_per_output=f'{row["whole_cycles"]/n:.6f}',
            cycles_per_product=f'{row["whole_cycles"]/(16*n):.6f}',
            cpu_offload_ratio=f"{cpu/off:.6f}",cycle_gap=cpu-off,
            gap_reduction=(cycles("resident",0)-cycles("offload",0))-
                          (cycles("resident",1)-cycles("offload",1)))
    # Check the measured affine size relationship, without extrapolating beyond tested sizes.
    for mode in ("resident","offload"):
        for enabled in (0,1):
            for delay in LATENCIES:
                samples=[next(r["whole_cycles"] for r in rows if r["output_count"]==n and
                    r["mode"]==mode and r["cache_enabled"]==enabled and r["read_delay"]==delay)
                    for n in (32,64,128)]
                assert samples[2]-samples[1]==2*(samples[1]-samples[0])
    # Uniform latency adds only accepted-read wait clocks relative to L=1.
    for row in rows:
        first=next(r for r in rows if r["output_count"]==row["output_count"] and
            r["mode"]==row["mode"] and r["cache_enabled"]==row["cache_enabled"] and r["read_delay"]==1)
        assert row["whole_cycles"]-first["whole_cycles"]==row["fetch_wait"]+row["cpu_data_wait"]+row["pim_wait"]
    return rows,state_rows,command_rows,traces

DERIVED_FIELDS=("cycles_per_output","cycles_per_product","cpu_offload_ratio","cycle_gap","gap_reduction","ram_reads","ram_writes","other_ram_writes")

def report(rows):
    lines=["# Controlled output-count scaling — October 7, 2026","",
        "Question: how does the remaining digital-offload advantage change with output count,",
        "holding vector residency, cache design, arithmetic and memory service fixed?","",
        "## Contract and controls","",
        "N={32,64,128}; each workload is 1x16 by 16xN. Resident scalar CPU versus one",
        "cold digital offload, cache bypass/enabled, uniform L={1,2,5,10,20}: 60 runs.",
        "All runs use RAM_WORDS=262144 (1 MiB physical RAM), MAX_OUTPUTS=128,",
        "BUFFER_WORDS=16, MAC_LANES=1. Router, validator and physical RAM capacities agree.",
        "Production RTL/defaults are unchanged. The cache retains 512 bytes, direct mapping,",
        "16-byte lines, two-cycle hits and four serial backing reads per miss.",
        "One single-port backing memory, one outstanding read, unchanged write/arbitration",
        "timing and blocking execution. Data/MMIO bypass the cache; busy gating precedes it.",
        "Reset cache/vector validity per run. No CPU MAC, tiling, precision change or extra lanes.","",
        "| Allocation | Byte range |",
        "|---|---|",
        "| Boot/refill line | 0x00000-0x0000F |",
        "| Vector | 0x00100-0x0013F |",
        "| Constants/control | 0x00200-0x0023F; signature 0x220, completion 0x224 |",
        "| Kernel allocation | 0x00A00-0x00DFF |",
        "| Matrix allocation | 0x01000-0x0FFFF |",
        "| Output allocation | 0x10000-0x10FFF |",
        "| Unallocated RAM | 0x11000-0xFFFFF |",
        "| Offload MMIO | 0x40000000-0x40000FFF |","",
        "Hex markers are word addresses; generators centralize/assert conversion.",
        "Pointers/counts load from the low constant table; no ISA additions.",
        "Within each method, instruction encodings, placement and register allocation",
        "are identical across sizes. CPU vector registers remain x15-x30.",
        "Each output uses the same 54-instruction scalar loop with MUL then ADD.",
        "The vector is identical and matrices are nested. Columns 0-31 preserve the",
        "historical formula; later columns extend it with a deterministic signed offset",
        "to avoid simply repeating its period-37 pattern. References are calculated",
        "from the logical matrix independently of column-major serialization.",
        "Relocated N=32 is a new baseline; historical images/results remain intact.","",
        "Boundary: reset release through accepted completion-signature store inclusive.",
        "Setup, launch, waiting, status and completion included; host placement and",
        "downstream consumption excluded. START-to-final-output is secondary.","",
        "## Measured whole-program results","",
        "| N | L | CPU bypass | Offload bypass | CPU cache | Offload cache | Bypass ratio | Cache ratio | Bypass gap | Cache gap | Gap reduction |",
        "|---|---|---|---|---|---|---|---|---|---|---|"]
    def get(n,delay,mode,enabled):
        return next(r for r in rows if r["output_count"]==n and r["read_delay"]==delay and
                    r["mode"]==mode and r["cache_enabled"]==enabled)
    for n in (32,64,128):
        for delay in LATENCIES:
            cb,ob,cc,oc=[get(n,delay,m,c) for m,c in
                         (("resident",0),("offload",0),("resident",1),("offload",1))]
            lines.append(f'| {n} | {delay} | {cb["whole_cycles"]} | {ob["whole_cycles"]} | {cc["whole_cycles"]} | {oc["whole_cycles"]} | {cb["cpu_offload_ratio"]} | {cc["cpu_offload_ratio"]} | {cb["cycle_gap"]} | {cc["cycle_gap"]} | {cc["gap_reduction"]} |')
    lines += ["","## Findings and accounting","",
        "All 60 configurations verify every output, unchanged operands, exactly 16",
        "vector reads, 16N matrix reads, N output writes and 16N arithmetic operations",
        "(CPU MUL/accumulating-ADD pairs or offload MACs). Independent execution/cache",
        "replay matches every logical fetch and miss. Writes to executable allocations",
        "are rejected. Capability/limit checks advertise 128; zero and 129 reject with",
        "INVALID_OUTPUT_COUNT before operand traffic; valid 128 completes correctly.","",
        "Dynamic CPU fetches are 54N+23; offload fetches stay at 23.",
        "CPU misses stay at 20 and offload misses at 7: 80 and 28 refill words.",
        "There are no later resident-loop misses. More output columns increase loop",
        "iterations and operand traffic, not the instruction working set.","",
        "Exact equality holds for all enabled runs:",
        "T_cache-T_bypass = hits*(2-L)+misses*(6+3L).",
        "Uniform-latency growth from L=1 also exactly equals categorized backing-read waits.",
        "The CPU still uses separate scalar MUL/ADD, operand loads, addressing and loop",
        "control; offload still streams every matrix word. The residual includes the",
        "chosen lookup/refill policy, so it is not an isolated fused-MAC benefit.","",
        "| N | Cached CPU cycles/output at L=20 | Cached offload cycles/output at L=20 | Cached ratio |",
        "|---|---|---|---|"]
    for n in (32,64,128):
        cpu,off=get(n,20,"resident",1),get(n,20,"offload",1)
        lines.append(f'| {n} | {cpu["cycles_per_output"]} | {off["cycles_per_output"]} | {cpu["cpu_offload_ratio"]} |')
    lines += ["",
        "Cold refill and CPU/offload setup costs amortize as N grows. Total cycles",
        "are exactly affine across the three tested sizes at every fixed policy/latency.",
        "With caching at L=20, CPU cycles=660N+2259 and offload cycles=433N+1171.",
        "These identities describe the measured sizes, not measurements at other N.",
        "The cached ratio decreases from 1.556 to 1.533 at L=20, while the absolute",
        "gap grows from 8352 to 30144 cycles. At L=1 the ratio instead increases",
        "from 2.698 to 2.744: size trends depend on the memory-service assumption.",
        "Caching remains slower than bypass at L=1 and L=2 for all three sizes;",
        "it helps the resident CPU at L=5,10,20. Offload refill overhead remains visible.","",
        "## Reproduction and evidence","",
        "- Run `make scaling-study` to regenerate and validate all images/results.",
        "- Run `make scaling-check` to rerun and compare against tracked evidence.",
        "- Run `python3 scripts/run_scaling_study.py --compat-only` for capacity-only reproduction.",
        "- Run `make verify` for historical lint, protocol/reset/conflict/busy, and benchmark regression.",
        "- [Primary counters and derived metrics](programs.csv), [disjoint states](states.csv),",
        "  [offload boundaries](commands.csv), [capacity-only compatibility](capacity-compatibility.csv),",
        "  [limit checks](limits.csv), [source hashes/exact commands](provenance.json),",
        "  and [completed verification evidence](verification.json).",
        "- Independent accepted-fetch predictions are in `resident-N-trace.csv` and `offload-N-trace.csv`.",
        "- Build/run logs are under `obj_dir/verification/output_scaling`.",
        "  Source hashes identify measured code; the base commit records ancestry, not a substitute for hashes.","",
        "CPU-state cycles form a disjoint partition summing to whole-program cycles.",
        "Busy, request backpressure, CPU response waits and backing wait counters overlap",
        "that partition and must not be added to it. Physical RAM size is fixed across all sizes.","",
        "This establishes output-count scaling with vector length 16, not behavior when",
        "vectors exceed registers/buffer. No energy, area, calibrated DRAM, physical",
        "clock-time or general CPU/PIM superiority claims follow.","",
        "Next separate experiment: define a CPU MAC instruction/control with explicit",
        "accumulator, low-product/modulo semantics, encoding and multicycle latency.",
        "Hold these images' layout, vector residency, cache and memory service fixed;",
        "compare matched scalar versus MAC kernels and report both instruction counts",
        "and total cycles. Do not combine that intervention with another architecture change.",""]
    return "\n".join(lines)

def main():
    from generate_scaling import generate
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compat-only",action="store_true")
    parser.add_argument("--check",action="store_true")
    args=parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    BUILD.mkdir(parents=True,exist_ok=True)
    RESULTS.mkdir(parents=True,exist_ok=True)
    commands=[]
    compatibility_rows=compatibility(commands)
    files={"capacity-compatibility.csv":csv_text(compatibility_rows,("cache_enabled",)+PROGRAM_FIELDS+CACHE_FIELDS)}
    if not args.compat_only:
        generate(check=args.check)
        limit_rows=limit_checks(commands)
        rows,states,command_rows,traces=primary(commands)
        files.update({
            "programs.csv":csv_text(rows,("output_count","cache_enabled")+PROGRAM_FIELDS+CACHE_FIELDS+DERIVED_FIELDS),
            "states.csv":csv_text(states,("output_count","mode","cache_enabled","read_delay","state","cycles")),
            "commands.csv":csv_text(command_rows,("output_count","cache_enabled","read_delay")+EXTRA_FIELDS),
            "limits.csv":csv_text(limit_rows,("output_count","error_code","operand_reads","output_writes")),
            "README.md":report(rows)})
        for (mode,n),events in traces.items():
            files[f"{mode}-{n}-trace.csv"]=csv_text(
                [dict(fetch=i,address=f"0x{a:08x}",miss=int(m)) for i,(a,m) in enumerate(events)],
                ("fetch","address","miss"))
        source_paths=sorted(list((ROOT/"rtl").glob("*/*.sv"))+
            [ROOT/f"scripts/{name}.py" for name in ("generate_scaling","scaling_trace","run_scaling_study",
             "run_cache_study","run_memory_latency_sweep","cache_trace","generate_matvec_1x16_16x32")]+
            [ROOT/"tb/benchmarks/opencorex_scaling_tb.sv",ROOT/"tb/benchmarks/opencorex_scaling_limits_tb.sv",
             ROOT/"tb/benchmarks/opencorex_cache_study_tb.sv",ROOT/"tb/memory/latency_memory_responder.sv"]+
            list((ROOT/"programs/scaling/hex").glob("*.hex"))+list((ROOT/"programs/hex").glob("*.hex")))
        provenance=dict(base_commit="7fb74d05590936d15dd8e1cc55dc638dd2b27929",
            verilator=subprocess.check_output(["verilator","--version"],text=True).strip(),
            source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths},
            commands=commands)
        if args.check:
            saved=json.loads((RESULTS/"provenance.json").read_text())
            assert saved["source_sha256"]==provenance["source_sha256"],"measured source changed"
        else:
            (RESULTS/"provenance.json").write_text(json.dumps(provenance,indent=2)+"\n")
    for name,text in files.items():
        path=RESULTS/name
        if args.check: assert path.read_text()==text,f"evidence differs: {path}"
        else: path.write_text(text)
    (BUILD/"commands.json").write_text(json.dumps(commands,indent=2)+"\n")
    print("PASS: 20 capacity-only compatibility cases" if args.compat_only else
          "PASS: 60 primary cases, 20 compatibility cases, 3 limit checks, independent traces and exact accounting")

if __name__=="__main__":
    main()
