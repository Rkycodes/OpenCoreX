# OpenCoreX 16-Element Dot-Product Benchmark

## Purpose

This program uses the verified scalar `MUL` instruction to execute one complete signed 16-element dot product on OpenCoreX.

The benchmark exercises:

- Repeated synchronous data loads
- Signed scalar multiplication
- Accumulation using `ADD`
- Pointer updates using `ADDI`
- Loop-count updates using `ADDI`
- Conditional loop termination using `BEQ`
- Backward control flow using `JAL`
- Result storage using `SW`
- Memory-based completion detection

The machine-code program is stored in:

```text
programs/hex/dot_product_16.hex
```

## Operation

The benchmark computes:

```text
result = sum(A[i] * B[i]), for i = 0 through 15
```

Each `MUL` retains the low 32 bits of the product. Accumulation also follows normal RV32 modulo-\(2^{32}\) behavior.

## Input Vectors

```text
A = [1, -2, 3, 4, -5, 6, 0, 8,
     -9, 10, 11, -12, 13, 14, -15, 16]

B = [16, 15, -14, 13, 12, -11, 10, 9,
     -8, 7, 6, -5, 4, -3, 2, 1]
```

Negative values are stored in memory using 32-bit two's-complement representation.

## Reference Result

The individual products are:

```text
A[0]  * B[0]  =   1 *  16 =  16
A[1]  * B[1]  =  -2 *  15 = -30
A[2]  * B[2]  =   3 * -14 = -42
A[3]  * B[3]  =   4 *  13 =  52
A[4]  * B[4]  =  -5 *  12 = -60
A[5]  * B[5]  =   6 * -11 = -66
A[6]  * B[6]  =   0 *  10 =   0
A[7]  * B[7]  =   8 *   9 =  72
A[8]  * B[8]  =  -9 *  -8 =  72
A[9]  * B[9]  =  10 *   7 =  70
A[10] * B[10] =  11 *   6 =  66
A[11] * B[11] = -12 *  -5 =  60
A[12] * B[12] =  13 *   4 =  52
A[13] * B[13] =  14 *  -3 = -42
A[14] * B[14] = -15 *   2 = -30
A[15] * B[15] =  16 *   1 =  16
```

Therefore:

```text
16 - 30 - 42 + 52 - 60 - 66 + 0 + 72
+ 72 + 70 + 66 + 60 + 52 - 42 - 30 + 16
= 206
```

The expected stored result is:

```text
Decimal: 206
Hex:     0x000000CE
```

A software reference can be calculated with:

```python
vector_a = [
    1, -2, 3, 4, -5, 6, 0, 8,
    -9, 10, 11, -12, 13, 14, -15, 16
]

vector_b = [
    16, 15, -14, 13, 12, -11, 10, 9,
    -8, 7, 6, -5, 4, -3, 2, 1
]

result = sum(a * b for a, b in zip(vector_a, vector_b))
result_low_word = result & 0xFFFF_FFFF

print(f"Signed result: {result}")
print(f"RV32 result: 0x{result_low_word:08X}")
```

Expected output:

```text
Signed result: 206
RV32 result: 0x000000CE
```

## Register Allocation

| Register | Purpose | Initial value |
|---|---|---:|
| `x1` | Vector-A pointer | `0x00000100` |
| `x2` | Vector-B pointer | `0x00000140` |
| `x3` | Elements remaining | `16` |
| `x4` | Accumulator | `0` |
| `x5` | Current vector-A element | Loaded each iteration |
| `x6` | Current vector-B element | Loaded each iteration |
| `x7` | Current low-word product | Calculated each iteration |
| `x31` | Completion signature | `0x524B5943` |

After the final iteration, the expected register values are:

```text
x1 = 0x00000140
x2 = 0x00000180
x3 = 0x00000000
x4 = 0x000000CE
```

## Memory Map

| Contents | Byte addresses | Word indices |
|---|---:|---:|
| Program | `0x000–0x040` | `0x00–0x10` |
| Vector A | `0x100–0x13C` | `0x40–0x4F` |
| Vector B | `0x140–0x17C` | `0x50–0x5F` |
| Stored result | `0x180` | `0x60` |
| Completion signature source | `0x1A0` | `0x68` |
| Completion transaction | `0x1BC` | `0x6F` |

The testbench must verify the stored value at byte address `0x180`, not only the value remaining in accumulator register `x4`.

## Instruction Sequence

| Address | Machine code | Assembly | Purpose |
|---:|---:|---|---|
| `0x00` | `10000093` | `addi x1, x0, 256` | Initialize vector-A pointer |
| `0x04` | `14000113` | `addi x2, x0, 320` | Initialize vector-B pointer |
| `0x08` | `01000193` | `addi x3, x0, 16` | Initialize loop count |
| `0x0C` | `00000213` | `addi x4, x0, 0` | Clear accumulator |
| `0x10` | `0000A283` | `lw x5, 0(x1)` | Load `A[i]` |
| `0x14` | `00012303` | `lw x6, 0(x2)` | Load `B[i]` |
| `0x18` | `026283B3` | `mul x7, x5, x6` | Multiply current elements |
| `0x1C` | `00720233` | `add x4, x4, x7` | Accumulate product |
| `0x20` | `00408093` | `addi x1, x1, 4` | Advance A pointer |
| `0x24` | `00410113` | `addi x2, x2, 4` | Advance B pointer |
| `0x28` | `FFF18193` | `addi x3, x3, -1` | Decrement count |
| `0x2C` | `00018463` | `beq x3, x0, 8` | Exit if count is zero |
| `0x30` | `FE1FF06F` | `jal x0, -32` | Jump back to `0x10` |
| `0x34` | `18402023` | `sw x4, 384(x0)` | Store result at `0x180` |
| `0x38` | `1A002F83` | `lw x31, 416(x0)` | Load completion signature |
| `0x3C` | `1BF02E23` | `sw x31, 444(x0)` | Signal completion at `0x1BC` |
| `0x40` | `0000006F` | `jal x0, 0` | Safety loop |

## Branch and Jump Offsets

The `BEQ` instruction is located at `0x2C`. Its target is the result-store instruction at `0x34`:

```text
0x34 - 0x2C = +8 bytes
```

The backward `JAL` is located at `0x30`. Its target is the first loop instruction at `0x10`:

```text
0x10 - 0x30 = -32 bytes
```

Both offsets are relative to the address of their own instruction.

## Dynamic Instruction Count

The existing `BEQ` plus `JAL` control-flow sequence executes:

| Portion | Dynamic instructions |
|---|---:|
| Initialization | 4 |
| Seven non-control loop instructions × 16 | 112 |
| `BEQ` executions | 16 |
| Backward `JAL` executions | 15 |
| Result and completion operations | 3 |
| **Total through completion** | **150** |

The safety-loop instruction is not included because the testbench should terminate when the completion store occurs.

## Expected Memory Accesses

### Data reads

Each iteration performs:

```text
1 load from vector A
1 load from vector B
```

For 16 iterations:

```text
16 vector-A reads
16 vector-B reads
```

The completion sequence performs one additional signature load:

```text
Total data reads = 16 + 16 + 1 = 33
```

### Data writes

The program performs:

```text
1 result write to 0x180
1 completion write to 0x1BC
```

Therefore:

```text
Total data writes = 2
```

### Unified-memory totals

Every dynamically executed instruction also requires an instruction-memory read. Through the completion transaction:

```text
Instruction fetches = 150
Data reads          = 33
Total memory reads  = 183
Total memory writes = 2
```

## Expected Cycle Count

Under the current multicycle controller:

- `LW` requires 7 cycles.
- All other instructions used before completion require 5 cycles.

The 150 dynamically executed instructions contain 33 loads:

```text
33 loads × 7 cycles = 231 cycles
117 other instructions × 5 cycles = 585 cycles
```

Therefore:

```text
Expected active execution cycles = 816
```

If the testbench begins counting at cycle zero immediately after reset release, it should observe the completion transaction at approximately cycle `815`.

## Control-Flow Evaluation

The baseline uses:

```text
beq x3, x0, done
jal x0, loop
```

This is architecturally valid, but it requires two control-flow instructions for every continuing iteration.

A future `BNE` implementation could replace both instructions with:

```text
bne x3, x0, loop
```

For this benchmark, that would eliminate 15 dynamically executed `JAL` instructions:

```text
Dynamic instruction count: 150 -> 135
Estimated cycle count:      816 -> 741
Estimated cycle reduction:   75 cycles
```

The baseline benchmark should be verified first. The measured instruction and cycle counts can then determine whether adding `BNE` is justified as a benchmark-driven ISA extension.

## Verification Requirements

The integration testbench should verify:

1. The core never enters the `ERROR` state.
2. `mem_read` and `mem_write` are never asserted simultaneously.
3. Every memory transaction is word-aligned.
4. Exactly 16 vector-A words are read.
5. Exactly 16 vector-B words are read.
6. The result store targets byte address `0x180`.
7. The stored result is exactly `0x000000CE`.
8. The completion store targets byte address `0x1BC`.
9. The completion value is exactly `0x524B5943`.
10. The input vectors remain unchanged.
11. The final pointer, counter, and accumulator registers contain their expected values.
12. Execution completes before the selected timeout.