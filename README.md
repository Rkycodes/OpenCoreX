# OpenCoreX

## Overview

OpenCoreX is a long-term hardware engineering portfolio project focused on modern CPU architecture, RTL design, computer architecture, verification, FPGA development, ASIC concepts, and AI hardware acceleration.

## Initial Milestone

OpenCoreX v0.1 is a simulation-only, non-pipelined, multicycle processor written in SystemVerilog. It implements a defined 10-instruction subset of the 32-bit RV32I base instruction set.

The milestone focuses on architectural understanding, control sequencing, synthesizable RTL, synchronous-memory integration, and self-checking verification. OpenCoreX v0.1 is not a complete RV32I implementation.

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

OpenCoreX v0.1 is complete and functionally verified in Verilator.

The integrated processor contains:

- ALU
- ALU decoder
- Immediate generator
- Register file
- Synchronous single-port unified memory
- 16-state multicycle controller
- Multicycle datapath
- Top-level processor wrapper

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

Every RTL module has a self-checking SystemVerilog testbench. The controller, datapath, and complete processor also have dedicated integration tests.

Verification includes:

- Directed ALU and decoder tests
- Immediate-generation boundary tests
- Full writable register-file coverage
- Synchronous memory reads, writes, and initialization
- Memory alignment and range protection
- Simultaneous memory read/write rejection
- Exhaustive controller decode across all 131,072 `{opcode, funct3, funct7}` combinations
- Cycle-level datapath control and writeback tests
- End-to-end execution of all 10 supported instructions
- Taken and not-taken branches
- Forward and backward branches and jumps
- Negative immediates and arithmetic results
- Architectural `x0` behavior
- Illegal-instruction detection and sticky `ERROR` behavior
- Reset during an in-flight instruction
- Restart and successful program completion after reset
- Clean Verilator RTL lint with `-Wall`
- A passing regression across all 12 positive testbenches
- Three validated expected-failure memory tests

The integration programs use an external synchronous memory initialized from hexadecimal files under `programs/hex/`. Successful programs write the completion signature `0x524B5943` (`RKYC`) to byte address `0xBC`.

OpenCoreX v0.1 verifies its defined 10-instruction subset. It does not claim complete RV32I compliance, privileged architecture support, exception handling, or hardware traps for invalid memory accesses.
  
## Roadmap

### v0.1 — Integrated Multicycle Core — Complete

- Integrated the controller, datapath, register file, and unified memory
- Executed complete programs containing all 10 supported instructions
- Verified legal execution, memory operations, control flow, illegal instructions, and reset recovery
- Completed warning-free RTL lint and the full manual regression

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

