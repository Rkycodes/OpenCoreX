# Controlled output-count scaling — October 7, 2026

Question: how does the remaining digital-offload advantage change with output count,
holding vector residency, cache design, arithmetic and memory service fixed?

## Contract and controls

N={32,64,128}; each workload is 1x16 by 16xN. Resident scalar CPU versus one
cold digital offload, cache bypass/enabled, uniform L={1,2,5,10,20}: 60 runs.
All runs use RAM_WORDS=262144 (1 MiB physical RAM), MAX_OUTPUTS=128,
BUFFER_WORDS=16, MAC_LANES=1. Router, validator and physical RAM capacities agree.
Production RTL/defaults are unchanged. The cache retains 512 bytes, direct mapping,
16-byte lines, two-cycle hits and four serial backing reads per miss.
One single-port backing memory, one outstanding read, unchanged write/arbitration
timing and blocking execution. Data/MMIO bypass the cache; busy gating precedes it.
Reset cache/vector validity per run. No CPU MAC, tiling, precision change or extra lanes.

| Allocation | Byte range |
|---|---|
| Boot/refill line | 0x00000-0x0000F |
| Vector | 0x00100-0x0013F |
| Constants/control | 0x00200-0x0023F; signature 0x220, completion 0x224 |
| Kernel allocation | 0x00A00-0x00DFF |
| Matrix allocation | 0x01000-0x0FFFF |
| Output allocation | 0x10000-0x10FFF |
| Unallocated RAM | 0x11000-0xFFFFF |
| Offload MMIO | 0x40000000-0x40000FFF |

Hex markers are word addresses; generators centralize/assert conversion.
Pointers/counts load from the low constant table; no ISA additions.
Within each method, instruction encodings, placement and register allocation
are identical across sizes. CPU vector registers remain x15-x30.
Each output uses the same 54-instruction scalar loop with MUL then ADD.
The vector is identical and matrices are nested. Columns 0-31 preserve the
historical formula; later columns extend it with a deterministic signed offset
to avoid simply repeating its period-37 pattern. References are calculated
from the logical matrix independently of column-major serialization.
Relocated N=32 is a new baseline; historical images/results remain intact.

Boundary: reset release through accepted completion-signature store inclusive.
Setup, launch, waiting, status and completion included; host placement and
downstream consumption excluded. START-to-final-output is secondary.

## Measured whole-program results

| N | L | CPU bypass | Offload bypass | CPU cache | Offload cache | Bypass ratio | Cache ratio | Bypass gap | Cache gap | Gap reduction |
|---|---|---|---|---|---|---|---|---|---|---|
| 32 | 1 | 9821 | 4270 | 11732 | 4349 | 2.300000 | 2.697632 | 5551 | 7383 | -1832 |
| 32 | 2 | 12105 | 4827 | 12345 | 4911 | 2.507769 | 2.513745 | 7278 | 7434 | -156 |
| 32 | 5 | 18957 | 6498 | 14184 | 6597 | 2.917359 | 2.150068 | 12459 | 7587 | 4872 |
| 32 | 10 | 30377 | 9283 | 17249 | 9407 | 3.272326 | 1.833635 | 21094 | 7842 | 13252 |
| 32 | 20 | 53217 | 14853 | 23379 | 15027 | 3.582913 | 1.555800 | 38364 | 8352 | 30012 |
| 64 | 1 | 19485 | 8398 | 23124 | 8477 | 2.320195 | 2.727852 | 11087 | 14647 | -3560 |
| 64 | 2 | 24009 | 9467 | 24249 | 9551 | 2.536073 | 2.538896 | 14542 | 14698 | -156 |
| 64 | 5 | 37581 | 12674 | 27624 | 12773 | 2.965204 | 2.162687 | 24907 | 14851 | 10056 |
| 64 | 10 | 60201 | 18019 | 33249 | 18143 | 3.340973 | 1.832608 | 42182 | 15106 | 27076 |
| 64 | 20 | 105441 | 28709 | 44499 | 28883 | 3.672751 | 1.540664 | 76732 | 15616 | 61116 |
| 128 | 1 | 38813 | 16654 | 45908 | 16733 | 2.330551 | 2.743561 | 22159 | 29175 | -7016 |
| 128 | 2 | 47817 | 18747 | 48057 | 18831 | 2.550648 | 2.552015 | 29070 | 29226 | -156 |
| 128 | 5 | 74829 | 25026 | 54504 | 25125 | 2.990050 | 2.169313 | 49803 | 29379 | 20424 |
| 128 | 10 | 119849 | 35491 | 65249 | 35615 | 3.376884 | 1.832065 | 84358 | 29634 | 54724 |
| 128 | 20 | 209889 | 56421 | 86739 | 56595 | 3.720051 | 1.532627 | 153468 | 30144 | 123324 |

## Findings and accounting

All 60 configurations verify every output, unchanged operands, exactly 16
vector reads, 16N matrix reads, N output writes and 16N arithmetic operations
(CPU MUL/accumulating-ADD pairs or offload MACs). Independent execution/cache
replay matches every logical fetch and miss. Writes to executable allocations
are rejected. Capability/limit checks advertise 128; zero and 129 reject with
INVALID_OUTPUT_COUNT before operand traffic; valid 128 completes correctly.

Dynamic CPU fetches are 54N+23; offload fetches stay at 23.
CPU misses stay at 20 and offload misses at 7: 80 and 28 refill words.
There are no later resident-loop misses. More output columns increase loop
iterations and operand traffic, not the instruction working set.

Exact equality holds for all enabled runs:
T_cache-T_bypass = hits*(2-L)+misses*(6+3L).
Uniform-latency growth from L=1 also exactly equals categorized backing-read waits.
The CPU still uses separate scalar MUL/ADD, operand loads, addressing and loop
control; offload still streams every matrix word. The residual includes the
chosen lookup/refill policy, so it is not an isolated fused-MAC benefit.

| N | Cached CPU cycles/output at L=20 | Cached offload cycles/output at L=20 | Cached ratio |
|---|---|---|---|
| 32 | 730.593750 | 469.593750 | 1.555800 |
| 64 | 695.296875 | 451.296875 | 1.540664 |
| 128 | 677.648438 | 442.148438 | 1.532627 |

Cold refill and CPU/offload setup costs amortize as N grows. Total cycles
are exactly affine across the three tested sizes at every fixed policy/latency.
With caching at L=20, CPU cycles=660N+2259 and offload cycles=433N+1171.
These identities describe the measured sizes, not measurements at other N.
The cached ratio decreases from 1.556 to 1.533 at L=20, while the absolute
gap grows from 8352 to 30144 cycles. At L=1 the ratio instead increases
from 2.698 to 2.744: size trends depend on the memory-service assumption.
Caching remains slower than bypass at L=1 and L=2 for all three sizes;
it helps the resident CPU at L=5,10,20. Offload refill overhead remains visible.

## Reproduction and evidence

- Run `make scaling-study` to regenerate and validate all images/results.
- Run `make scaling-check` to rerun and compare against tracked evidence.
- Run `python3 scripts/run_scaling_study.py --compat-only` for capacity-only reproduction.
- Run `make verify` for historical lint, protocol/reset/conflict/busy, and benchmark regression.
- [Primary counters and derived metrics](programs.csv), [disjoint states](states.csv),
  [offload boundaries](commands.csv), [capacity-only compatibility](capacity-compatibility.csv),
  [limit checks](limits.csv), [source hashes/exact commands](provenance.json),
  and [completed verification evidence](verification.json).
- Independent accepted-fetch predictions are in `resident-N-trace.csv` and `offload-N-trace.csv`.
- Build/run logs are under `obj_dir/verification/output_scaling`.
  Source hashes identify measured code; the base commit records ancestry, not a substitute for hashes.

CPU-state cycles form a disjoint partition summing to whole-program cycles.
Busy, request backpressure, CPU response waits and backing wait counters overlap
that partition and must not be added to it. Physical RAM size is fixed across all sizes.

This establishes output-count scaling with vector length 16, not behavior when
vectors exceed registers/buffer. No energy, area, calibrated DRAM, physical
clock-time or general CPU/PIM superiority claims follow.

Next separate experiment: define a CPU MAC instruction/control with explicit
accumulator, low-product/modulo semantics, encoding and multicycle latency.
Hold these images' layout, vector residency, cache and memory service fixed;
compare matched scalar versus MAC kernels and report both instruction counts
and total cycles. Do not combine that intervention with another architecture change.
