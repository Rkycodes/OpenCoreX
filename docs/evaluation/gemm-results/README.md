# Square GEMM: 16×16 and 32×32

C=A×B, with streaming CPU, four-output CPU tiling and one cold digital offload
per A row. All 60 cache/latency configurations pass; every output and unchanged
input is checked. Tiling saves **42.47–46.22%** of CPU whole-job cycles.

| Order | Streaming | Tiled | Offload |
|---:|---:|---:|---:|
| 16 | 380724 | 219012 | 118895 |
| 32 | 2993940 | 1719396 | 910703 |

Cycles above use cache enabled and backing-read L=20. [All measurements](programs.csv)
include cycles/output, cycles/product, traffic and CPU/offload ratios.

## Conditions

- Signed 32-bit wraparound; A/C row-major, B column-major.
- Time reset release through accepted completion, including every row command.
- Operands preplaced in RAM; host placement/layout conversion excluded.
- Fixed 1 MiB RAM, 128-word private offload buffer, one MAC lane, no CPU data cache.
- Both cache policies; uniform L={1,2,5,10,20}. Offload retains an A row, not B.

S is the square matrix dimension. Changing S changes all three dimensions;
these results do not isolate a MAC benefit or establish a strongest CPU baseline.

## Reproduce

```bash
make gemm-study
make gemm-check
make verify
```

[Contract and register allocation](../gemm-contract.md), [row commands](commands.csv),
[state counts](states.csv), [source hashes/commands](provenance.json),
[verification receipt](verification.json). Compressed CSV traces record independent
execution/cache replay. Larger jobs have [separate results](../gemm-large-results/README.md).
