# BNE Benchmark-Driven Architecture Extension

## Motivation

OpenCoreX currently supports `BEQ` and `JAL`, which are sufficient to implement a counted loop. However, a loop that continues while its counter is nonzero requires two control-flow instructions:

```text
beq counter, x0, done
jal x0, loop
```

The 16-element scalar dot-product benchmark performs 15 continuing iterations before the counter reaches zero. Therefore, the unconditional backward `JAL` executes 15 times solely because `BNE` is unavailable.

With `BNE`, the loop can instead use:

```text
bne counter, x0, loop
```

This is the natural RISC-V representation of a counted loop and removes the redundant unconditional jump.

## Benchmark Impact

### Existing BEQ/JAL loop

The original loop contains seven arithmetic, memory, and pointer-update instructions followed by:

```text
beq x3, x0, done
jal x0, loop
```

Its dynamic instruction count through the completion store is:

| Portion | Instructions |
|---|---:|
| Initialization | 4 |
| Seven loop-body instructions × 16 | 112 |
| `BEQ` executions | 16 |
| Backward `JAL` executions | 15 |
| Result and completion operations | 3 |
| **Total** | **150** |

Under the current multicycle controller:

```text
33 LW instructions × 7 cycles = 231 cycles
117 other instructions × 5 cycles = 585 cycles
Total                             = 816 cycles
```

### BNE loop

The optimized loop uses:

```text
bne x3, x0, loop
```

Its dynamic instruction count is:

| Portion | Instructions |
|---|---:|
| Initialization | 4 |
| Eight loop instructions × 16 | 128 |
| Result and completion operations | 3 |
| **Total** | **135** |

Its expected cycle count is:

```text
33 LW instructions × 7 cycles = 231 cycles
102 other instructions × 5 cycles = 510 cycles
Total                             = 741 cycles
```

### Improvement

```text
Dynamic instructions: 150 -> 135
Execution cycles:      816 -> 741
Instructions removed:  15
Cycles removed:         75
Cycle reduction:       approximately 9.2%
```

Instruction-memory reads also decrease by 15 because each removed `JAL` would have required an instruction fetch.

The extension is justified because it materially simplifies the benchmark loop and reduces measured scalar-baseline execution time without adding a benchmark-specific custom instruction.

## Instruction Encoding

`BNE` uses the standard RISC-V B-type encoding:

| Field | Value |
|---|---|
| `opcode` | `1100011` |
| `funct3` | `001` |
| Immediate format | B-type |

Assembly syntax:

```text
bne rs1, rs2, offset
```

Architectural behavior:

```text
if RegisterFile[rs1] != RegisterFile[rs2]:
    PC = instruction_address + sign_extended_offset
else:
    PC = instruction_address + 4
```

The offset is encoded in multiples of two bytes using the existing B-type immediate format.

## Architectural Reuse

`BNE` reuses the existing branch sequence:

```text
FETCH
  -> FETCH_CAPTURE
  -> DECODE
  -> BRANCH_TARGET
  -> BRANCH_COMPARE
  -> FETCH
```

No new FSM state is required.

During `BRANCH_TARGET`, the existing datapath calculates:

```text
ALUOut = OldPC + Immediate
```

During `BRANCH_COMPARE`, the existing ALU calculates:

```text
ALUResult = A - B
Zero      = (ALUResult == 0)
```

Therefore:

- `BEQ` is taken when `Zero = 1`.
- `BNE` is taken when `Zero = 0`.

The existing branch target, immediate generator, subtract operation, `ALUOut`, and `PCSource` path are all reused.

## Required Control Extension

The current PC-enable expression is:

```text
PCEnable = PCWrite | (PCWriteCond & Zero)
```

This expression only supports branch-on-equal behavior.

Add one controller-to-datapath control signal:

```text
BranchInvert
```

Its meaning is:

| `BranchInvert` | Conditional branch behavior |
|---:|---|
| `0` | Branch when `Zero = 1` |
| `1` | Branch when `Zero = 0` |

The branch decision becomes:

```text
BranchCondition = Zero ^ BranchInvert
PCEnable = PCWrite | (PCWriteCond & BranchCondition)
```

Truth table:

| Instruction | `Zero` | `BranchInvert` | Branch taken |
|---|---:|---:|---:|
| `BEQ`, equal | 1 | 0 | 1 |
| `BEQ`, unequal | 0 | 0 | 0 |
| `BNE`, equal | 1 | 1 | 0 |
| `BNE`, unequal | 0 | 1 | 1 |

`BranchInvert` must default to zero in every non-`BNE` case.

## Controller Changes

During `DECODE`, the branch opcode must accept exactly two legal `funct3` values:

| Instruction | Opcode | `funct3` |
|---|---|---|
| `BEQ` | `1100011` | `000` |
| `BNE` | `1100011` | `001` |

Every other branch `funct3` value must continue to enter `ERROR`.

Both legal encodings transition to:

```text
BRANCH_TARGET
```

During `BRANCH_COMPARE`:

```text
PCWriteCond = 1
ALUSrcA     = A
ALUSrcB     = B
ALUOp       = SUB
PCSource    = ALUOut
```

Additionally:

```text
BranchInvert = 0 for BEQ
BranchInvert = 1 for BNE
```

## Datapath Changes

The datapath requires:

1. A new `BranchInvert` input.
2. An internal branch-condition signal.
3. An updated `PCEnable` expression.

No new:

- Datapath register
- ALU operation
- ALU control encoding
- Immediate format
- PC source
- FSM state
- Memory interface signal

is required.

## Core Integration

`opencorex_core` must declare and connect `BranchInvert` between:

```text
controller -> datapath
```

The signal remains internal to the processor and does not change the external core interface.

## Verification Requirements

### Controller verification

The controller testbench must verify:

- `BEQ` remains legal with `funct3 = 000`.
- `BNE` is legal with `funct3 = 001`.
- Both instructions follow the existing branch-state sequence.
- `BranchInvert = 0` during `BEQ`.
- `BranchInvert = 1` during `BNE`.
- Other branch `funct3` values remain illegal.
- `BranchInvert = 0` in all unrelated states.

The exhaustive legality model must count both legal branch encodings.

Before `BNE`, the expected exhaustive counts are:

```text
Legal:   1542
Illegal: 129530
```

After `BNE`, the expected counts become:

```text
Legal:   1670
Illegal: 129402
Total:   131072
```

The additional 128 legal combinations come from the 128 possible values of `funct7`, which are immediate bits for a B-type instruction and must not affect legality.

### Datapath verification

The datapath testbench must cover all four branch-condition combinations:

| Instruction | Operands | Expected behavior |
|---|---|---|
| `BEQ` | Equal | Taken |
| `BEQ` | Unequal | Not taken |
| `BNE` | Equal | Not taken |
| `BNE` | Unequal | Taken |

The tests must confirm both `PCEnable` and the resulting `PC`.

### Integration verification

The revised dot-product benchmark must use one backward `BNE` per iteration:

```text
addi x3, x3, -1
bne  x3, x0, loop
```

For a branch at byte address `0x2C` targeting the loop at `0x10`:

```text
offset = 0x10 - 0x2C
       = -28 bytes
```

The corresponding instruction is:

```text
bne x3, x0, -28
```

Machine encoding:

```text
FE0192E3
```

The integration test must verify:

- `BNE` is taken for the first 15 iterations.
- `BNE` is not taken after the sixteenth iteration.
- Exactly 16 elements from each vector are loaded.
- The stored dot-product result is `0x000000CE`.
- The benchmark completes without entering `ERROR`.
- The measured cycle count matches the optimized control flow.

## Scope Decision

`BNE` is the only branch instruction required for the current fixed-count dot-product benchmark.

Other branches should not be added to this milestone unless a later workload demonstrates a concrete need. This preserves the benchmark-driven scope of the CPU reference while leaving a clear path for future ISA experiments.