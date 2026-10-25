"""Measure CPU MAC fusion with the existing square GEMM topology and interpreter."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from array import array
import generate_gemm as small
import generate_gemm_large as large
import run_scaling_study as scaling
import run_gemm_large as large_runner
from run_cache_study import CACHE_FIELDS, csv_text, run
from run_memory_latency_sweep import PROGRAM_FIELDS
from run_gemm_large import EXTRA, encoded, compare_binary
from gemm_large_trace import trace

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "obj_dir/verification/mac_study"
RESULTS = ROOT / "docs/evaluation/mac-results"
MODES = ("streaming", "tiled", "mac", "offload")
NUMBERS = dict(streaming=1, tiled=2, offload=3, mac=4)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=int, nargs="+", default=[16,32,64,128], choices=[16,32,64,128])
    parser.add_argument("--latencies", type=int, nargs="+", default=[1,5,20], choices=range(1,21))
    parser.add_argument("--caches", type=int, nargs="+", default=[1], choices=[0,1])
    parser.add_argument("--workers", type=int, default=4, choices=range(1,5))
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True); RESULTS.mkdir(parents=True, exist_ok=True)
    # Existing A/B/D images must reproduce exactly; only new MAC images are written.
    small.generate(True); large.generate(True)
    small.generate(modes=("mac",)); large.generate(modes=("mac",))
    commands=[]; scaling.BUILD=BUILD; large_runner.BUILD=BUILD
    builds={c:scaling.compile_tb("opencorex_gemm_large_tb",
        ROOT/"tb/benchmarks/opencorex_gemm_large_tb.sv",c,"mac",commands) for c in args.caches}
    rows=[]
    for size in args.sizes:
        for mode in MODES:
            print("INTERPRET",size,mode,flush=True)
            addresses,traffic=trace(mode,size)
            assert traffic["cpu_macs"] == (size**3 if mode=="mac" else 0)
            predictions={c:encoded(addresses,bool(c)) for c in args.caches}
            def job(item):
                cache,delay=item
                directory,exe=builds[cache]
                stem=f"{mode}_{size}_c{cache}_l{delay}"
                binary=directory/f"{stem}.fetch.bin"
                command=[str(exe),f"+MODE={NUMBERS[mode]}",f"+N={size}",f"+DELAY={delay}",f"+TRACE_FILE={binary}"]
                output=run(command,directory/f"{stem}.log")
                assert f"PASS: opencorex_gemm_large_tb N={size}" in output
                parsed,_,states=scaling.parse(output)
                row=dict(zip(PROGRAM_FIELDS,parsed["PROGRAM"]))
                row.update(zip(CACHE_FIELDS,parsed["CACHE"])); row.update(zip(EXTRA,parsed["EXTRA"]))
                row.update(order=size,mode=mode,cache_enabled=cache,cpu_macs=traffic["cpu_macs"],
                           numerical_correct=1,trace_sha256=compare_binary(binary,predictions[cache]))
                for key in ("vector_reads","matrix_reads","cpu_muls","cpu_accumulating_adds","offload_macs",
                            "output_writes","completion_writes","cpu_other_reads","literal_reads","signature_reads","mmio_reads","mmio_writes"):
                    assert row[key]==traffic[key],(key,row,traffic)
                assert row["fetches"]==len(addresses)
                assert sum(count for _,count in states)==row["whole_cycles"]
                assert dict(states).get(16,0)==traffic["cpu_macs"]
                assert f'MAC,{traffic["cpu_macs"]}' in output
                assert row["ram_reads"]==(row["refill_reads"] if cache else row["fetches"])+row["vector_reads"]+row["matrix_reads"]+row["cpu_other_reads"]
                assert row["ram_writes"]==size*size+1
                assert row["fetch_wait"]==(row["refill_reads"] if cache else row["fetches"])*(delay-1)
                operands=row["vector_reads"]+row["matrix_reads"]
                assert row["cpu_data_wait"]==(row["cpu_other_reads"]+(operands if mode!="offload" else 0))*(delay-1)
                assert row["pim_wait"]==(operands if mode=="offload" else 0)*(delay-1)
                # All instructions fetched before completion execute; no speculation/prefetch.
                row["dynamic_instructions"]=row["fetches"]
                row["cycles_per_mac"]=f'{row["whole_cycles"]/size**3:.9f}'
                row["mac_accum_cycles"]=dict(states).get(16,0)
                print("MEASURED",size,mode,cache,delay,row["whole_cycles"],flush=True)
                return row,command
            jobs=[(c,l) for c in args.caches for l in args.latencies]
            with ThreadPoolExecutor(max_workers=args.workers) as pool:
                for row,command in pool.map(job,jobs):
                    rows.append(row); commands.append(command)
            # Preserve completed configurations if a later run fails.
            (RESULTS/"partial.json").write_text(json.dumps(rows,indent=2)+"\n")
    for row in rows:
        def pick(mode):
            return next(r for r in rows if r["order"]==row["order"] and r["cache_enabled"]==row["cache_enabled"]
                        and r["read_delay"]==row["read_delay"] and r["mode"]==mode)
        tiled,mac,off=pick("tiled"),pick("mac"),pick("offload")
        for key in ("vector_reads","matrix_reads","output_writes","completion_writes","cpu_other_reads","ram_writes","cpu_data_wait"):
            assert tiled[key]==mac[key],(key,tiled,mac)
        assert tiled["fetches"]-mac["fetches"]==row["order"]**3
        assert mac["cpu_macs"]==tiled["cpu_muls"]==tiled["cpu_accumulating_adds"]==row["order"]**3
        row["cpu_mac_speedup"]=f'{tiled["whole_cycles"]/mac["whole_cycles"]:.9f}'
        row["pim_speedup_vs_mac"]=f'{mac["whole_cycles"]/off["whole_cycles"]:.9f}'
        row["cycles_saved_vs_tiled"]=tiled["whole_cycles"]-mac["whole_cycles"]
        # In the cache-enabled experiment one fewer instruction saves six cycles,
        # minus one additional arithmetic state. Refill differences are measured.
        if row["cache_enabled"]:
            expected=5*row["order"]**3+(tiled["misses"]-mac["misses"])*(4+4*row["read_delay"])
        else:
            expected=(row["read_delay"]+3)*row["order"]**3
        assert row["cycles_saved_vs_tiled"]==expected,(row,expected)
        if row["mode"]!="mac":
            folder="gemm-results" if row["order"]<=32 else "gemm-large-results"
            with (ROOT/f"docs/evaluation/{folder}/programs.csv").open() as f:
                old=next(r for r in csv.DictReader(f) if int(r["order"])==row["order"] and r["mode"]==row["mode"]
                         and int(r["cache_enabled"])==row["cache_enabled"] and int(r["read_delay"])==row["read_delay"])
            for key in PROGRAM_FIELDS+CACHE_FIELDS:
                if key=="mode": continue
                assert str(row[key])==old[key],("baseline reproduction",key,row[key],old[key])
    rows.sort(key=lambda r:(r["order"],r["cache_enabled"],r["read_delay"],MODES.index(r["mode"])))
    fields=list(rows[0])
    (RESULTS/"programs.csv").write_text(csv_text(rows,fields))
    paths=sorted((ROOT/"rtl").glob("*/*.sv"))+[
        ROOT/f"scripts/{n}.py" for n in ("run_mac_study","generate_gemm","generate_gemm_large","generate_matvec_1x16_16x32","gemm_large_trace")]
    paths += [ROOT/"tb/benchmarks/opencorex_gemm_large_tb.sv",ROOT/"tb/memory/latency_memory_responder.sv"]
    paths += sorted((ROOT/"programs/gemm/hex").glob("*.hex"))+sorted((ROOT/"programs/gemm-large/hex").glob("*.hex"))
    provenance=dict(base_commit=subprocess.check_output(["git","rev-parse","HEAD"],text=True).strip(),
        verilator=subprocess.check_output(["verilator","--version"],text=True).strip(),
        arguments=vars(args),commands=commands,
        source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths})
    (RESULTS/"provenance.json").write_text(json.dumps(provenance,indent=2)+"\n")
    (RESULTS/"partial.json").unlink()
    print(f"PASS: {len(rows)} RTL GEMM runs; all outputs, exact instruction replay, traffic, cycle accounting, historical baselines",flush=True)


if __name__=="__main__":
    main()
