# 1×16 by 16×32 CPU Matrix-Vector Benchmark

## Purpose

This benchmark establishes the CPU-only baseline for future
processing-in-memory (PIM) and accelerator studies.

It computes a 32-element output vector:

\[
y[j] = \sum_{i=0}^{15} x[i] \times W[i][j]
\]

where:

- `x` is a signed 16-element input vector.
- `W` is a signed 16×32 matrix.
- `y` is a signed 32-element output vector.

The CPU executes all multiply-accumulate operations using scalar RV32IM
instructions. A deterministic, mixed-sign input set is generated in software,
and all 32 outputs are checked against an independent software reference.

## Memory Layout

| Region | Byte address range | Size | Contents |
|---|---:|---:|---|
| Program | `0x000`–`0x05B` | 23 instructions | Matrix-vector kernel and completion loop |
| Vector `x[0:15]` | `0x100`–`0x13F` | 16 words | Signed input vector |
| Matrix `W[0:15][0:31]` | `0x140`–`0x93F` | 512 words | Signed matrix, stored output-column-major |
| Outputs `y[0:31]` | `0x940`–`0x9BF` | 32 words | CPU-computed result vector |
| RKYC signature source | `0x9C0` | 1 word | `0x524B5943` |
| Completion destination | `0x9C4` | 1 word | Written with `0x524B5943` when complete |

The matrix is stored so that the 16 weights required for one output are
contiguous:

\[
\text{address}(W[i][j]) = 0x140 + 4 \times (16j + i)
\]

This layout makes each inner loop a sequential walk through one matrix column.
It is deliberately explicit so that a later PIM implementation can use the
same logical workload while changing only where computation occurs.

## Register Allocation

| Register | Role |
|---|---|
| `x5` | Constant vector base address: `0x100` |
| `x6` | Current matrix-column pointer |
| `x7` | Current output pointer |
| `x8` | Remaining output count |
| `x9` | Working vector pointer, reset for every output |
| `x10` | Remaining inner-loop count |
| `x11` | Accumulator for the current output |
| `x12` | Current vector element |
| `x13` | Current matrix element |
| `x14` | Product register |
| `x31` | RKYC completion signature |

## Loop Structure

```text
for j in 0..31:
    vector_pointer = vector_base
    accumulator = 0

    for i in 0..15:
        vector_value = x[i]
        matrix_value = W[i][j]
        product = vector_value * matrix_value
        accumulator = accumulator + product

    y[j] = accumulator
```

The matrix pointer is not reset after each output. It advances by 16 words
during each inner loop, then already points to the next output column.

The vector pointer is reset to `x5` for each output because every output uses
the same input vector.

## Completion Protocol

After storing `y[31]`, the program:

1. Loads `0x524B5943` (`RKYC`) from `0x9C0` into `x31`.
2. Stores `x31` to `0x9C4`.
3. Enters a self-loop.

The completion write is the reliable termination indicator used by the
testbench. The testbench does not infer completion from a fixed cycle count.

## Verification

The generator creates:

- `programs/hex/matvec_1x16_16x32.hex`
- `programs/hex/matvec_1x16_16x32_expected.hex`

The testbench checks:

- Every one of the 32 output stores has the expected address and value.
- Outputs are stored sequentially from `0x940` through `0x9BC`.
- The RKYC completion write reaches `0x9C4`.
- The input vector and matrix remain unchanged.
- Final register values match the completed loop state.
- The expected dynamic instruction and memory-operation counts occur.

## Observed CPU Baseline

| Metric | Result |
|---|---:|
| Matrix dimensions | 16 × 32 |
| Outputs verified | 32 / 32 |
| Multiply operations | 512 |
| Accumulating additions | 512 |
| Vector-memory reads | 512 |
| Matrix-memory reads | 512 |
| Output writes | 32 |
| Completion writes | 1 |
| Instruction fetches through completion | 4327 |
| Active cycles through completion | 23685 |

The CPU reads only 16 unique vector words, but rereads them 32 times for a
total of 512 vector-memory reads. That reuse is a concrete data-movement
opportunity for the future accelerator/PIM study.

### Derived Performance Metrics

| Metric | Calculation | Result |
|---|---:|---:|
| Cycles per output/dot product | `23685 / 32` | 740.156 |
| Instructions per output | `4327 / 32` | 135.219 |
| Cycles per multiply-accumulate pair | `23685 / 512` | 46.260 |
| Average cycles per instruction | `23685 / 4327` | 5.474 |
| Kernel data reads | `512 + 512` | 1024 words |
| Kernel data writes | `32` | 32 words |
| Kernel data traffic | `(1024 + 32) × 4` | 4224 bytes |
| Completion-protocol traffic | `(1 signature read + 1 completion write) × 4` | 8 bytes |
| Total data traffic through completion | `4224 + 8` | 4232 bytes |
| Instruction-fetch traffic | `4327 × 4` | 17308 bytes |
| Unified instruction and data traffic | `17308 + 4232` | 21540 bytes |
| Unique workload data footprint | `(16 + 512 + 32) × 4` | 2240 bytes |
| Redundant vector reads | `512 - 16` | 496 words / 1984 bytes |
| Kernel-read reduction if the vector is fetched once | `496 / 1024` | 48.438% |

Each output is one 16-element dot product, so cycles per output and cycles
per dot product are the same for this benchmark.

A multiply-accumulate pair means one scalar `MUL` followed by the corresponding
scalar accumulator `ADD`. OpenCoreX currently implements these as two separate
instructions, not as one fused multiply-accumulate instruction.

The traffic figures count transactions observed at the unified CPU memory
interface. Testbench reads used to inspect final memory contents are verification
activity and are not counted as processor-generated memory traffic.

## Reproduction

```bash
python3 scripts/generate_matvec_1x16_16x32.py
make verify
```

The benchmark passes when the matrix-vector test reports all 32 output stores,
the RKYC completion write, and the final completion summary as `PASS`.