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

