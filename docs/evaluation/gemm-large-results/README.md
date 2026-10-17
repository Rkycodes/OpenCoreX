# Square GEMM: 64×64 and 128×128

All **60 configurations pass**, verifying all 4,096 or 16,384 outputs per job.
Inputs remain unchanged.
Tiling reduces whole-job CPU cycles by **42.53–46.19%**. Offload remains faster
for these implemented comparators. S is the square dimension in C=A×B.

| S | L | Streaming | Tiled | Offload | Tiled/offload |
|---:|---:|---:|---:|---:|---:|
| 64 | 1 | 13805570 | 7428130 | 2109386 | 3.521465 |
| 64 | 20 | 23767764 | 13655076 | 7169903 | 1.904499 |
| 128 | 1 | 109744002 | 59068322 | 16809738 | 3.513935 |
| 128 | 20 | 189436500 | 108876708 | 56970095 | 1.911120 |

Table: cache enabled, cycles. [All results and normalized metrics](programs.csv).

## Conditions

- Signed 32-bit wraparound; A/C row-major, B column-major.
- Reset through accepted completion, including every cold row command.
- Host placement/layout conversion excluded for all methods.
- Fixed 1 MiB RAM, 128-word private offload buffer, one MAC lane, no CPU data cache.
- Both cache policies and L={1,2,5,10,20}. B is reread for every A row.
- Order 128 fills each 64 KiB matrix allocation and buffer indices 0–127.

## Reproduce

```bash
make gemm-large-study   # Run and record RTL measurements
make gemm-large-audit   # Fast integrity/accounting checks on saved evidence
make gemm-large-check   # Repeat RTL runs against recorded results
```

[Contract and binary trace format](../gemm-large-contract.md), [row commands](commands.csv),
[state counts](states.csv), [trace identities](traces.csv), [small-job calibration](baseline.csv),
[source hashes/commands](provenance.json), [verification receipt](verification.json).
Exact binary traces are compressed; no per-fetch text logs. Hardware defaults
and the [16×16/32×32 evidence](../gemm-results/README.md) remain unchanged.
