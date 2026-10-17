"""Audit recorded large-GEMM evidence without rerunning RTL simulations."""
from array import array
import csv
import gzip
import hashlib
import json
from run_gemm_large import ROOT, BUILD, RESULTS, compare_binary


def read_csv(name):
    with (RESULTS/name).open() as stream:
        return list(csv.DictReader(stream))


def main():
    provenance = json.loads((RESULTS/"provenance.json").read_text())
    for name, digest in provenance["source_sha256"].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest() == digest, name
    rows, states, commands, traces = (read_csv(n) for n in ("programs.csv", "states.csv", "commands.csv", "traces.csv"))
    assert len(rows) == 60 and len(states) == 960 and len(commands) == 1920 and len(traces) == 12
    assert len(read_csv("baseline.csv")) == 12
    for trace in traces:
        s, enabled, mode = int(trace["order"]), int(trace["cache_enabled"]), trace["mode"]
        digest, length = hashlib.sha256(), 0
        with gzip.open(RESULTS/f"{mode}-{s}-cache{enabled}.fetch.bin.gz", "rb") as stream:
            while chunk := stream.read(1 << 20):
                digest.update(chunk)
                length += len(chunk)
        assert length == 4*int(trace["fetches"]) and digest.hexdigest() == trace["sha256"]
    for row in rows:
        def n(key): return int(row[key])
        s, cache, mode, delay = n("order"), n("cache_enabled"), row["mode"], n("read_delay")
        key = lambda r: int(r["order"]) == s and int(r["cache_enabled"]) == cache and int(r["read_delay"]) == delay
        assert n("output_writes") == s*s and n("completion_writes") == 1
        assert n("matrix_reads") == s*s*s
        assert n("vector_reads") == {"streaming":s*s*s, "tiled":s*s*s//4, "offload":s*s}[mode]
        expected_fetches = {"streaming":s*(8*s*s+7*s+5)+9, "tiled":s*((s//4)*(17*s+14)+5)+9, "offload":18*s+10}[mode]
        assert n("fetches") == expected_fetches
        assert n("cpu_muls") == n("cpu_accumulating_adds") == (s*s*s if mode != "offload" else 0)
        assert n("offload_macs") == (s*s*s if mode == "offload" else 0)
        assert sum(int(r["cycles"]) for r in states if key(r) and r["mode"] == mode) == n("whole_cycles")
        expected_trace = next(r for r in traces if int(r["order"]) == s and int(r["cache_enabled"]) == cache and r["mode"] == mode)
        assert row["trace_sha256"] == expected_trace["sha256"]
        if mode == "offload":
            intervals = [r for r in commands if key(r)]
            assert len(intervals) == s
            assert sum(int(r["execution_cycles"]) for r in intervals) == n("command_cycles")
            assert n("last_index_writes") == (128 if s == 128 else 0)
            assert n("last_index_reads") == (128*127 if s == 128 else 0)
        if cache:
            bypass = next(r for r in rows if int(r["order"]) == s and r["mode"] == mode and int(r["read_delay"]) == delay and int(r["cache_enabled"]) == 0)
            assert n("whole_cycles")-int(bypass["whole_cycles"]) == n("hits")*(2-delay)+n("misses")*(6+3*delay)
    # Explicitly ensure the binary comparator rejects truncated, extra and
    # altered bytes, rather than accepting a matching prefix or digest alone.
    words = array("I", [0, 0x80001000, 0x1010])
    raw = memoryview(words).cast("B").tobytes()
    probe = BUILD/"audit_comparator.fetch.bin"
    for bad in (raw[:-1], raw+b"\x00", bytes([raw[0]^1])+raw[1:]):
        probe.write_bytes(bad)
        try:
            compare_binary(probe, words)
        except AssertionError:
            pass
        else:
            raise AssertionError("invalid trace accepted")
    probe.write_bytes(raw)
    assert compare_binary(probe, words) == hashlib.sha256(raw).hexdigest()
    print("PASS: 60 recorded cases, 1920 row commands, trace/source SHA-256, counter formulae, state/cache accounting and binary rejection checks")


if __name__ == "__main__":
    main()
