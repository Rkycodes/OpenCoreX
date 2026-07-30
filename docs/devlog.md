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
- Established the next task: audit FSM control outputs state by state before writing RTL.
