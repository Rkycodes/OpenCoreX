# OpenCoreX Development Log

## 2026-07-07
- Defined OpenCoreX as a long-term CPU, RTL, verification, FPGA, ASIC, and PIM project.
- Chose a multicycle RV32I processor as the first milestone.

## 2026-07-18
- Set up the development environment.
- Installed and verified Git, Verilator, Make, GCC, Python, GTKWave, VS Code, and WSL.
- Created and organized the GitHub repository.

## 2026-07-19
- Defined the initial processor scope and supported instruction subset.
- Began documenting the architecture and multicycle execution model.

## 2026-07-20
- Defined the main datapath registers, memory behavior, and register-file behavior.
- Established reset and illegal-instruction handling.

## 2026-07-21
- Defined ALU operations, ALU decoding, and major control signals.
- Continued developing the FSM and instruction execution paths.

## 2026-07-23
- Reviewed the earlier 8-bit CPU project and verification workflow.
- Used lessons from that project to guide OpenCoreX organization and testing plans.

## 2026-07-25
- Continued the OpenCoreX architecture specification.
- Created the datapath diagram.
- Connected datapath registers, memory, register file, ALU, and control paths.

## 2026-07-26
- Added and reviewed datapath write-enable controls.
- Clarified memory-read, memory-write, and register-write behavior.

## 2026-07-27
- Audited datapath connections.
- Clarified the PC input path, ALU result path, and constant-four path.

## 2026-07-28
- Completed the full datapath diagram.
- Reviewed the diagram for missing or incorrect connections.
- Committed and pushed the completed datapath.

## 2026-07-29
- Finalized all five datapath MUX-select encodings.
- Documented the encodings in `architecture.md`.
- Created the project roadmap.
- audited FSM control outputs state by state before writing RTL.
- created this here devlog document!

## 2026-07-30
- Finalized FSM Control
- Audited `architecture.md` for mistakes and conflicts and resolved them.
- begin RTL Module boundaries.
- Decided that OpenCoreX v0.1 is changing to be synchronous, one cycle latency memory interface now so that FPGA integration is more seamless, avoids restructuring `FETCH` and load timing. Lots of rework to architecture.md required.

## 2026-07-31
- More fixing of architecture.md
 - re did FSM control (added 2 FSM States)
 - re did datapath
 - updated mermaid diagram in `architecture.md`
 - all of this had to be redone because of the decision to use synchronous memory for later FPGA implementation and to ease incorporation of different memory blocks; I think it will save time.
 - this took all day. very frustrating, need to be better about defining requirements in the future so I do not have to go back and change things.

## 2026-08-01
- Completed ALU rtl

## 2026-08-02
- Completed ALU testbench (11 Tests)

## 2026-08-03
- completed ALU decoder + ALU decoder testbench

## 2026-08-05
- completed immediate generator + immediate generator testbench
- testbench was a little longer than I meant it to be but it was similar to decoder testbench so it was not too bad to write out.

## 2026-08-06
- complete register file rtl + tb
- reg file rtl was not bad at all, testbench kicked my butt again, long testbench
- dreading making the controller and cpu, I already know those testbenches are going to be 400+ lines

## 2026-08-08
- completed memory rtl + passed lint

## 2026-08-09

- completed and verified the single-port synchronous memory module
- tested normal word-aligned reads and writes through the memory interface
- verified optional program/data initialization using `$readmemh`
- added tests for simultaneous read/write requests, misaligned addresses, and out-of-range accesses
- debugged a subtle initialization failure caused by the hex file missing a final newline (spent way too long on this)
- confirmed that all intended error cases trigger `$fatal` correctly
- memory RTL and standalone verification are now complete

## 2026-08-11

- began implementing the controller
- completed the 16 state enum and asynchronous reset state register
- drafted next state logic for arithmetic, memory, branch, jump, and error paths
- added full instruction encoding validation in the decode path
- next: fix remaining syntax issues, implement control outputs, and write the controller testbench

## 2026-8-13
- completed and linted 16-state multicycle controller RTL
- finished next state logic logic
- added legality checks for all 10 instructions
- bunch of syntax debugging
- next: build self checking testbench and verify all legal paths, illegal encoding, async reset, and sticky error behavior

## 2026-08-14

- began building the self-checking controller testbench
- added the controller signal declarations, DUT connections, and clock generator
- grouped all 19 controller outputs into one 23-bit packed control vector
- designed a reusable comparison task using `!==` to detect incorrect, unknown, or high-impedance outputs
- reviewed simulation timing, including settling delays and asynchronous-reset behavior
- next: implement the reset task, define expected state-control vectors, and test every legal and illegal instruction path

## 2026-08-15
- completed the reusable frameowrk for the contorller testbench
- implemented and verified async reset, reset state retenetion and post reset state progression
- passed complete path tests for arthmetic functions
- started working through LW and SW address, read, capture and write back + write
- next: implement LW and SW sequences then make BEQ, JAL, illegal error

## 2026-08-16
- finished the controller testbench
- added targeted tests for all 10 supported instructions
- verified async reset enters `FETCH` and holds while asserted
- added exhaustive decode testing across all 131,072 `{opcode, funct3, funct7}` combinations
  - 1,541 legal combos
  - 129,531 illegal combos
- verified illegal instructions enter `ERROR` without asserting memory, register or PC write controls
- Verified `ERROR` remains active even if the instruction inputs become legal
- Verified reset recovers controller from `ERROR` to `FETCH`
- All targeted and exhaustive tests passed in Verilator
- next: begin implementing `datapath.sv`

## 2026-08-22
- fully audited the datapath connections
- began implementing datapath rtl in `datapath.sv`

## 2026-08-23
- completed and linted the multicycle datapath RTL
- memory outside the datapath for connection at the CPU top level
- created a thoroughly commented, self checking datapath testbench
- passed 68/68 tests in verilator
- verified async reset, fetch sequencing, register hold behavior, instruction capture, operand capture, ALU execution, taken and untaken branches, memory paths, and all writeback sources
- verified that async datapath reset clears all eight ddatapath registers without erasing the register file
- next: integrate these in a cpu top module

## 2026-09-02
- it's been a while, school started and it has been busy
- audited the datapath_tb for verification coverage
- implemented `rtl/opencorex_core.sv` as a wrapper connecting the controller and datapath
- linted the core and came back clean
- next: build the `opencorex_core_tb.sv`, connect the core to synchrnous memory and execute complete v0.1 instructions to prove functionality

## Week of 2026-09-07
- completed the first full end-to-end verification of the OpenCoreX v0.1 processor
- connected `opencorex_core` to the external synchronous memory module
- created `programs/hex/integration_smoke.hex` to execute all 10 supported instructions
- verified final register values, stored memory data, branches, jumps, loads, stores, and the `RKYC` completion signature
- created a legal corner-case program covering negative immediates, negative arithmetic results, writes to `x0`, a not-taken `BEQ`, backward branches, and backward `JAL` with `rd = x0`
- created an illegal-instruction integration test that verifies entry into the sticky `ERROR` state without architectural side effects
- created a reset-during-execution test that verifies an in-flight instruction is cancelled and execution restarts correctly
- ran all 12 positive testbenches successfully
- validated all three expected-failure memory tests for simultaneous read/write, misaligned addresses, and out-of-range addresses
- completed warning-free Verilator lint with `-Wall` for both the CPU hierarchy and memory module
- completed the OpenCoreX v0.1 simulation-only multicycle RV32I subset milestone
- added a root `Makefile` and `scripts/verify.sh` for reproducible one-command verification
- verified that `make verify` runs lint, all 12 positive testbenches, and all three expected-failure memory tests

## 2026-09-13
- implemented and verified scalar RV32M `MUL` as the first benchmark-driven CPU extension after OpenCoreX v0.1
- assigned `ALUControl = 3'b101` to multiplication and implemented the lower 32 bits of the product
- added exact MUL decoding using `opcode = 0110011`, `funct3 = 000`, and `funct7 = 0000001`
- reused the existing `R_EXEC` and `ALU_WRITEBACK` states without adding datapath registers, control signals, or FSM states
- expanded the ALU testbench to 13 tests, covering positive multiplication, negative operands, truncation, and `Zero` behavior
- updated the ALU decoder testbench to verify MUL and reject nearby unsupported encodings
- updated the controller’s targeted and exhaustive verification
  - 1,542 legal encodings
  - 129,530 illegal encodings
  - 131,072 total encodings
- created `programs/hex/scalar_mul.hex` and documented it in `programs/scalar_mul.md`
- created `tb/opencorex_mul_tb.sv` for end-to-end MUL verification
- verified positive, negative, negative-times-negative, zero, low-word truncation, and `x0` destination behavior
- completed the scalar MUL integration test successfully at cycle 68
- added `opencorex_mul_tb` to the automated regression
- completed warning-free RTL lint and passed the full regression with 13 positive testbenches and three expected-failure memory tests
- preserved the original processor specification as `docs/architecture-v0.1.md`
- documented the multiplier architecture and research timing assumptions in `docs/scalar-mul-extension.md`

## 2026-09-14
- implemented BNE support using the existing branch target and sub paths
- added `BranchInvert` so that the datapath can ocnditionally update the PC for either equal or unequal comparisons
- reused the existing `BRANCH_TARGET` and `BRANCH_COMPARE` states without adding new FSM states
- updated controller verification
- verified all four BEQ and BNE outcomes
- next: update dot-product program to use BNE and build its e2e testbench.

## 2026-09-15
- Expanded controller and datapath tests to cover taken and untaken `BEQ` and `BNE` cases.
- Completed a 16-element signed dot product using scalar `MUL`, accumulating `ADD`, and a `BNE` loop.
- Verified the expected result of `206` (`0x000000CE`) in both `x4` and memory address `0x180`.
- Measured 135 instruction fetches, 16 executions each of `MUL`, `ADD`, and `BNE`, and 741 active cycles.
- Added the benchmark to the automated regression; RTL lint and all 14 positive testbenches pass.

## 2026-09-17

Completed the first CPU-only matrix-vector benchmark for the OpenCoreX study.

- added a deterministic mixed-sign 1x16 by 16x32 matrix vector workload: `y[j] = sum(x[i] * W[i][j])`.
- added an instruction-encoding generator that produces the executable memory image an an independently calculated 32-word software reference.
- Made the memory layout explicit: vector at `0x100`, column-major matrix at `0x140`, outputs at `0x940`, RKYC signature source at `0x9C0`, and completion destination at `0x9C4`.
- Added a dedicated self-checking testbench that verified outputs, final architectural state, input immutability, operation counts, and the completion write.
- Full regression passes. The test completes in 23,685 active cycles with 512 MUL ops, 512 accumulating ADD ops, 1024 kernel data reads, and 32 result writes

Key Observation: the CPU rereads the same 16-word vector once per output column, creating 512 vector-memory reads. The next research phase will study coordination and data movement required to reduce traffic by moving suitable/appropriate work closer to memory.

## 2026-09-19
- Calculated Derived metrics from CPU dot product experiment including:
  - Cycles per output
  - cycles per MAC
  - Average CPI
  - Instructions per putput
  - kernel data
  - total data traffic
  - instruction + data memory
  - unique workload
  - Redundant vector traffic
- Began to draft custom RISC-V instruction(s) for PiM block
- Defined PiM block reset behavior
- Working on memory ownership and arbitration for single-port synchronous unified memory between CPU and nonblocking PiM.
- Working on system block diagrams to get feedback from Prof. Yang on.

## Week of 2026-09-20
- Added a two-requester shared-memory interconnect for the CPU and future PIM engine.
- Added ready/valid request handshakes so arbitration and downstream backpressure can stall either requester safely.
- Implemented round-robin contention handling with grant locking while the selected request is stalled.
- Added read-response ownership tracking so synchronous memory responses return to the requester that issued the read.
- Added a synchronous-memory adapter with fixed one-cycle read responses and handshake-qualified memory enables.
- Migrated the CPU controller from the legacy direct-memory interface to request, acceptance, and response phases.
- Added `FETCH_CAPTURE` and `MEM_READ_CAPTURE` states so instruction and load data are written only when `mem_rsp_valid` is asserted.
- Added the integrated `opencorex_memory_subsystem` wrapper while keeping the physical RAM external.
- Verified CPU/PIM contention, backpressure, response routing, reset behavior, and preservation of RAM contents across reset.
- Verified that the inactive-PIM subsystem preserves the CPU matrix-vector baseline of 23,685 active cycles and 4,327 instruction fetches.
- Expanded the regression suite to 20 positive testbenches plus three expected-failure memory tests.I
- Finalized the version-1 PIM architectural contract before writing functional PIM RTL.
- Selected MMIO configuration and launch without a PIM-specific ISA extension.
- Defined a blocking CPU policy from the accepted `START` store through final PIM result write-back.
- Selected a private, power-of-two vector buffer with `BUFFER_WORDS=16` by default.
- Selected one synchronous read-or-write buffer port with a response-bypass path for newly returned vector operands.
- Defined internal per-entry validity plus software-visible `valid_count` and `vector_full` status.
- Defined explicit vector reuse, resident base/length matching, and idle-only invalidation.
- Selected one outstanding PIM read and one MAC lane for the initial implementation.
- Defined signed 32-bit CPU-matching multiplication and modulo-`2^32` accumulation.
- Defined MMIO command, status, capability, error, clear, and buffer-control behavior.
- Defined sequential atomic validation, deterministic first-fault priority, and half-open address-range checks.
- Retained the existing round-robin, single-port shared-memory transport.
- Defined completion as acceptance of the final output write and reset as non-transactional: accepted RAM writes persist.
- Defined module-level verification, golden arithmetic comparison, randomized 1–20-cycle response delay, parameter sweeps, reset injection, protocol assertions, and reuse tests.
- Preserved `opencorex_memory_subsystem` as the verified Phase 1 baseline and selected a separate PIM integration top for the next milestone.
- Recorded the version-1 architecture in `docs/pim-architecture-v0.1.md`.
- Added parameterized cpu_address_router to decode CPU requests between RAM and the PIM MMIO page.
- Defined half-open address windows for RAM and MMIO using widened arthmetic to prevent 32-bit range clculations from warpping.
- Added simulation time checks that reject zero-sized or overlapping address windows
- Kept address decoding separate from target validation: misaligned RAM accesses, misaligned MMIO accesses, and reserved MMIO offsets are forwarded to the selected target for validation.
- Added blocking behavior so pim_busy and an outstanding CPU read prevent new CPU requests from reaching either destination
- Preserved START-store retirement by allowing the MMIO write to complete before the PIM block raises its registered busy signal.
- Added support for one outstanding CPU read with registered response-source ownership, ensuring delayed RAM and MMIO responses return from the destination that accepted the request.
- Ensured writes do not create pending read state or overwrite response ownership.
- Allowed an already-owned CPU response to complete while pim_busy is asserted.
- Added safe reset behavior that clears pending ownership, suppresses visible protocol outputs, and ignores late responses from pre-reset transactions.
- Added simulation failure behavior for unmapped CPU addresses while keeping synthesized behavior non-forwarding because version 1 has no architectural access-fault response.
- Added protocol assertions for mutually exclusive destination selection, blocked-request enforcement, stable stalled payloads, and response routing by recorded ownership.
- Added cpu_address_router_tb coverage for RAM/MMIO boundaries, reserved MMIO offsets, target backpressure, START-to-busy timing, delayed responses, response-source isolation, writes, reset during a pending read, and unmapped accesses.
- Expanded the regression suite to 21 positive testbenches and four expected-failure tests.
- Completed the full make verify regression with Verilator 5.032; all RTL lint, positive tests, and expected-failure tests passed.
- Preserved the existing Phase 1 memory interconnect, synchronous-memory adapter, and memory subsystem without modification.

## 2026-09-25

- Began Research Milestone 3 on `feat/pim-mmio` from remote `main` at `d11ff76`.
- Added `pim_pkg.sv` for the six-field descriptor, error codes, MMIO offsets, and architectural bit positions. Parameter-derived values remain local to modules.
- Added `pim_mmio_regs.sv` with six configuration registers, registered read responses, sticky status and first-fault code, accepted-edge `START`, W1C status, capabilities, and idle-only buffer invalidation.
- Resolved the `START=0` command-bit gap: MMIO records reserved-bit or unsupported-mode errors without launching the validator. Reserved bits have priority.
- Defined writes to reserved interrupt registers as simulation-fatal invalid accesses until interrupt register behavior exists.
- Added a self-checking MMIO testbench and five expected-failure access tests; verified START-store retirement through the CPU address router.
- Compiled the package first in the regression and preserved the existing Phase 1 subsystem without changes.
- Completed full Verilator 5.032 verification: RTL lint, 22 positive testbenches, and nine expected-failure cases passed.
- Kept the roadmap's module-port-list item open: controller and accelerator interfaces still specify groups rather than finalized complete port lists.

## 2026-09-26

- Implemented the sequential PIM command validator with ten ordered checks, first-fault reporting, and no memory or buffer side effects.
- Used widened unsigned half-open ranges; an exclusive endpoint of 0x1_0000_0000 is accepted, and the matrix span includes stride padding.
- Added self-checking coverage for error priority, boundaries, overlap, reuse, reset, back-to-back commands, and one-entry parameters. A second start while busy is a simulation-fatal protocol violation.
- Added standalone validator lint, the positive testbench, and the expected-failure test to the regression.
- Completed the full `make verify` regression with Verilator 5.032.

- Completed the one-lane MAC and standalone arithmetic verification.
- Implemented and independently verified the PIM controller: command snapshot, validation gate, vector fill/reuse with response bypass, variable-latency reads, MAC scheduling, and completion after final write acceptance.
- Added controller lint and standalone test coverage to `make verify`; integration remains the next milestone.
- Full make verify and git diff --check passed on feat/pim-controller.

- Added `opencorex_pim_subsystem` as a separate top that connects the CPU, address router, accelerator, existing memory interconnect, and synchronous RAM adapter without changing the Phase 1 top or RAM protocol.
- Added a CPU-driven system test for accepted START retirement, registered busy blocking, PIM request and response routing, CPU resume after final write acceptance, and reset persistence of an accepted RAM write.
- Ran the unchanged CPU-only matrix-vector program through the new top: all 32 outputs matched and completion remained at 23,685 active cycles.
- Added subsystem lint and both system tests to `make verify`. The CPU-driven PIM benchmark program remains the next milestone.
- Full `make verify` and `git diff --check` passed on `feat/pim-subsystem` before the commit and fast-forward review.

- Generated a CPU-driven PIM offload program for the deterministic 1×16 by 16×32 workload, reusing the original operands and independent 32-output reference. The MMIO-base literal is isolated at 0x80 below the vector at 0x100.
- The program writes all six descriptor fields, launches with COMMAND=1, checks STATUS for DONE without ERROR after the CPU unblocks, writes RKYC to 0x9C4, and remains in a self-loop.
- End-to-end verification confirmed 32 correct results, unchanged inputs, 16 vector reads, 512 matrix reads, 32 output writes, MMIO isolation, PIM response routing, and CPU blocking through final output acceptance.
- Measured 4,272 total CPU-program cycles, 4,141 accepted-START-to-final-output cycles, and 4,141 CPU blocked cycles on the current synchronous RAM model. These intervals overlap and are not additive.
- Kept the 23,685-cycle CPU reference unchanged. This is a 32-bit functional prototype; the packed 8-bit D8 configuration remains later work.
