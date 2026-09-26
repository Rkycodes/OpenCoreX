# PIM Event Accounting

## Status

**Draft experimental accounting contract.** This document records the assumptions used for the current benchmark model. Treat performance and energy results as provisional until Professor Yang confirms the modeling boundaries.

## Purpose

This document defines how to count benchmark events and assign their costs across OpenCoreX, PiMulator, and NeuroSim. Keep it separate from the PIM architecture document: the architecture document explains how the system works; this document explains how experiments are measured.

## Configurations

The following configuration names and definitions are used in this accounting contract.

| Configuration | Definition |
|---|---|
| `D0-32` | No-buffer, signed 32-bit CPU/digital baseline |
| `D8` | Buffered 8-bit digital accelerator with 32-bit accumulation and output |
| `C-SRAM-8` | 8-bit SRAM compute-in-memory |
| `C-RRAM-8` | 8-bit RRAM compute-in-memory |

## Benchmark and Counting Assumptions

The benchmark computes a 1 × 16 vector multiplied by a 16 × 32 matrix. It performs **512 logical MACs** and produces **32 outputs**.

The accounting uses these assumptions:

- 8-bit operands are densely packed: four operands fit in each 32-bit external-memory beat.
- Outputs are signed 32-bit values.
- A cold matrix requires transferring or programming all 512 weights.
- A warm matrix is already resident in the CIM array before the measured run.
- A cold vector requires loading its 16 elements.
- A warm vector buffer contains valid data matching the benchmark input.
- No dirty matrix is evicted. PiMulator must count any eviction writebacks separately if they occur.
- The complete 16 × 32 matrix fits in one CIM mapping and is processed in one VMM invocation.
- A canonical accelerator launch uses six descriptor writes, one `COMMAND` write, and one final `STATUS` read: **7 MMIO writes and 1 MMIO read**.
- A repeated launch with unchanged descriptors uses one `COMMAND` write and one `STATUS` read.
- External-memory read counts are reported as **logical elements / 32-bit memory beats**.
- A logical weight program is counted once per 8-bit weight. NeuroSim models the physical programming activity for those logical programs.
## Per-Configuration Event Counts

The table shows the canonical-launch MMIO count. For repeated launches with unchanged descriptors, replace **7 MMIO writes and 1 MMIO read** with **1 MMIO write and 1 MMIO read**.

External reads are shown as logical elements / 32-bit memory beats. A warm vector eliminates external vector reads. A warm matrix eliminates external matrix reads only for configurations with matrix residency.

| Configuration | Matrix / vector state | MMIO W/R | External vector reads (elements / beats) | External matrix reads (elements / beats) | External output writes (elements / beats) | Local-buffer events | Matrix-program events | Compute events | CPU wait |
|---|---|---:|---:|---:|---:|---|---:|---|---|
| `D0-32` | Any / any | 0 / 0 | 512 / 512 | 512 / 512 | 32 / 32 | None | 0 | 512 MUL + 512 ADD | 0 blocked cycles; 23,685 total active cycles |
| `D8` | Cold matrix, cold vector | 7 / 1 | 16 / 4 | 512 / 128 | 32 / 32 | 16 vector writes + 496 vector reads | 0 | 512 digital MACs | Measure `W_D8_CV` |
| `D8` | Warm matrix, cold vector | 7 / 1 | 16 / 4 | 512 / 128 | 32 / 32 | 16 vector writes + 496 vector reads | 0 | 512 digital MACs | Same accounting as cold matrix |
| `D8` | Cold matrix, warm vector | 7 / 1 | 0 / 0 | 512 / 128 | 32 / 32 | 512 vector reads | 0 | 512 digital MACs | Measure `W_D8_WV` |
| `D8` | Warm matrix, warm vector | 7 / 1 | 0 / 0 | 512 / 128 | 32 / 32 | 512 vector reads | 0 | 512 digital MACs | Same accounting as cold matrix |
| `C-SRAM-8` | Cold matrix, cold vector | 7 / 1 | 16 / 4 | 512 / 128 | 32 / 32 | 16 vector writes + 16 vector reads | 512 SRAM weight writes | 1 SRAM VMM invocation = 512 MAC-equivalents | Measure `W_CS_CC` |
| `C-SRAM-8` | Cold matrix, warm vector | 7 / 1 | 0 / 0 | 512 / 128 | 32 / 32 | 16 vector reads | 512 SRAM weight writes | 1 SRAM VMM invocation = 512 MAC-equivalents | Measure `W_CS_CW` |
| `C-SRAM-8` | Warm matrix, cold vector | 7 / 1 | 16 / 4 | 0 / 0 | 32 / 32 | 16 vector writes + 16 vector reads | 0 | 1 SRAM VMM invocation = 512 MAC-equivalents | Measure `W_CS_WC` |
| `C-SRAM-8` | Warm matrix, warm vector | 7 / 1 | 0 / 0 | 0 / 0 | 32 / 32 | 16 vector reads | 0 | 1 SRAM VMM invocation = 512 MAC-equivalents | Measure `W_CS_WW` |
| `C-RRAM-8` | Cold matrix, cold vector | 7 / 1 | 16 / 4 | 512 / 128 | 32 / 32 | 16 vector writes + 16 vector reads | 512 logical RRAM weight programs | 1 RRAM VMM invocation = 512 MAC-equivalents | Measure `W_CR_CC` |
| `C-RRAM-8` | Cold matrix, warm vector | 7 / 1 | 0 / 0 | 512 / 128 | 32 / 32 | 16 vector reads | 512 logical RRAM weight programs | 1 RRAM VMM invocation = 512 MAC-equivalents | Measure `W_CR_CW` |
| `C-RRAM-8` | Warm matrix, cold vector | 7 / 1 | 16 / 4 | 0 / 0 | 32 / 32 | 16 vector writes + 16 vector reads | 0 | 1 RRAM VMM invocation = 512 MAC-equivalents | Measure `W_CR_WC` |
| `C-RRAM-8` | Warm matrix, warm vector | 7 / 1 | 0 / 0 | 0 / 0 | 32 / 32 | 16 vector reads | 0 | 1 RRAM VMM invocation = 512 MAC-equivalents | Measure `W_CR_WW` |

## Architectural Implications

- `D0-32` has no resident vector or matrix, so cold/warm labels do not change its traffic.
- `D8` reuses the vector but streams the matrix. Matrix warmth does not affect D8 traffic because this configuration has no matrix-local storage.
- Only the CIM configurations benefit from a warm matrix.
- The D8 cold-vector count assumes response bypass: each of the 16 newly filled entries supplies its first MAC directly, leaving \(512 - 16 = 496\) actual vector-buffer reads.
- For CIM, the vector must be assembled before the VMM invocation, so a cold vector incurs 16 buffer writes followed by 16 reads.
- Do not multiply one NeuroSim VMM result by 512. NeuroSim models the parallel array activity. Record both **1 array invocation** and **512 logical MAC-equivalents**.

## Cost Ownership

| Event or cost | Event-count owner | Latency / energy owner | Accounting rule |
|---|---|---|---|
| CPU instructions and control | OpenCoreX | OpenCoreX RTL/synthesis model | Includes launch-code execution, not accelerator busy time |
| MMIO reads and writes | OpenCoreX | OpenCoreX | Never send MMIO traffic to NeuroSim or PiMulator as DRAM traffic |
| Accepted logical vector, matrix, and output requests | OpenCoreX | PiMulator | OpenCoreX supplies request type, address, size, and issue time |
| Physical DRAM commands | PiMulator | PiMulator | Includes row activation, burst transfer, refresh, queueing, and contention |
| PiMulator allocation and writeback traffic | PiMulator | PiMulator | Extra physical traffic; do not duplicate it in OpenCoreX counters |
| D8 vector-buffer accesses | OpenCoreX | OpenCoreX SRAM/macro model | Exclude from NeuroSim unless NeuroSim is deliberately selected as the sole SRAM cost model |
| CIM input/vector buffer | OpenCoreX | NeuroSim as a separate SRAM structure | Keep separate from the compute array cost |
| D0-32 MUL and ADD | OpenCoreX | OpenCoreX RTL/synthesis model | Count actual scalar operations |
| D8 digital MAC | OpenCoreX | OpenCoreX RTL/synthesis model | NeuroSim must not price an ordinary digital MAC |
| SRAM-CIM array programming | OpenCoreX | NeuroSim | 512 logical 8-bit weight writes when cold |
| RRAM-CIM programming | OpenCoreX | NeuroSim | NeuroSim owns pulses, verification, latency, energy, and endurance implications |
| SRAM/RRAM VMM invocation | OpenCoreX | NeuroSim | One invocation because the full matrix fits in one mapping |
| Output conversion/readout | OpenCoreX issues logical result collection | NeuroSim | ADC, sensing, accumulation, and peripheral activity remain inside the NeuroSim event |
| Accelerator busy cycles | OpenCoreX | Integrated timeline | Measure from accepted `START` through final output-write acceptance |
| CPU wait cycles | OpenCoreX | Integrated timeline | Count only cycles in which the CPU is actively denied progress because of PIM busy |
| Area | OpenCoreX for controller/digital logic; NeuroSim for memory arrays | Same respective owner | Do not include the same SRAM structure in both reports |

## Required Counters

These should eventually be implemented as 64-bit testbench counters.

```text
mmio_read_count
mmio_write_count

ext_vector_read_elements
ext_vector_read_beats
ext_matrix_read_elements
ext_matrix_read_beats
ext_output_write_elements
ext_output_write_beats

vector_buffer_read_count
vector_buffer_write_count
vector_response_bypass_count

matrix_program_count
digital_mul_count
digital_add_count
digital_mac_count
cim_vmm_count
logical_mac_equivalent_count

accelerator_busy_cycles
cpu_pim_wait_cycles
memory_backpressure_cycles
matrix_residency_hit_count
vector_residency_hit_count
```