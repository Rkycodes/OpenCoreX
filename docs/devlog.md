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

