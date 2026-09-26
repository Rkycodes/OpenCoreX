# 1×16 by 16×32 CPU-Driven PIM Offload Benchmark

## Program and generation

Run `python3 scripts/generate_pim_offload_1x16_16x32.py` to generate
`programs/hex/pim_offload_1x16_16x32.hex`. The generator imports the
deterministic vector and logical matrix from the CPU benchmark generator,
serializes the matrix in the same output-column-major order, and checks its
independently calculated 32-word reference against
`programs/hex/matvec_1x16_16x32_expected.hex`. The CPU-only image,
reference, and 23,685-cycle regression are unchanged.

The RV32 program loads `0x4000_0000` from the RAM literal at `0x80`
because this core does not implement LUI. It writes the six MMIO descriptor
fields, then writes `COMMAND=1` at offset `0x18`:

| Field | Value |
|---|---:|
| VECTOR_BASE | `0x100` |
| VECTOR_LENGTH | 16 |
| MATRIX_BASE | `0x140` |
| MATRIX_COLUMN_STRIDE | 64 bytes |
| OUTPUT_BASE | `0x940` |
| OUTPUT_COUNT | 32 |

The next instruction reads STATUS at offset `0x1C`. The router blocks that
CPU request while PIM is busy. After PIM accepts the final output write, the
CPU reads STATUS, masks DONE and ERROR, and requires `DONE=1, ERROR=0`.
Failure branches to a dedicated self-loop. Success loads RKYC from `0x9C0`,
stores it at `0x9C4`, and enters a success self-loop.

## Memory layout

| Region | Byte addresses | Contents |
|---|---|---|
| Program | `0x000`–`0x06B` | 27 instructions; success loop at `0x064`, failure loop at `0x068` |
| Gap | `0x06C`–`0x0FF` | MMIO-base literal at `0x080`; no fall-through execution |
| Vector | `0x100`–`0x13F` | 16 signed 32-bit words |
| Matrix | `0x140`–`0x93F` | 512 signed 32-bit words, output-column-major |
| Outputs | `0x940`–`0x9BF` | 32 signed 32-bit results |
| Signature source | `0x9C0` | `0x524B5943` (RKYC) |
| Completion destination | `0x9C4` | CPU writes RKYC after confirmed DONE |

The testbench checks that the literal is read once as data, never executed
as an instruction, and that the CPU repeatedly fetches the success loop.

## Observations and comparison boundary

With the current single-port synchronous RAM and one MAC lane:

| Measurement | Cycles or transactions |
|---|---:|
| Total CPU program, reset release through RKYC store acceptance | 4,272 cycles |
| Accepted START through final PIM output-write acceptance | 4,141 cycles |
| Cycles with a pending CPU request blocked by PIM busy | 4,141 cycles |
| PIM vector reads | 16 |
| PIM matrix reads | 512 |
| PIM output writes | 32 |

The START-to-final and blocked-cycle intervals overlap; they are separate
views of the same execution period and must not be added to total cycles.
The CPU-only reference completes its own RKYC store after 23,685 active
cycles on the same RAM model. The whole-program comparison includes the
offload program's MMIO setup, launch, STATUS read, and signature work.
It excludes operand placement, host transfer, physical device latency,
energy, power, and area. This is a 32-bit functional prototype, distinct
from any later packed 8-bit D8 configuration.

The end-to-end test also checks all 32 results against the independent
software reference, unchanged vector and matrix, MMIO isolation from RAM,
PIM read-response ownership, CPU blocking until final write acceptance,
and STATUS completion before the RKYC store.
