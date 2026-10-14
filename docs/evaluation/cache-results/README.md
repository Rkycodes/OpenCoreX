# October 19 instruction-cache results

Measured whole-program cycles; reset through accepted completion store. All 20 cases pass.
Programs/operands unchanged. Registered lookup and full four-word refill are included.

| L | CPU bypass | Offload bypass | CPU cache | Offload cache | Bypass ratio | Cache ratio | Bypass gap | Cache gap | Gap reduction |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 9818 | 4272 | 11738 | 4353 | 2.298 | 2.697 | 5546 | 7385 | -1839 |
| 2 | 12099 | 4827 | 12351 | 4911 | 2.507 | 2.515 | 7272 | 7440 | -168 |
| 5 | 18942 | 6492 | 14190 | 6585 | 2.918 | 2.155 | 12450 | 7605 | 4845 |
| 10 | 30347 | 9267 | 17255 | 9375 | 3.275 | 1.841 | 21080 | 7880 | 13200 |
| 20 | 53157 | 14817 | 23385 | 14955 | 3.588 | 1.564 | 38340 | 8430 | 29910 |

Independent RV32 trace replay agrees with every accepted fetch:
resident 1,752 fetches / 21 misses / 1,731 hits / 84 refill words;
offload 25 fetches / 7 misses / 18 hits / 28 refill words.
The resident's 21 misses are first visits to distinct lines; the repeated loop has no later misses.
Every run retains 16 vector reads, 512 matrix reads and 32 output writes.
CPU uses 512 MULs plus 512 accumulating ADDs; offload uses 512 MACs.

## Cycle accounting and interpretation

For this no-contention, blocking study, a hit has acceptance-to-response latency 2;
a full miss has latency 6+4L. Relative to bypass, measured whole-program change is
hits*(2-L) + misses*(6+3L). Exact equality is checked in all enabled runs.
At L=1 the cache adds lookup/refill overhead despite reducing instruction RAM traffic.
At larger L repeated hits avoid backing waits, while compulsory full-line refills remain.
Fetch-state response occupancy includes registered lookup and refill service;
backing fetch_wait counts only delayed backing responses, so the counters overlap.
CPU-state cycles are disjoint and sum to whole-program cycles. cpu_blocked includes
request backpressure; busy_blocked is an overlapping subset. PIM waits overlap CPU busy.
The CPU still executes separate scalar arithmetic, loads, address/control instructions
and multicycle state transitions. The offload still streams all 512 matrix words.
These counts support a residual-cost explanation, not a causal estimate for fused MAC.

## Reproduction and limits

Run `make cache-study` to regenerate; `python3 scripts/run_cache_study.py --check`
requires exact agreement with tracked counters/traces. `make verify` includes that check.
Commands, Verilator version and source hashes are in provenance.json;
individual build/run logs are under obj_dir/verification/cache_study.
The parent Git HEAD alone does not identify uncommitted changes: use the source hashes.
Host placement and downstream consumption are excluded. Latencies are synthetic;
no energy, area, calibrated DRAM or physical clock-time conclusions follow.
No scaling, associativity, D8 or CIM results are claimed.

## Measured residual breakdown at L=20

Disjoint whole-program groups derived from controller states; busy request
clocks are removed from FETCH and shown separately.

| Group | Resident CPU | Offload CPU/program |
|---|---|---|
| Fetch request and response | 7020 | 663 |
| Decode | 1752 | 25 |
| ALU execution and writeback | 2314 | 26 |
| Data/MMIO address, access and writeback | 12233 | 66 |
| Branch/jump | 66 | 2 |
| CPU blocked during offload | 0 | 14173 |
| Total | 23385 | 14955 |

The 8,430-cycle residual is the difference of these complete paths.
Its latency slope is 55 cycles per added backing-response cycle:
resident has 84 refill + 529 data reads; offload has 28 refill + 530 data reads.
The residual also includes cold spatial-refill costs and the selected lookup policy;
it is not a pure measure of arithmetic or control advantage.
