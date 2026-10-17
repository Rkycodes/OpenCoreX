# Square matrix multiplication — October 17, 2026

Implemented and verified **16×16 and 32×32 C=A×B** with streaming scalar CPU,
four-output-tiled scalar CPU and the existing single-lane digital matvec offload.
No production RTL or ISA changes. Larger orders are outside this experiment.

## Contract and timing

The [contract](../gemm-contract.md) records register allocation, layouts, row loops,
command sequence and memory map. A and C are row-major; B is column-major.
All methods use the same deterministic signed 32-bit inputs and modulo-2^32
products/sums. References use logical matrices before serialization. Order 16
uses the top-left logical input submatrices of order 32, packed at its own stride.

Whole-job timing runs from reset release through the accepted RKYC completion
store inclusive. It includes every row, CPU loop, launch, validation, busy wait,
status check and final completion. **Host operand placement and layout conversion
are excluded for all methods.** These are preplaced-layout measurements, not
row-major-input end-to-end transpose measurements. There is no timed transpose.

RAM_WORDS=262144 (1 MiB), BUFFER_WORDS=128, MAX_OUTPUTS=128 and MAC_LANES=1
are fixed across all runs. The provisioned offload buffer is 512 bytes, while
CPU arithmetic and control share 31 writable registers. Neither CPU retains
whole A/B matrices; there is no CPU data cache. The existing instruction cache
keeps its 512-byte direct mapping, 16-byte lines, two-cycle hits and four serial
refill reads. One backing port, one outstanding read, blocking and arbitration
timing are unchanged. Cache and buffer validity reset once per complete job.

Offload performs S cold commands, one per A row. Each command configures all
six descriptor fields and uses START=1 without REUSE. The controller begins a
new vector and refills the buffer for each row. B is reread for every output row.
CPU/cache state persists between commands. Status must indicate successful done
before the next row proceeds; failures cannot emit the completion signature.

## Complete-job results

Three methods × two orders × cache bypass/enabled × uniform backing-read
L={1,2,5,10,20} give 60 configurations. All timing values below are cycles.

| Order | L | Streaming bypass | Tiled bypass | Offload bypass | Streaming cache | Tiled cache | Offload cache |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 | 1 | 189641 | 102217 | 34800 | 224354 | 120706 | 35162 |
| 16 | 2 | 232488 | 125736 | 39473 | 232584 | 125880 | 39569 |
| 16 | 5 | 361029 | 196293 | 53492 | 257274 | 141402 | 52790 |
| 16 | 10 | 575264 | 313888 | 76857 | 298424 | 167272 | 74825 |
| 16 | 20 | 1003734 | 549078 | 123587 | 380724 | 219012 | 118895 |
| 32 | 1 | 1478489 | 797017 | 266656 | 1748034 | 940130 | 267306 |
| 32 | 2 | 1813512 | 981000 | 301073 | 1813608 | 981144 | 301169 |
| 32 | 5 | 2818581 | 1532949 | 404324 | 2010330 | 1104186 | 402758 |
| 32 | 10 | 4493696 | 2452864 | 576409 | 2338200 | 1309256 | 572073 |
| 32 | 20 | 7843926 | 4292694 | 920579 | 2993940 | 1719396 | 910703 |

Tiling reduces CPU whole-job cycles by **42.47–46.22%** across the 20 matched
CPU pairs. This combines reduced A traffic and fewer addressing/loop instructions.
It still executes S³ scalar MUL/ADD pairs and reads all S³ B words. Offload
remains faster for these implemented comparators, with its larger private storage.
Changing S changes the row count, output columns and reduction length together;
this square-GEMM comparison does not isolate vector-length or output-count effects.
The comparison does not isolate a MAC-instruction benefit or establish the
strongest possible CPU implementation. No physical PPA, energy or calibrated
DRAM claim follows from these abstract cycle measurements.

| Cached L=20 | Streaming | Tiled | Offload | Tiled/offload |
|---|---:|---:|---:|---:|
| 16×16 cycles/output | 1487.203125 | 855.515625 | 464.433594 | 1.842062 |
| 16×16 cycles/product | 92.950195 | 53.469727 | 29.027100 | — |
| 32×32 cycles/output | 2923.769531 | 1679.097656 | 889.358398 | 1.887988 |
| 32×32 cycles/product | 91.367798 | 52.471802 | 27.792450 | — |

## Exact accounting

| Per complete job, order S | Streaming | Tiled | Offload |
|---|---:|---:|---:|
| A reads | S³ | S³/4 | S² |
| B reads | S³ | S³ | S³ |
| C writes | S² | S² | S² |
| CPU MULs / accumulating ADDs | S³ / S³ | S³ / S³ | 0 / 0 |
| Digital MACs | 0 | 0 | S³ |
| Literal reads / signature reads | 5 / 1 | 5 / 1 | (6+S) / 1 |
| Completion writes | 1 | 1 | 1 |
| MMIO writes / status reads | 0 / 0 | 0 / 0 | 7S / S |
| Cold row commands | 0 | 0 | S |
| Buffer writes / reads | 0 / 0 | 0 / 0 | S² / S²(S−1) |
| Static instruction bytes including boot and parks | 120 | 184 | 120 |
| Cache misses / refill words | 8 / 32 | 12 / 48 | 8 / 32 |

Dynamic fetches are S(8S²+7S+5)+9 for streaming, S((S/4)(17S+14)+5)+9
for tiling, and 18S+10 for offload. At order 32 these are 269481, 143017 and
586. Compact instruction structure/size stays fixed across orders. No partial
sums spill, and no writes occur outside C and completion.

In [programs.csv](programs.csv), `vector_reads` means A-row backing reads and
`matrix_reads` means B backing reads, retaining the established harness field
names. The file includes cycles/output, cycles/product, method/offload ratios,
buffer and MMIO traffic, fetch/cache counters and overlapping wait counters.
[commands.csv](commands.csv) gives all 480 measured row-command intervals.
`command_cycles` sums these START-to-final-output intervals; offload
`command_overhead_cycles` is whole-job time minus that sum, including setup,
between-command control/status and completion. It is not excluded from the
primary time. [states.csv](states.csv) partitions whole-job cycles into 16
disjoint CPU states. Busy, request-blocked and response-wait counts overlap
those states and must not be added to them.

All 30 enabled-cache runs exactly satisfy
`T_cache−T_bypass = hits*(2−L)+misses*(6+3L)`.
Latency growth from L=1 exactly matches categorized backing-read waits.
Offload now repeats a compact command loop across rows, so instruction-cache
reuse differs from a single-command matvec. Its cache overhead/benefit must be
measured at this whole-job boundary rather than copied from the older study.

## Reproduction and verification

From `/home/robel/OpenCoreX` in Ubuntu WSL:

```bash
make gemm-study
make gemm-check
make verify
```

Run order 16 before order 32. Every run checks all S² outputs against logical
references, unchanged A/B, exact operand address sequences and arithmetic counts,
no partial-sum spills, all S cold command descriptors/status responses, request
stability, response timing/ownership, single-port service, busy CPU blocking
and correct accepted completion. Six negative runs reject executable writes
from scalar CPU paths and offload, with cache bypass/enabled.

Independent RV32 execution also checks every output and unchanged operand, then
replays accepted fetches against a separate cache model. Six deterministic
`method-order-trace.csv.gz` files contain those predictions and match RTL exactly.
[provenance.json](provenance.json) records simulator version, base ancestry,
measured source SHA-256 identities and exact commands. [verification.json](verification.json)
records actual check results and log hashes. Logs live in `obj_dir/gemm-*.log`
and `obj_dir/verification/square_gemm/`. Historical source/images/results remain
intact; this study uses separate files and build output.
