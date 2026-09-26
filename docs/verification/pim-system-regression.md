# PIM System Regression

## CPU-driven command sequence

`scripts/generate_pim_system_regression.py` emits
`programs/hex/pim_system_regression.hex`. It reuses the deterministic
16-word vector, 512-word column-major matrix, and independent 32-output
reference from the CPU benchmark. Reset starts at byte address zero,
which jumps to program code at `0xA00`; the vector at `0x100`,
matrix at `0x140`, outputs at `0x940`, and RKYC words at
`0x9C0`–`0x9C4` stay in their original locations. A RAM literal at
`0x80` supplies the MMIO base because the CPU lacks LUI.

The CPU runs cold fill, warm `REUSE_VECTOR`, buffer invalidation and
refill, a reuse-length mismatch, a START attempt while ERROR remains
sticky, an invalid zero-length descriptor, and a valid launch after
`STATUS_CLEAR`. It reads STATUS and ERROR_CODE between steps. The
testbench checks the expected values, including first-fault persistence,
DONE clearing, error clearing, and vector-full changes. It repeats a
cold launch after reset, resets just after the first output write is
accepted, and verifies that the write persists while no aborted PIM
request reappears before a fresh CPU START.

| Command | External vector reads | Weight reads | Output writes | Buffer writes | Bypasses | Buffer reads |
|---|---:|---:|---:|---:|---:|---:|
| Cold fill | 16 | 512 | 32 | 16 | 16 | 496 |
| Warm reuse | 0 | 512 | 32 | 0 | 0 | 512 |
| Invalidate then refill | 16 | 512 | 32 | 16 | 16 | 496 |
| Reuse mismatch, sticky START, invalid descriptor | 0 | 0 | 0 | 0 | 0 | 0 |
| Valid after clear | 16 | 512 | 32 | 16 | 16 | 496 |

These counts are per accepted command at the subsystem boundary.
The buffer counters observe controller-to-buffer enables. Each bypass
check also compares the controller's captured vector operand with the
returned response word after the fill edge. The accepted output-write
handshake is counted once per address and checked against the independent
reference. Rejected commands must leave all 32 output words unchanged.

## Seeded accelerator timing test

`pim_accelerator_random_tb` connects the real accelerator directly to
a controlled memory responder. Its default 32-bit LFSR seed is
`0x6D527C91`; use `+SEED=<hex>` to reproduce another run. Seed
`0x00000001` was also exercised. The responder independently stalls
requests according to the LFSR and chooses each accepted read's response
delay from 1 through 20 cycles. Responses remain ordered because only
one read may be outstanding. The default run covered every delay value,
with 4,092 stalled request cycles across cold and warm commands.

The timing test checks stable request payloads during stalls, no second
outstanding read, response data tied to its accepted request, exactly
one write per output address in each command, and a 30,000-cycle
completion watchdog. It expects 1,040 accepted reads and matching
responses across cold fill and warm reuse. The system regression checks
PIM read responses do not appear on the CPU channel.

The integrated `opencorex_pim_subsystem` test uses the existing
synchronous-memory adapter, whose response latency is fixed at one
cycle. Its system scenarios establish CPU/MMIO behavior and physical
RAM persistence. The seeded accelerator test establishes variable
request and response timing. The 32-bit functional tests do not model
device latency or the later packed 8-bit D8 configuration.
