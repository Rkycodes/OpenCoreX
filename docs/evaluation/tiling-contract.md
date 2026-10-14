# Larger-vector output tiling — contract settled October 14, 2026

Measure x(1×K) B(K×32), K={16,32,64,128}, streaming scalar CPU,
four-output-tiled scalar CPU, and one cold digital offload; bypass/enabled
instruction cache and uniform backing-read L={1,2,5,10,20}: 120 cases.
Whole-program timing is reset release through accepted RKYC store, inclusive.
Setup, launch, blocking wait, status and completion are included.

Fixed experiment-only parameters: RAM_WORDS=262144, BUFFER_WORDS=128,
MAX_OUTPUTS=128, MAC_LANES=1. Production defaults and historical evidence stay
intact. The offload has a provisioned 512-byte private vector buffer, enough
for all 128 elements; the CPU has 31 writable 32-bit registers shared by operands,
accumulators, pointers and counters. These comparators have different storage
capacities. Neither CPU kernel retains the whole vector or matrix.

The existing single port, one outstanding read, arbitration, accepted-write
timing, blocking router and cache policy are unchanged: 512 bytes, direct mapped,
16-byte lines, registered two-cycle hits and four serial refill reads, without
early restart, prefetch or burst. Data/MMIO bypass and busy gating are preserved.
Each run resets cache and vector validity. Signed 32-bit inputs use low-32-bit
products and modulo-2^32 sums. Smaller inputs prefix the maximum logical inputs;
references are computed before column-major serialization.

| Allocation | Byte range / use |
|---|---|
| Boot | 0x00000–0x0000F; JAL to kernel, full refill line |
| Vector | 0x00100–0x002FF |
| Constants/control | 0x00400–0x004FF; signature 0x440, completion 0x444 |
| Kernel | 0x01000–0x04FFF; padded full final refill line |
| Future A | 0x10000–0x1FFFF; unused |
| Matrix B | 0x20000–0x2FFFF; column stride 4K bytes |
| Outputs | 0x30000–0x3FFFF |
| Remaining RAM | 0x40000–0xFFFFF |
| MMIO | 0x40000000–0x40000FFF |

All RAM pointers load with supported LW from x0-relative constants. Hex @
markers are word indices. Generators check alignment, disjoint allocations,
RAM and complete refill-line bounds, and signed branch/JAL reach. The harness
rejects CPU and offload writes to either executable allocation.

## CPU register and loop contract (before implementation)

Shared: x5 vector base, x6 current matrix address, x7 output pointer, x8 outputs
remaining, x9 K, x10 walking vector pointer, x12 loaded vector element,
x13 reduction count, x14 product, x18 loaded weight, x31 completion signature.
Streaming accumulates in x11; tiling uses x11/x15/x16/x17. x0 is constant zero.
All used registers are initialized before use; unused registers need no reset.

Streaming initializes vector pointer, K counter and one sum per output. Its
eight-instruction inner loop loads vector/weight, executes scalar MUL then ADD,
advances both pointers by four, decrements K and BNEs. After K products it
stores the sum, advances output by four, decrements N and repeats. The matrix
pointer naturally arrives at the next column. No partial sums are stored.

Tiling initializes vector pointer, K counter and four sums per tile. Its
17-instruction inner loop loads x[k] once, then four weights at offsets
0/4K/8K/12K from x6 and four scalar MUL/ADD pairs. It advances x10 and x6 by
four, decrements the reduction counter and BNEs. At K=128 the largest weight
offset is 1536, within signed 12-bit LW reach. After K iterations, four stores
write consecutive completed outputs; x6 skips another 12K bytes (also ≤1536)
to the next four-column tile, x7 advances 16 and x8 decrements four. N=32
needs exactly eight tiles; remainder handling is outside this study. The
instruction structure and code size stay fixed across K; only three weight
offsets and the matrix-skip immediate change in the tiled code. No new ISA,
CPU MAC, matrix buffering or partial-sum spills are introduced.

Both kernels load RKYC from 0x440 and store to 0x444 after all 32 outputs.
Offload loads descriptors, accepts one cold START, blocks until done, reads
and checks status, then performs the same completion store. Failure parks
without completion. Host placement and downstream consumption are excluded.

Expected traffic: vector reads 32K/8K/K (streaming/tiled/offload), matrix reads
32K and output writes 32 for each. CPU MULs and accumulating ADDs are 32K each;
offload MACs are 32K. Literals/signature, completion and MMIO are separate.
Dynamic fetch predictions are 256K+232, 136K+120, and 23 respectively.
Disjoint CPU-state cycles sum to total cycles; busy, response waits and request
backpressure overlap those states. For unchanged no-contention cache timing,
verify T_cache−T_bypass = hits(2−L)+misses(6+3L), without fitting results.
