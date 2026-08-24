# OpenCoreX

## Overview

OpenCoreX is a long-term hardware engineering portfolio project focused on modern CPU architecture, RTL design, computer architecture, verification, FPGA development, ASIC concepts, and AI hardware acceleration.

## Initial Milestone

The first milestone is to design and verify a simulation only, non-pipelined, multicycle RISC-V processor in SystemVerilog. The processor will implement a defined subset of the 32-bit RV32I base instruction set. This stage emphasizes understanding and documenting the architecture, control sequence, RTL, and verification methodology rather than simply producing a working CPU. The goal is to have this stage done by September 1, 2026 at the latest.

## Supported Instructions

OpenCoreX v0.1 supports 10 instructions:
- `ADD`
- `SUB`
- `AND`
- `OR`
- `XOR`
- `ADDI`
- `LW`
- `SW`
- `BEQ`
- `JAL`
  
## Current Status

The processor architecture and all standalone RTL modules are complete:

- ALU
- ALU decoder
- Immediate Generator
- Register file
- Synchronous single-port memory
- Multicycle controller
- Multicycle datapath

## Architecture

OpenCoreX uses a multicycle architecture that reuses major hardware resources across several clock cycles.

Key architectural features include:

- Eight internal datapath registers: `PC`, `OldPC`, `PCPlus4`, `IR`, `A`, `B`, `ALUOut`, and `MDR`
- A 16-state multicycle controller
- Synchronous single-port unified instruction and data memory
- Asynchronous register-file reads and synchronous writes
- Explicit write enables for every multicycle datapath register
- Conditional branch updates using `PCWriteCond` and the ALU `Zero` result
- Safe-zero behavior for unsupported MUX and ALU-control encodings
- Sticky illegal-instruction handling with reset recovery

Detailed architecture, control sequencing, MUX encodings, and instruction paths are documented in [`docs/architecture.md`](docs/architecture.md).

## Verification

Each RTL module has a self-checking SystemVerilog testbench.

Verification currently includes:

- Directed functional tests
- Boundary and wraparound cases
- Reserved-encoding behavior
- Synchronous memory timing
- Memory alignment and range checks
- Full writable register-file coverage
- Exhaustive controller instruction decode
- Sticky `ERROR` behavior
- Cycle-level datapath integration testing
- Verilator lint with `-Wall`
  
## Roadmap

### v0.1 — Integrated Multicycle Core

- Connect the controller, datapath, and unified memory
- Execute complete programs containing all 10 supported instructions
- Verify legal execution, memory operations, branches, jumps, and error behavior

### v0.2 — Verification Infrastructure

- Automated regression scripts
- Repository-wide lint
- GitHub Actions continuous integration
- Initial architectural assertions

### v0.3 — RV32I Expansion

- Expand the supported instruction set to approximately 30 useful RV32I instructions
- Add the remaining branch, load/store, arithmetic, and logical operations

### v0.4 — Accelerator and PIM Work

- Explore accelerator integration
- Develop processing-in-memory experiments
- Study memory capacity, data movement, scheduling, utilization, and throughput

## Long-Term Direction

OpenCoreX is intended to grow beyond the initial multicycle processor. Future work may include RV32M support, pipelining, caches, AXI4-based interconnects, FPGA peripherals, accelerator interfaces, and research-inspired processing-in-memory extensions.

A parallel system-level modeling effort will explore compact PIM architectures using Python. It will study architectural tradeoffs involving memory capacity, data movement, scheduling, pipeline utilization, and throughput.

## Project Goals

- Understand every architectural and RTL design decision
- Develop strong SystemVerilog and verification practices
- Translate architectural specifications into cycle-accurate hardware
- Build toward FPGA, ASIC, CPU-design, and AI-hardware engineering work

