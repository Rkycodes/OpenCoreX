# OpenCoreX Evaluation Methodology

## Purpose

This document defines how OpenCoreX performance and memory-traffic measurements
are collected and compared.

Benchmark-specific raw results belong in the corresponding file under
`programs/`. This document contains definitions and comparison rules that apply
across CPU-only, blocking-PIM, and nonblocking-PIM configurations.

The current reference benchmark is:

- [`programs/matvec_1x16_16x32.md`](../programs/matvec_1x16_16x32.md)

The executable measurement logic is implemented in:

- [`tb/opencorex_matvec_tb.sv`](../tb/opencorex_matvec_tb.sv)

## Source-of-Truth Hierarchy

Measurement information is stored at four levels:

1. Testbenches contain executable counters, assertions, and completion checks.
2. Benchmark documents record raw and derived results for one workload.
3. This document defines reusable metrics and fair-comparison rules.
4. The roadmap records milestone status, not detailed experimental results.

When documentation disagrees with executable measurement logic, the testbench
and simulation trace are authoritative. The discrepancy must then be corrected
in the documentation.

## Current Measurement Boundary

The current matrix-vector benchmark measures execution after reset is released
and through the completion write to address `0x9C4`.

The completion write is included in the measurement interval. Cycles spent
remaining in the final self-loop after completion are excluded.

The measurement does not terminate after a fixed number of cycles. It terminates
when the expected RKYC completion signature is written to the completion
destination.

This event-based boundary must remain consistent across future implementations.

## Raw CPU Metrics

The CPU-only baseline records:

- active cycles through completion,
- instruction fetches through completion,
- vector-data reads,
- matrix-data reads,
- signature reads,
- output writes,
- completion writes,
- scalar multiply operations,
- scalar accumulating additions,
- verified output count.

A raw metric is directly counted or observed by the testbench. It is not
calculated from another reported metric.

## Instruction Count

The current multicycle core is non-speculative and fetches one instruction for
each dynamically executed instruction. Therefore, instruction fetch count is
currently used as the dynamic instruction count.

This equivalence may no longer hold after adding pipelining, speculative fetch,
prefetching, replay, or caches. A future core with those features must expose an
instruction-retirement event so that fetched instructions and retired
instructions can be measured separately.

## Cycle Metrics

### Active cycles

Active cycles are clock cycles inside the defined measurement interval. Reset
cycles and cycles after the completion event are excluded.

### Cycles per output

For a benchmark producing $N$ outputs:

$$
\text{cycles per output} =
\frac{\text{active cycles}}{N}
$$

For the current matrix-vector benchmark, each output is one dot product.
Therefore, cycles per output and cycles per dot product are equivalent.

### Cycles per multiply-accumulate pair

For a workload containing $M$ mathematical multiply-accumulate operations:

$$
\text{cycles per MAC pair} =
\frac{\text{active cycles}}{M}
$$

The current CPU implements each mathematical MAC using a scalar `MUL` followed
by a scalar `ADD`. This metric is an end-to-end workload metric. It includes
instruction fetch, loop control, address calculation, memory access, and
completion overhead.

### Average cycles per instruction

For the current non-speculative multicycle processor:

$$
\text{average CPI} =
\frac{\text{active cycles}}{\text{dynamic instruction count}}
$$

This is an average over the entire benchmark. It is not the latency of every
individual instruction.

## Memory-Traffic Metrics

All memory traffic is counted in accepted word transactions. Each word is four
bytes.

The current memory does not provide request backpressure, so an asserted valid
read or write represents an accepted transaction. After the request/ready
interface is added, a transaction will count only when:

```systemverilog
mem_req_valid && mem_req_ready
```