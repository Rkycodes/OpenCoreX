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
- [x] Automate local regressio and lint with `make verify`

## Research Direction — Decisions from September 7, 2026 Sync

The next phase of OpenCoreX is benchmark-driven PIM research rather than completing full RV32I or RV32M first.

- The PIM block will begin as a coprocessor-style unit controlled by the CPU.
- The initial control protocol will use explicit `start`, `busy`, and `done` behavior.
- The CPU will decode custom PIM instructions using `opcode`, `funct3`, and `funct7` and issue commands to the PIM unit.
- The initial accelerated operation will be coarse-grained dot-product / matrix-vector work rather than individual PIM multiply/add instructions.
- The first agreed benchmark is a `1 x 16` vector multiplied by a `16 x 32` matrix.
- The CPU reference implementation will add scalar `MUL` and only other ISA features that materially simplify or enable the benchmark.
- Additional loop and branch instructions may be added when they reduce benchmark complexity, but completing full RV32I is not a prerequisite for PIM work.
- PIM timing, power, energy, and area parameters should be grounded in NeuroSim and relevant device literature rather than arbitrary constants.
- PiMulator should be investigated for scope and possible reuse, but OpenCoreX is not committed to adopting it until its role is understood.
- Evaluation must include offload overheads rather than measuring PIM compute in isolation.
- Required comparison metrics include operand placement, instruction issue, memory traffic, synchronization, result readback, cycles/latency, throughput, power, energy efficiency, and area.
- Dot product is the required initial deliverable. ReLU and softmax support are possible later extensions toward neural-network inference.

## Research Milestone 1 — CPU Reference

Goal: establish a correct and measurable scalar baseline for the exact workload that the PIM unit will accelerate.

- [ ] Define the scalar algorithm and memory layout for `1 x 16` by `16 x 32` matrix-vector multiplication
- [ ] Determine the minimum benchmark-driven ISA additions
- [ ] Implement and verify scalar `MUL`
- [ ] Add loop/branch control instructions only if they materially simplify the benchmark
- [ ] Write and verify the CPU-only matrix-vector benchmark
- [ ] Verify all 32 output values against a software reference
- [ ] Instrument total cycles
- [ ] Instrument or derive instruction count
- [ ] Record loads, stores, multiplies, additions, and total memory traffic
- [ ] Establish cycles per output and cycles per dot product

## Research Milestone 2 — PIM Architecture and ISA

Goal: define the CPU-to-PIM contract before writing integrated PIM RTL.

- [ ] Select a custom opcode/funct encoding
- [ ] Define the first coarse-grained PIM command semantics
- [ ] Define how source operands and addresses are supplied
- [ ] Define destination/result placement
- [ ] Define `start`, `busy`, and `done` protocol timing
- [ ] Define CPU behavior while a PIM operation is active
- [ ] Define memory ownership and arbitration between CPU and PIM
- [ ] Define architectural state visible to software
- [ ] Define error and reset behavior for an in-flight PIM operation

## Research Milestone 3 — Functional PIM RTL

Goal: build a synthesizable, technology-independent PIM prototype and run the same workload used by the CPU baseline.

- [ ] Implement standalone PIM controller
- [ ] Implement the initial dot-product / matrix-vector datapath
- [ ] Verify PIM arithmetic independently
- [ ] Verify variable-latency `start` / `busy` / `done` behavior
- [ ] Integrate custom-instruction decode into OpenCoreX
- [ ] Integrate the PIM coprocessor with the CPU
- [ ] Add required memory arbitration
- [ ] Execute the `1 x 16` by `16 x 32` benchmark through the PIM path
- [ ] Verify PIM results against the CPU/software reference

## Research Milestone 4 — Characterization and CPU-vs-PIM Evaluation

Goal: compare the complete CPU and PIM execution paths using a fair system boundary.

- [ ] Investigate NeuroSim outputs and identify usable latency, energy, power, and area parameters
- [ ] Investigate relevant device papers for parameter validation
- [ ] Investigate PiMulator scope and determine whether any component should be reused
- [ ] Account for operand placement cost
- [ ] Account for custom-instruction issue overhead
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
