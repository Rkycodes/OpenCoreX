# Scalar MUL Architecture Extension

## Purpose and Scope

Scalar `MUL` is the first benchmark-driven ISA addition after the completed OpenCoreX v0.1 milestone.

It provides the CPU multiplication operation required for the scalar `1 × 16` vector by `16 × 32` matrix benchmark. This extension implements only the RV32M `MUL` instruction and does not claim complete RV32M support.

The frozen v0.1 processor architecture remains documented in:

```text
docs/architecture/architecture-v0.1.md
```

## Instruction Encoding

`MUL` uses the standard RV32M R-type encoding:

| Field | Value |
|---|---|
| `opcode` | `0110011` |
| `funct3` | `000` |
| `funct7` | `0000001` |

Its assembly form is:

```text
mul rd, rs1, rs2
```

## Architectural Semantics

Two 32-bit source operands produce a mathematical 64-bit product. `MUL` writes only the lower 32 product bits:

```text
RegisterFile[rd] =
    (RegisterFile[rs1] * RegisterFile[rs2])[31:0]
```

Signed and unsigned multiplication produce identical lower 32 bits. Signedness matters only for the upper-product instructions `MULH`, `MULHSU`, and `MULHU`, which are not implemented.

## ALU Integration

The existing three-bit `ALUControl` encoding is extended as follows:

| `ALUControl` | Operation |
|---|---|
| `000` | `ADD` |
| `001` | `SUB` |
| `010` | `AND` |
| `011` | `OR` |
| `100` | `XOR` |
| `101` | `MUL` |
| `110–111` | Reserved |

The ALU computes:

```systemverilog
result = operand_a * operand_b;
```

Because `result` is 32 bits wide, the upper product bits are discarded.

## ALU Decoder Integration

When `ALUOp = 2'b10`, the ALU decoder interprets the instruction function fields.

The exact combination:

```text
funct7 = 0000001
funct3 = 000
```

selects:

```text
ALUControl = 101
ALUDecodeValid = 1
```

Other unsupported RV32M function combinations remain invalid.

## Controller Integration

The controller recognizes the exact MUL encoding during `DECODE` and routes it to `R_EXEC`.

No new FSM state is required because the current multiplier is combinational and uses the existing arithmetic result path.

The execution sequence is:

```text
FETCH
  → FETCH_CAPTURE
  → DECODE
  → R_EXEC
  → ALU_WRITEBACK
  → FETCH
```

During `R_EXEC`:

```text
ALUSrcA     = A
ALUSrcB     = B
ALUOp       = FUNC
ALUOutWrite = 1
```

During `ALU_WRITEBACK`:

```text
RegWrite        = 1
WriteBackSelect = ALUOut
```

## Datapath Impact

MUL requires no new:

- Datapath registers
- Multiplexers
- Writeback sources
- Control signals
- Top-level ports

The existing `A` and `B` registers provide the operands. `ALUOut` captures the lower 32 product bits, and the existing writeback path writes the result to `rd`.

## Timing Tradeoff

The current implementation uses a combinational multiplier. Functionally, this allows MUL to use one `R_EXEC` state, like the existing arithmetic operations.

However, multiplication generally has a longer combinational delay than addition or bitwise logic. Consequently, the multiplier may become the processor’s critical path during synthesis.

On an FPGA, the multiplication operator may infer DSP hardware. In an ASIC flow, synthesis may infer a combinational multiplier implementation.

The initial implementation is appropriate for establishing a functional CPU reference baseline. If later synthesis results show unacceptable timing or area, MUL can be replaced by:

- An iterative multiplier with multiple execution cycles
- A pipelined multiplier with latency-aware result handling
- A dedicated multiplier unit using `start`, `busy`, and `done`

Such a change would require additional controller sequencing and internal state.

## Research Measurement Limitation

The scalar CPU currently counts MUL as one execute state. Cycle-count comparisons against PIM must document this assumption.

A one-cycle combinational MUL does not imply that multiplication has the same clock delay as addition. Future comparisons should use either:

- A clock period constrained by the multiplier’s critical path
- A realistic multi-cycle multiplier latency

This prevents the CPU-versus-PIM comparison from overstating or understating performance.

## Verification

Verification is divided across four levels:

1. `tb/cpu/alu_tb.sv`
   - Positive multiplication
   - Negative operand
   - Low-word truncation
   - `Zero` output

2. `tb/cpu/alu_decoder_tb.sv`
   - Exact MUL decoding
   - Rejection of nearby unsupported encodings

3. `tb/cpu/controller_tb.sv`
   - MUL follows the R-type control sequence
   - Exhaustive legality testing includes exactly one new encoding

4. `tb/cpu/opencorex_mul_tb.sv`
   - End-to-end instruction execution
   - Positive, negative, zero, and truncation cases
   - Destination register `x0`
   - Completion through memory

The machine-code integration program is documented in:

```text
programs/scalar_mul.md
```