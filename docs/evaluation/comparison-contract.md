# Executable 16×32 comparison contract

All rows use the same signed 32-bit operands initially in the same single-port
RAM. Host placement is excluded. OpenCoreX has no CPU cache. The current PIM
is a separate digital MAC with an SRAM vector buffer, not in-array CIM.

| Role / program | Whole-program cycles | START → final output cycles | CPU instruction fetches | Vector RAM reads | Matrix RAM reads | Output RAM writes |
|---|---:|---:|---:|---:|---:|---:|
| Looped, memory-based CPU: general reference | 23,685 | — | 4,327 | 512 | 512 | 32 |
| Unrolled streaming CPU: control experiment | 13,290 | — | 2,248 | 512 | 512 | 32 |
| Register-resident CPU: strongest implemented comparator for this 16×32 workload | 9,818 | — | 1,752 | 16 | 512 | 32 |
| Existing 32-bit CPU-driven PIM offload | 4,272 | 4,141 | 25 | 16 | 512 | 32 |
| Two-command PIM cold fill | shared 8,452 total | 4,141 | shared 31 total | 16 | 512 | 32 |
| Two-command PIM warm reuse | shared 8,452 total | 4,140 | shared 31 total | 0 | 512 | 32 |

Whole-program clocks start at reset release and include acceptance of the
RKYC completion store. START → final output is final accepted output edge
minus accepted START edge; setup and status handling are outside it.
The two-command total is not a per-command whole-program measurement.

Evidence: [looped subsystem test](../../tb/benchmarks/opencorex_matvec_subsystem_tb.sv),
[diagnostics](../../tb/benchmarks/opencorex_matvec_diagnostic_tb.sv),
[offload](../../tb/benchmarks/opencorex_pim_offload_tb.sv), and
[cold/warm](../../tb/benchmarks/opencorex_pim_cold_warm_tb.sv).
The diagnostics run both direct-core and shared-subsystem paths.
Every run checks all 32 outputs and unchanged inputs; instruction and traffic
counts stop at completion and exclude testbench inspection. Each CPU program
also reads one signature word and writes one completion word; offload programs
also read a RAM MMIO-base literal. MMIO control traffic is separate.

At one-cycle RAM latency, eliminating 16 vector reads saves only one PIM
execution cycle. This is the hypothesis to test under matched read-response
delays, not evidence that traffic has no cost under other memory assumptions.
Warm reuse requires a prior successful fill without reset or invalidation.

These workload-specific cycles do not establish energy, area, or physical
clock-time superiority. The CPU programs have different control flow and
register reuse; the 4,141-cycle execution boundary cannot replace the 4,272-cycle
whole-program comparator. Packed signed-8-bit and matrix-resident CIM variants
require separately matched arithmetic, residency, and physical characterization.
