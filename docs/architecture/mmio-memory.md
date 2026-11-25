# MMIO and memory interface

The CPU uses aligned 32-bit accesses. RAM starts at byte address zero. The accelerator's 4 KiB MMIO page defaults to `0x40000000`. Requests transfer on `valid && ready`. Accepted reads return a separate response. The shared RAM path allows one outstanding read and arbitrates between the CPU side and accelerator.

## Submit a command

1. Program vector address and length, matrix address and column stride, and output address and count. Addresses and stride are in bytes. Length and count are in words.
2. Write `COMMAND.START` (bit 0). Set bit 1 for resident-vector reuse. The start store can complete before the command finishes. The CPU blocks during command execution.
3. Read `STATUS` for completion or error. Read `ERROR_CODE` on error and clear sticky flags through `STATUS_CLEAR` before retrying. Invalidate the buffer through `BUFFER_CONTROL` before reusing an address whose contents changed.

| Offset | Register | Access |
|---|---|---|
| 0x000 / 0x004 | VECTOR_BASE / VECTOR_LENGTH | R/W |
| 0x008 / 0x00C | MATRIX_BASE / MATRIX_COLUMN_STRIDE | R/W |
| 0x010 / 0x014 | OUTPUT_BASE / OUTPUT_COUNT | R/W |
| 0x018 | COMMAND | W |
| 0x01C | STATUS (bits 0–3 are busy, done, error, vector full) | R |
| 0x020 / 0x024 | VALID_COUNT / ERROR_CODE | R |
| 0x028 | STATUS_CLEAR (write one to bit 1 or 2 to clear done or error) | W |
| 0x02C / 0x030 | RESIDENT_VECTOR_BASE / RESIDENT_VECTOR_LENGTH | R |
| 0x034–0x040 | CAPABILITIES, BUFFER_WORDS, MAX_OUTPUTS, MAC_LANES | R |
| 0x044 / 0x048 | Reserved interrupt registers (read zero) | R |
| 0x04C | BUFFER_CONTROL (bit 0 invalidates the vector) | W |

The [RTL package](../../rtl/pim/pim_pkg.sv) defines exact constants and error codes. The [validator](../../rtl/pim/pim_command_validator.sv) enforces descriptor bounds, alignment, stride, overlap, and resident-vector identity. For port timing and error precedence, see the [module contract](pim-module-interfaces-v0.1.md) and [shared-memory protocol](pim-memory-interface.md).
