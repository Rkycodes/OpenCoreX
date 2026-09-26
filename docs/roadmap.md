# OpenCoreX Roadmap

## v0.1 — Simulation-Only Multicycle RV32I Subset Core (Completed: September 11, 2026)

### Architecture
- [x] Define processor architecture
- [x] Select initial 10-instruction RV32I subset
- [x] Complete datapath design
- [x] Document datapath behavior and control signals
- [x] Finalize all datapath MUX encodings
- [x] Audit FSM control outputs state-by-state

### RTL
- [x] Define module interfaces
- [x] Implement primitive RTL modules
- [x] Integrate datapath
- [x] Implement controller FSM
- [x] Integrate complete processor

### Verification
- [x] Develop module-level testbenches
- [x] Verify supported instructions
- [x] Run full processor regression
- [x] Validate example programs
- [x] Automate local regression and lint with `make verify`

## Research Direction — Decisions through September 24, 2026

The next phase of OpenCoreX is benchmark-driven PIM research rather than completing full RV32I or RV32M first.

- The PIM block will begin as a coprocessor-style unit controlled by the CPU.
- Version 1 uses memory-mapped configuration, command, status, and capability registers; it does not require a PIM-specific ISA extension.
- An accepted `START` store launches one blocking command. The CPU remains idle until the PIM completes its final result write or rejects the command.
- The PIM uses a private, parameterized local vector buffer with a default capacity of 16 words and a one-port synchronous interface.
- Vector fill may overlap computation. A response-bypass path supplies a newly returned vector word directly to compute while storing it locally.
- Version 1 permits one outstanding PIM read and one MAC lane. Multiple outstanding reads, multiple lanes, chunking, tiling, nonblocking execution, and interrupts are later extensions.
- Results are written to the programmed output region, and `done` is set only after the final output-write handshake.
- The existing round-robin interconnect remains the baseline, and PIM control tolerates variable request and response latency even though the current RAM adapter responds in one cycle.
- The initial accelerated operation will be coarse-grained dot-product / matrix-vector work rather than individual PIM multiply/add instructions.
- The first agreed benchmark is a `1 x 16` vector multiplied by a `16 x 32` matrix.
- The CPU reference implementation will add scalar `MUL` and only other ISA features that materially simplify or enable the benchmark.
- Additional loop and branch instructions may be added when they reduce benchmark complexity, but completing full RV32I is not a prerequisite for PIM work.
- NeuroSim exploration begins with SRAM and then extends to RRAM if feasible. PiMulator remains under investigation for compatible memory-system modeling or reuse.
- OpenCoreX owns external traffic, arbitration, and scheduling measurements; tool-internal movement must not be counted twice.
- Evaluation must include offload overheads rather than measuring PIM compute in isolation.
- The detailed evaluation plan remains deferred until the next advisor meeting.
- Dot product is the required initial deliverable. ReLU and softmax support are possible later extensions toward neural-network inference.

## Research Milestone 1 — CPU Reference

Goal: establish a correct and measurable scalar baseline for the exact workload that the PIM unit will accelerate.

- [x] Define the scalar algorithm and memory layout for `1 x 16` by `16 x 32` matrix-vector multiplication
- [x] Determine the minimum benchmark-driven ISA additions
- [x] Implement and verify scalar `MUL`
- [x] Add loop/branch control instructions only if they materially simplify the benchmark
- [x] Write and verify the CPU-only matrix-vector benchmark
- [x] Verify all 32 output values against a software reference
- [x] Instrument total cycles
- [x] Instrument or derive instruction count
- [x] Record loads, stores, multiplies, additions, and total memory traffic
- [x] Establish cycles per output and cycles per dot product

## Research Milestone 2 — PIM Architecture and Control Contract

Goal: define the CPU-to-PIM contract, local-buffer behavior, and verification boundary before writing integrated PIM RTL.

### Phase 1 — Shared-memory transport

- [x] Define CPU and PIM request/response channel semantics
- [x] Add requester-local `valid`/`ready` backpressure
- [x] Implement two-requester round-robin memory arbitration
- [x] Lock the selected requester while downstream memory is stalled
- [x] Route fixed-latency read responses to the requesting owner
- [x] Adapt the existing synchronous RAM to the handshake interface
- [x] Migrate CPU fetches, loads, and stores to the handshake interface
- [x] Keep physical RAM external to the CPU/PIM subsystem wrapper
- [x] Define interface-reset behavior and preserve RAM across reset
- [x] Verify CPU/PIM contention and CPU request stability during stalls
- [x] Verify that an idle PIM requester adds no matrix-vector baseline cycles
- [x] Document the Phase 1 shared-memory interface and limitations

### Phase 2 — PIM command and software contract (architecture complete)

- [x] Select MMIO configuration and launch without a version-1 PIM ISA extension
- [x] Define vector, matrix, stride, output, and count fields
- [x] Define command, status, capability, error, clear, and buffer-control registers
- [x] Define a single outstanding blocking command
- [x] Define CPU idle behavior from accepted `START` through final write-back
- [x] Define sticky `done`, sticky first-fault `error_code`, and write-one-to-clear behavior
- [x] Define atomic sequential validation and deterministic error priority
- [x] Define private vector-buffer capacity, valid metadata, reuse, and invalidation
- [x] Define one outstanding read and variable-latency-safe request/response sequencing
- [x] Define output placement and final-write completion semantics
- [x] Define reset behavior, including persistence of already accepted RAM writes
- [x] Reserve nonblocking execution, interrupts, memory-fault responses, multiple reads, multiple lanes, and tiling for later versions
- [x] Define the initial verification strategy and parameter corner cases

The version-1 contract is specified in [`pim-architecture-v0.1.md`](pim-architecture-v0.1.md).

## Research Milestone 3 — Functional PIM RTL

Goal: build a synthesizable, technology-independent PIM prototype and run the same workload used by the CPU baseline.

- [x] Finalize module port lists and cycle-level MMIO timing
- [x] Preserve `opencorex_memory_subsystem` as the Phase 1 transport baseline
- [x] Add a new integrated PIM subsystem and CPU RAM/MMIO address-routing boundary
- [x] Implement and verify `pim_mmio_regs`
- [x] Implement and verify the sequential command validator
- [x] Implement and verify the one-port synchronous vector buffer
- [x] Implement and verify the one-lane MAC using the CPU arithmetic semantics
- [x] Implement and verify the PIM controller and response-bypass path
- [x] Integrate the PIM requester with the existing round-robin memory interconnect
- [ ] Verify randomized request stalls and 1–20-cycle read-response delays
- [ ] Verify blocking CPU launch, completion, rejection, reuse, invalidation, and reset
- [ ] Execute the `1 x 16` by `16 x 32` benchmark through the PIM path
- [ ] Verify PIM results against the CPU/software reference

The CPU-driven PIM benchmark program is the next Milestone 3 step. The new subsystem already preserves the CPU-only 32-output, 23,685-cycle reference.

## Research Milestone 4 — Characterization and CPU-vs-PIM Evaluation

Goal: compare the complete CPU and PIM execution paths using a fair system boundary.

- [ ] Investigate NeuroSim outputs and identify usable latency, energy, power, and area parameters
- [ ] Investigate relevant device papers for parameter validation
- [ ] Investigate PiMulator scope and determine whether any component should be reused
- [ ] Account for operand placement cost
- [ ] Account for MMIO configuration and launch overhead
- [ ] Account for synchronization/wait overhead
- [ ] Account for memory traffic and result readback
- [ ] Compare total latency/cycles
- [ ] Compare throughput
- [ ] Compare power and energy
- [ ] Compare energy efficiency
- [ ] Compare area consumption
- [ ] Compare area-normalized efficiency where meaningful
- [ ] Identify when PIM acceleration is compute-bound versus data-movement-bound

## Research Milestone 5 — Neural-Network and Compact-PIM Extensions

Goal: extend the validated dot-product platform only after the baseline comparison is trustworthy.

- [ ] Add ReLU support if required by the selected inference workload
- [ ] Investigate practical softmax support and whether it belongs on CPU or PIM
- [ ] Select a small neural-network inference workload
- [ ] Explore fixed-point precision choices
- [ ] Model limited PIM capacity and weight reloads
- [ ] Study batch-size effects and data reuse
- [ ] Study memory traffic and data-movement overhead
- [ ] Explore scheduling, partitioning, and utilization
- [ ] Compare compact-PIM behavior against the CPU baseline and appropriate reference systems

## Supporting CPU Development

These remain valuable OpenCoreX directions, but they are secondary to the research milestones unless they directly support the benchmark.

- [ ] Additional useful RV32I instructions
- [ ] Additional RV32M instructions if justified by workloads
- [ ] GitHub Actions CI
- [ ] Additional architectural assertions
- [ ] FPGA implementation
- [ ] Pipelined CPU
- [ ] Caches
- [ ] AXI4-based interconnect
- [ ] UART and other FPGA peripherals
