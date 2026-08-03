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