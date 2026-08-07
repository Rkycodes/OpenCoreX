# OpenCoreX

## Overview
OpenCoreX is a long-term hardware engineering portfolio project focused on modern CPU architecture, RTL design, computer architecture, verification, FPGA development, ASIC concepts, and AI hardware acceleration.

## Initial Milestone
The first milestone is to design and verify a simulation only, non-pipelined, multicycle RISC-V processor in SystemVerilog. The processor will implement a defined subset of the 32-bit RV32I base instruction set. This stage emphasizes understanding and documenting the architecture, control sequence, RTL, and verification methodology rather than simply producing a working CPU. The goal is to have this stage done by September 1, 2026 at the latest.

## Current Status
The project currenltly has architecture complete; RTL implementation beginning. ALU subsystem, immediate generator, and register file are complete.

## Long-Term Direction
Over time, it will expand to include more advanced architectural features, memory systems, verification infrastructure, FPGA implementation, and research-inspired extensions.

A parallel effort explores compact PIM architectures through a Python-based system-level simulator inspired by research by Peilin Chen and Xiaoxuan Yang. The simulator will models architectural tradeoffs such as memory capacity, data movement, scheduling, pipeline utilization, and throughput to understand the performance limits of compact AI accelerators.

## Project Goals
- Understand every architectural and RTL design decision
- Develop high level SystemVerilog and verification practices
- Build toward FPGA, RTL, ASIC, and AI-hardware engineering work
