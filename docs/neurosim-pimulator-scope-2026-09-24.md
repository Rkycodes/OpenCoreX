# NeuroSim and PiMulator Scope Note

**Prepared for:** September 24, 2026 morning scope session  
**Status:** Working scope note; the digital-baseline/CIM-variant split is accepted, while detailed tool roles remain subject to advisor confirmation  
**Related documents:** `pim-architecture-v0.1.md`, `pim-module-interfaces-v0.1.md`

## Why this review comes next

The functional OpenCoreX architecture is defined far enough to establish its
research boundary before more RTL is written. The immediate question is not
whether NeuroSim and PiMulator are useful; both are. The question is which
part of the system each tool owns so that OpenCoreX does not duplicate or
double-count their models.

Professor Yang's confirmed direction is to:

- keep traffic and scheduling central to OpenCoreX,
- inspect both established tools and identify what OpenCoreX adds,
- account for NeuroSim's assumptions about movement between arrays and
  subarrays,
- begin NeuroSim with SRAM and then extend to RRAM, ideally covering both, and
- defer the detailed evaluation plan until the next meeting.

## Primary-source capability comparison

| Dimension | PiMulator | NeuroSim (2D Inference V1.4) |
|---|---|---|
| Primary purpose | FPGA-synthesizable emulation and prototyping of PIM memory organizations | Device-to-algorithm hardware estimation for DNN compute-in-memory accelerators |
| Model form | Parameterized SystemVerilog memory soft core, testbenches, configuration/generation scripts | PyTorch workload wrapper plus C++ analytical/circuit models |
| Modeled hierarchy | DDR-style DIMM/chip/bank-group/bank organization, shared data bus, row buffer, and subarrays; PIM kernels may be placed at different hierarchy levels | Memory cell and peripheral circuits through subarray, processing element, tile, and chip; global/tile/PE buffers and chip interconnect are modeled |
| Timing | Component state and command timing, memory latency, bank state, burst reads/writes, refresh, and bank interleaving | Synchronous or asynchronous operation; sensing-derived clock option; layer and chip latency with separate buffer, interconnect, sensing/ADC, accumulation, and other-periphery breakdowns |
| Array/device technology | DDR-family behavioral structure and timing intended for FPGA emulation; not a transistor/device model of SRAM versus RRAM | Selectable SRAM, RRAM, or FeFET cells; CMOS-access, BJT-access, diode-access, or crossbar arrangements; technology nodes from 130 nm through 1 nm in V1.4 |
| Interconnect and buffers | Shared data bus and memory hierarchy behavior | X-Y bus or H-tree; global, tile, and PE buffers selectable as register file or SRAM in the examined branch |
| Outputs | RTL simulation behavior and FPGA synthesis/resource/timing results; architecture-specific emulation results | Area, latency, dynamic energy, leakage, throughput, and energy-efficiency estimates with component breakdowns |
| Workload boundary | Memory commands and inserted PIM kernels; the published model emphasizes bitwise-PIM examples | DNN layers, weights, and activation traces mapped through the NeuroSim accelerator hierarchy |
| System boundary | A memory/PIM soft core. The repository says full-system integration is still in progress | A hardware-estimation framework, not CPU RTL, a cache-coherence model, or a cycle-accurate CPU/PIM shared-memory arbiter |

### PiMulator details that matter to OpenCoreX

PiMulator explicitly models a DDR-family hierarchy and behavior. The visible
SystemVerilog structure includes `DIMM`, `Chip`, `BankGroup`, `Bank`, timing
FSMs, and a bank array. Its documentation also names the shared data bus, row
buffer, subarrays, latency, bank states, burst reads/writes, refresh, and bank
interleaving. PIM kernels can be inserted at different points in that
hierarchy.

This makes PiMulator relevant to OpenCoreX's external memory traffic and
scheduling questions. It is not currently a drop-in replacement for the
OpenCoreX PIM controller: its published examples center on memory/PIM
emulation and bitwise PIM, while OpenCoreX currently specifies a blocking,
MMIO-launched, signed 32-bit matrix-vector MAC engine with a private vector
scratchpad. The repository also labels full-system integration as work in
progress.

### NeuroSim details that matter to OpenCoreX

NeuroSim V1.4 supports SRAM, RRAM, and FeFET; conventional sequential and
parallel modes; partial row activation; synchronous/asynchronous operation;
pipelined/layer-by-layer execution; multiple technology nodes; and X-Y or
H-tree global interconnect. The examined configuration also distinguishes
global, tile, and PE buffers from the compute memory array.

The tool reports chip and layer latency, area, dynamic energy, leakage, and
performance. Its output separates buffer and interconnect contributions and
breaks the compute path into sensing/ADC, accumulation, and other peripheral
circuits. These internal contributions are exactly why OpenCoreX must define
an accounting boundary before combining results.

The largest modeling mismatch is important: selecting "SRAM" in NeuroSim can
mean an SRAM compute-in-memory array, while the currently planned OpenCoreX
SRAM structure is a private vector scratchpad feeding a digital MAC. NeuroSim
also has separate SRAM/register-file buffer models. The scope session should
decide whether Professor Yang wants NeuroSim to represent the scratchpad, the
compute array, or a future CIM realization of the PIM engine.

## Recommended responsibility boundary

This is an engineering recommendation, not yet an advisor decision.

## Accepted CIM-variant direction

- The streamed signed-32-bit digital MAC remains the functional baseline.
- SRAM-CIM and RRAM-CIM are separately named architectural variants.
- A programmed matrix remains resident across commands until invalidation,
  replacement, or reset.
- Evaluation includes both cold execution with matrix programming and warm
  execution with a resident matrix.
- The private vector scratchpad remains SRAM in both CIM variants. The matrix
  compute array changes from SRAM to RRAM.
- The CIM study targets 8-bit inference.
- The first SRAM/RRAM experiment holds mapping and parallelism constant; later
  technology-specific optimized configurations are reported separately.
- NeuroSim PPA initially remains separate from RTL cycle timing.
- The CIM variants reuse the MMIO launch/status model and add matrix-load and
  residency controls; no ISA extension is required at this stage.
- CIM arithmetic is signed 8-bit by signed 8-bit with signed 32-bit
  accumulation and signed 32-bit initial outputs. Scaling, activation, and
  requantization are deferred.
- A separate `D8` digital configuration will provide a precision-matched
  evaluation reference without replacing the original `D0-32` baseline.
- The first CIM design holds one resident matrix. A blocking `LOAD_MATRIX`
  operation fetches it through the shared memory port while the CPU waits.
- Matrix-residency metadata records validity, source base address, rows,
  columns, source stride, and precision.
- A replacement load invalidates the prior matrix immediately. Validity is
  restored only after the final programming operation completes; atomic
  double-buffered replacement is deferred.
- Evaluation reports four residency cases: neither matrix nor vector resident,
  matrix only, vector only, and both resident.
- The first mapping is the existing `16 x 32` matrix-vector microbenchmark;
  a realistic inference layer or small network follows after the methodology
  is validated.
- A version-2 MMIO opcode adds `LOAD_MATRIX`, `COMPUTE`, and
  `INVALIDATE_MATRIX` without changing the version-1 digital command encoding.
- The matrix loader accepts the existing column-major source layout and maps it
  into the selected internal array organization.
- Load completion means external fetching and internal programming are both
  complete and `matrix_valid` is set.
- A compute command with missing or mismatched resident metadata is atomically
  rejected with `MATRIX_NOT_RESIDENT` and creates no data traffic.
- Reset clears matrix validity and metadata but need not physically clear the
  array cells.

The 8-bit choice creates an evaluation requirement: the 8-bit CIM variants
cannot be claimed as direct replacements for the existing signed-32-bit
baseline based on raw results alone. A matched 8-bit digital reference, or a
carefully limited technology-only comparison, is required before making
cross-architecture speedup or efficiency claims.

### OpenCoreX owns

- the CPU-visible MMIO command and status interface,
- CPU blocking from accepted start through final write-back,
- descriptor validation and error behavior,
- round-robin arbitration and the shared one-request memory port,
- vector fill, per-entry validity, reuse, and scratchpad occupancy,
- scheduling of vector reads, matrix reads, MAC operations, and output writes,
- cycle/event counters for requests, stalls, reuse, and CPU idle time, and
- end-to-end functional correctness against the CPU baseline.

### NeuroSim supplies

- SRAM-first, then RRAM, estimates for a clearly declared physical structure,
- internal array/peripheral/buffer/interconnect area, latency, and energy, and
- technology-sensitive comparison data that functional RTL alone cannot
  provide.

### PiMulator supplies

- a reference implementation for a parameterized DDR-style memory hierarchy,
- detailed memory-state and timing behavior for later traffic experiments,
- examples of where PIM logic can be placed within a memory hierarchy, and
- a possible later replacement or co-simulation model behind the OpenCoreX
  memory-request boundary.

### Double-counting rule

Use one owner for each latency or energy contribution.

- If PiMulator produces the response time for an OpenCoreX memory request, do
  not also add the current synthetic RAM delay for that same request.
- If a NeuroSim result already includes array, local buffer, interconnect, and
  accumulation latency or energy, do not separately add those same internal
  components as OpenCoreX compute cost.
- OpenCoreX may still count the request once as traffic while another tool
  determines its timing or energy. Event count and modeled cost are different
  quantities, but the event must not be charged twice.

A clean long-term experiment boundary would be:

```text
OpenCoreX command/scheduler
        |
        +-- emits external-memory request trace --> current RAM model OR PiMulator
        |
        +-- emits compute invocation -----------> NeuroSim-derived cost model
```

This keeps OpenCoreX's novel traffic/scheduling behavior visible without
claiming that its simple RTL recreates either established tool.

## Recommended scope for the next implementation interval

1. Keep the current streamed digital-MAC OpenCoreX architecture as the named
   functional baseline. Do not replace its controller or scratchpad with
   either tool.
2. Treat PiMulator as a reference and prospective memory-backend model during
   the first interval, not as a required integration dependency.
3. Use NeuroSim for two separately reported physical roles: characterization
   of local storage and characterization of a matrix-resident CIM array.
   Never combine them into an unlabeled aggregate result.
4. Use SRAM for the first controlled configuration, then change only the
   declared technology/mapping variables needed for the RRAM comparison.
5. Record the translation between the OpenCoreX `1 x 16` by `16 x 32`
   workload and NeuroSim's layer/array mapping. Do not present a default DNN
   network result as if it were the OpenCoreX workload.
6. Preserve the existing variable-latency request/response boundary so a
   PiMulator-backed memory path can be explored later without redesigning the
   PIM controller.

## Questions for the September 24 morning scope session

These questions are ordered so the first answers constrain the later ones.

1. **What does “incorporate” mean for each tool?** Must both tools be directly
   integrated, or may one provide parameters/reference behavior while the
   other participates in quantitative experiments?
2. **What physical structure should NeuroSim represent first?** The private
   vector scratchpad, an SRAM compute-in-memory array, or the entire PIM
   datapath? These are not equivalent models.
3. **Is the intended OpenCoreX PIM architecture still a digital MAC near
   memory, or should it evolve toward SRAM/RRAM compute in the array?** This
   determines whether NeuroSim is a characterization tool or an architectural
   target.
4. **Which NeuroSim branch and mode should be the project baseline?** Is
   2DInference V1.4 with `memcelltype=SRAM` and conventional parallel mode
   acceptable, or is the newer digital-CIM branch preferred?
5. **For the SRAM-to-RRAM comparison, what remains fixed?** Logical array
   capacity and workload, subarray dimensions and parallelism, accuracy, or an
   independently optimized design for each technology?
6. **Where should PiMulator attach?** Behind OpenCoreX's memory adapter as the
   source of response timing, as reusable hierarchy RTL, or only as a
   comparison/reference model during the first phase?
7. **Which data movement is OpenCoreX allowed to count?** Proposed answer:
   count traffic crossing the CPU/PIM/shared-memory boundary in OpenCoreX;
   leave movement within NeuroSim arrays, buffers, and interconnect to
   NeuroSim, and leave modeled DDR-internal movement to PiMulator.
8. **How should time domains be reconciled?** Should nanosecond estimates from
   NeuroSim become a fixed/variable compute latency at the OpenCoreX clock, or
   remain a separate PPA result beside cycle-level RTL measurements?
9. **Is PiMulator's bitwise-PIM emphasis part of the desired design space?**
   If yes, it represents a different compute organization from the current
   32-bit MAC and should be treated as an explicit alternative, not silently
   mixed into the baseline.
10. **What deliverable is expected by the October 7 sync?** A tool-capability
    matrix and justified boundary, first reproducible SRAM NeuroSim run, a
    PiMulator smoke test, an OpenCoreX integration proposal, or some subset?

## Proposed answers to carry into the meeting

- Keep OpenCoreX's contribution centered on measurable CPU/PIM traffic,
  scheduling, buffer reuse, and blocking execution behavior.
- Preserve the streamed digital-MAC system as the baseline. Add the
  matrix-resident SRAM-CIM and RRAM-CIM organizations as explicitly named
  architectural variants, with their matrix-programming and reuse traffic
  reported separately.
- Start with NeuroSim 2D Inference V1.4 only as a provisional baseline because
  it explicitly supports both SRAM and RRAM and exposes buffer/interconnect
  breakdowns. Confirm the branch with Professor Yang before building the
  evaluation around it.
- Model SRAM and RRAM with the same logical OpenCoreX workload and report every
  changed physical assumption.
- Use PiMulator first to learn and validate memory hierarchy/timing choices;
  postpone direct coupling until the request/response translation and value to
  the research question are clear.
- Do not change the already agreed OpenCoreX MMIO, blocking handshake,
  scratchpad, or single-outstanding-read decisions solely to resemble either
  external tool.

## Primary sources reviewed

- [PiMulator repository](https://github.com/hplp/PiMulator)
- [PiMulator wiki](https://github.com/hplp/PiMulator/wiki)
- [PiMulator getting started](https://github.com/hplp/PiMulator/wiki/Getting-started)
- [PiMulator SystemVerilog model](https://github.com/hplp/PiMulator/tree/main/PiMulator/SysVerilog_Model)
- [NeuroSim repository and branch index](https://github.com/neurosim/NeuroSim)
- [DNN+NeuroSim 2D Inference V1.4](https://github.com/neurosim/NeuroSim/tree/2DInferenceV1.4)
- [NeuroSim V1.4 parameters](https://github.com/neurosim/NeuroSim/blob/2DInferenceV1.4/Inference_pytorch/NeuroSIM/Param.cpp)
- [NeuroSim V1.4 hardware estimator](https://github.com/neurosim/NeuroSim/blob/2DInferenceV1.4/Inference_pytorch/NeuroSIM/main.cpp)
