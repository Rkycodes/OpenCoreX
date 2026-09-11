# OpenCoreX v0.1 Integration Smoke Test

## Purpose

The integration smoke test verifies that the OpenCoreX controller, datapath, register file, ALU, immediate generator, and synchronous external memory operate correctly as one integrated processor.

The component testbenches verify individual RTL modules in isolation. This program verifies that those modules are connected correctly and cooperate to execute instructions end to end.

The program exercises every instruction supported by OpenCoreX v0.1:

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

The machine-code program is stored in:

```text
programs/hex/integration_smoke.hex
```

## Test Program

| Address | Assembly | Expected effect |
|---:|---|---|
| `0x00` | `addi x1, x0, 12` | `x1 = 12` |
| `0x04` | `addi x2, x0, 10` | `x2 = 10` |
| `0x08` | `add x3, x1, x2` | `x3 = 22` |
| `0x0C` | `sub x4, x1, x2` | `x4 = 2` |
| `0x10` | `and x5, x1, x2` | `x5 = 8` |
| `0x14` | `or x6, x1, x2` | `x6 = 14` |
| `0x18` | `xor x7, x1, x2` | `x7 = 6` |
| `0x1C` | `addi x8, x7, 5` | `x8 = 11`; tests `ADDI` with a nonzero `rs1` |
| `0x20` | `sw x8, 128(x0)` | Memory word 32 receives `11` |
| `0x24` | `lw x9, 128(x0)` | `x9 = 11` |
| `0x28` | `addi x10, x0, 17` | Initializes the branch sentinel |
| `0x2C` | `beq x8, x9, 8` | Taken branch to `0x34` |
| `0x30` | `addi x10, x0, 99` | Must be skipped by `BEQ` |
| `0x34` | `addi x12, x0, 23` | Initializes the jump sentinel |
| `0x38` | `jal x11, 8` | Writes `0x3C` to `x11` and jumps to `0x40` |
| `0x3C` | `addi x12, x0, 99` | Must be skipped by `JAL` |
| `0x40` | `lw x31, 160(x0)` | Loads the completion signature |
| `0x44` | `sw x31, 188(x0)` | Writes the completion signature |
| `0x48` | `jal x0, 0` | Safety loop if simulation continues |

## Expected Architectural State

| Location | Expected value | Verification purpose |
|---|---:|---|
| `x1` | `12` | First `ADDI` |
| `x2` | `10` | Second `ADDI` |
| `x3` | `22` | `ADD` |
| `x4` | `2` | `SUB` and operand order |
| `x5` | `8` | `AND` |
| `x6` | `14` | `OR` |
| `x7` | `6` | `XOR` |
| `x8` | `11` | `ADDI` using a nonzero source register |
| `x9` | `11` | `SW` followed by `LW` |
| `x10` | `17` | Taken `BEQ` skipped the following instruction |
| `x11` | `0x0000003C` | Correct `JAL` return address |
| `x12` | `23` | `JAL` skipped the following instruction |
| `x31` | `0x524B5943` | Completion-signature load |
| Memory word 32 | `11` | Correct store to byte address 128 |

Registers `x10` and `x12` receive known sentinel values before the control-flow instructions. OpenCoreX intentionally does not reset registers `x1` through `x31`, so the test cannot assume that a skipped register remains zero.

## Memory Map

| Word index | Byte address | Purpose |
|---:|---:|---|
| 0–18 | `0x00–0x48` | Test instructions |
| 32 | `0x80` | Arithmetic result written by `SW` and read by `LW` |
| 40 | `0xA0` | Preloaded completion signature |
| 47 | `0xBC` | Completion address |

OpenCoreX presents byte addresses to memory. Because each memory word contains four bytes:

```text
word_index = byte_address / 4
```

For example:

```text
128 / 4 = memory word 32
160 / 4 = memory word 40
188 / 4 = memory word 47
```

## Completion Protocol

The hex file places the value `0x524B5943` at memory word index 40, corresponding to byte address 160.

This value is the ASCII encoding of `RKYC`:

```text
0x52 = R
0x4B = K
0x59 = Y
0x43 = C
```

The final program instructions load this value into `x31` and store it to byte address `188`.

The testbench declares successful program completion only when it observes:

```systemverilog
mem_write &&
mem_addr == 32'h0000_00BC &&
mem_write_data == 32'h524B_5943
```

A write to the completion address with any other value causes an immediate failure. Failure to reach the completion transaction within the configured cycle limit causes a timeout failure.

## Testbench Configuration

The external memory is initialized with:

```systemverilog
memory #(
    .WORDS(1024),
    .INIT_FILE("programs/hex/integration_smoke.hex")
) test_memory (
    // Memory connections
);
```

The testbench uses:

```systemverilog
localparam int MAX_CYCLES = 150;
localparam logic [31:0] DONE_ADDR  = 32'h0000_00BC;
localparam logic [31:0] DONE_VALUE = 32'h524B_5943;
```

The stored arithmetic result is checked at memory word index 32:

```systemverilog
test_memory.mem[32] == 32'd11
```

## Interface Checks

During execution, the testbench verifies that:

- `error` remains deasserted.
- `mem_read` and `mem_write` are never asserted simultaneously.
- Every active memory address is word-aligned.
- The completion write contains the expected signature.
- Execution completes before the timeout.
- The final register and memory values match the expected architectural state.

## Verification Scope

This smoke test covers one legal end-to-end execution path through every instruction supported by OpenCoreX v0.1. It verifies basic processor integration but is not exhaustive by itself.

Companion verification covers:

- Legal architectural corner cases in `tb/opencorex_corner_cases_tb.sv`
- Illegal instructions and sticky `ERROR` behavior in `tb/opencorex_illegal_tb.sv`
- Misaligned, out-of-range, and simultaneous memory operations in `tb/memory_error_tb.sv`
- Reset during execution and restart behavior in `tb/opencorex_reset_tb.sv`
- Detailed module behavior in the standalone RTL testbenches
- Exhaustive instruction-decode legality in `tb/controller_tb.sv`