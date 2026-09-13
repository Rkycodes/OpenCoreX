# OpenCoreX Scalar MUL Integration Test

## Purpose

This program verifies the scalar RV32M `MUL` instruction through the complete OpenCoreX processor.

The ALU, ALU decoder, and controller testbenches verify their respective modules independently. This program verifies that instruction fetch, legality checking, register reads, multiplication, `ALUOut` capture, register writeback, and memory-based completion work together correctly.

The machine-code program is stored in:

```text
programs/hex/scalar_mul.hex
```