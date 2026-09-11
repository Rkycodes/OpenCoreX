# OpenCoreX v0.1 Legal Corner-Case Integration Test

## Purpose

This program extends the primary integration smoke test with legal architectural corner cases. It verifies signed immediates and results, the architectural behavior of `x0`, both outcomes of `BEQ`, and backward control flow.

The machine-code program is stored in:

```text
programs/hex/integration_corner_cases.hex
```

This program intentionally excludes illegal instructions and invalid memory accesses because those cases terminate normal execution or enter the core's sticky `ERROR` state. Reset during execution also requires independent testbench control. Those behaviors belong in separate tests.

## Test Program

| Address | Assembly | Expected effect |
|---:|---|---|
| `0x00` | `addi x1, x0, -5` | `x1 = -5` |
| `0x04` | `addi x2, x0, 3` | `x2 = 3` |
| `0x08` | `add x3, x1, x2` | `x3 = -2` |
| `0x0C` | `sub x4, x1, x2` | `x4 = -8` |
| `0x10` | `addi x0, x0, 99` | Attempted write to `x0` must be ignored |
| `0x14` | `addi x5, x0, 7` | `x5 = 7`, proving `x0` still reads as zero |
| `0x18` | `addi x6, x0, 17` | Initialize the not-taken branch sentinel |
| `0x1C` | `beq x1, x2, 8` | Must not branch because `-5 != 3` |
| `0x20` | `addi x6, x0, 23` | Must execute after the not-taken branch |
| `0x24` | `addi x7, x0, 0` | Initialize the backward-branch counter |
| `0x28` | `addi x8, x0, 1` | Set the backward-branch comparison value |
| `0x2C` | `addi x7, x7, 1` | Increment the backward-branch counter |
| `0x30` | `beq x7, x8, -4` | Taken once to `0x2C`, then not taken |
| `0x34` | `addi x13, x0, 0` | Initialize the backward-jump counter |
| `0x38` | `addi x14, x0, 2` | Set the backward-jump loop limit |
| `0x3C` | `addi x13, x13, 1` | Increment the backward-jump counter |
| `0x40` | `beq x13, x14, 8` | Exit the loop when `x13 = 2` |
| `0x44` | `jal x0, -8` | Jump backward to `0x3C` without writing a link register |
| `0x48` | `lw x31, 160(x0)` | Load the completion signature |
| `0x4C` | `sw x31, 188(x0)` | Write the completion signature |
| `0x50` | `jal x0, 0` | Safety loop if simulation continues |

## Expected Architectural State

| Location | Expected hexadecimal value | Interpretation |
|---|---:|---|
| `x1` | `0xFFFFFFFB` | `-5` |
| `x2` | `0x00000003` | `3` |
| `x3` | `0xFFFFFFFE` | `-2` |
| `x4` | `0xFFFFFFF8` | `-8` |
| `x5` | `0x00000007` | `x0` remained architecturally zero |
| `x6` | `0x00000017` | Decimal 23; not-taken branch fall-through executed |
| `x7` | `0x00000002` | Backward branch executed exactly once |
| `x8` | `0x00000001` | Backward-branch comparison value |
| `x13` | `0x00000002` | Backward jump executed exactly once |
| `x14` | `0x00000002` | Backward-jump loop limit |
| `x31` | `0x524B5943` | Completion signature |

Do not check the internal storage element corresponding to register zero. The register file does not reset its storage array, and architectural reads of `x0` are forced to zero independently of that storage. The value written to `x5` proves the architectural behavior of `x0`.

## Finite Backward Branch

The branch at `0x30` targets `0x2C`:

1. `x7` increments from 0 to 1.
2. `beq x7, x8, -4` is taken because both registers contain 1.
3. `x7` increments from 1 to 2.
4. The same branch is not taken because `2 != 1`.

This tests a negative branch offset without creating an infinite loop.

## Finite Backward Jump

The jump at `0x44` targets `0x3C`:

1. `x13` increments from 0 to 1.
2. The branch at `0x40` is not taken because `1 != 2`.
3. `jal x0, -8` jumps backward to `0x3C`. Because `rd = x0`, the return address is discarded.
4. `x13` increments from 1 to 2.
5. The branch at `0x40` is taken to `0x48`, skipping the backward jump.

This tests a negative jump offset and `JAL` with `rd = x0` while keeping the program finite.

## Completion Protocol

The hex file places `0x524B5943`, the ASCII encoding of `RKYC`, at memory word index 40, corresponding to byte address 160. The program loads the signature into `x31` and stores it to byte address 188 (`0xBC`).

The testbench declares completion only when it observes:

```systemverilog
mem_write &&
mem_addr == 32'h0000_00BC &&
mem_write_data == 32'h524B_5943
```

A write to the completion address with another value is an immediate failure. Failure to reach the completion transaction within the configured cycle limit is a timeout failure.

## Verification Scope

This program covers:

- A not-taken forward `BEQ`
- A taken and then not-taken backward `BEQ`
- A negative `ADDI` immediate
- Negative `ADD` and `SUB` results
- An attempted write to `x0`
- A backward `JAL` with `rd = x0`

Related exceptional behavior is covered separately:

- `tb/opencorex_illegal_tb.sv` verifies illegal instructions and sticky `ERROR` behavior.
- `tb/memory_error_tb.sv` verifies misaligned, out-of-range, and simultaneous memory requests.
- `tb/opencorex_reset_tb.sv` verifies reset during execution and successful restart.