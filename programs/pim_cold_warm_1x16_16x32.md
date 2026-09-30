# CPU-driven PIM cold and warm vector timing

This benchmark executes two successful 1×16 by 16×32 commands on the existing
signed 32-bit digital PIM, with one MAC lane and the single-port synchronous
1,024-word RAM. It does not model the proposed packed 8-bit D8 configuration.
Both commands read the same 512 matrix weights in output-column-major order,
perform 512 logical MACs, and store the same 32 independently checked outputs.

Run `python3 scripts/generate_pim_cold_warm_1x16_16x32.py` to regenerate
`programs/hex/pim_cold_warm_1x16_16x32.hex`. The generator reuses the existing
signed operands, instruction encoders, matrix serializer, and independent
reference. A `JAL` at `0x000` reaches the CPU code at `0xA00`–`0xA78`.
The MMIO-base literal is at `0x080`; vector, matrix, outputs, RKYC source,
and completion destination remain at `0x100`, `0x140`, `0x940`, `0x9C0`,
and `0x9C4`. The generator checks that these regions do not overlap and
fit within RAM.

## Command and status sequence

The CPU writes all six descriptors, then writes `COMMAND=1` for a cold
fill. The following STATUS load waits behind PIM busy. After completion,
the CPU reads STATUS (`DONE|VECTOR_FULL=0xA`), VALID_COUNT (16), resident
vector base (`0x100`), and resident length (16). It writes `0x2` to
`STATUS_CLEAR`, the contract's write-one-to-clear action for sticky DONE.
A subsequent STATUS read must return `VECTOR_FULL=0x8`: DONE is clear
and the vector remains valid. The CPU then writes `COMMAND=3`
(`START|REUSE_VECTOR`) with every descriptor unchanged. After warm
completion, STATUS again returns `0xA`, and the CPU writes RKYC to
`0x9C4`. No reset or buffer invalidation occurs between launches.

The test additionally checks all 16 valid bits and stored buffer words
against the original vector before warm START. Warm execution must perform
512 buffer reads, with no vector RAM read, buffer write, response bypass,
or `begin_vector` event. These observations prove actual reuse of the
resident vector, beyond prior access to the same RAM addresses.

## Measurement boundary

For each command, START-to-final is `final_output_cycle - start_cycle`:
it counts cycles **after** accepted START through and **including** the
accepted final PIM output write, matching the existing offload benchmark.
Blocked cycles count clocks with a pending CPU request denied while PIM is
busy. CPU setup and completion/status intervals are kept outside the
START-to-final interval:

- Cold setup: reset release through accepted cold START, inclusive.
- Cold completion/status: after the cold final output through acceptance
  of `STATUS_CLEAR`, inclusive. It includes four MMIO reads and the clear.
- Warm setup: after `STATUS_CLEAR` through accepted warm START, inclusive.
  It includes the read proving DONE was cleared and the warm command write.
- Warm completion/status: after the warm final output through RKYC store
  acceptance, inclusive.

These six adjacent intervals sum to the 8,452-cycle two-command program.
They should not be added to the blocked cycles, which overlap execution.

## Results

| Metric | Cold fill | Warm reuse |
|---|---:|---:|
| Accepted START to final output, cycles | 4,141 | 4,140 |
| CPU cycles blocked by PIM busy | 4,141 | 4,140 |
| CPU setup cycles outside execution | 87 | 17 |
| CPU completion/status cycles outside execution | 38 | 29 |
| External vector reads | 16 | 0 |
| External matrix reads | 512 | 512 |
| External output writes | 32 | 32 |
| Vector-buffer writes | 16 | 0 |
| Vector-buffer reads | 496 | 512 |
| Vector response bypasses | 16 | 0 |
| Logical MAC starts | 512 | 512 |
| MMIO writes attributed to command | 7 | 1 |
| MMIO reads attributed to command | 4 | 2 |

There is **one additional STATUS_CLEAR write between commands**, included
in the cold completion/status interval and kept separate from the MMIO
command-write row. The warm command uses the same descriptors, so its
shorter setup and different status sequence must not be attributed to
vector reuse. The warm START-to-final interval is only one cycle shorter
(4,141/4,140 = 1.00024×). The current controller's buffer read/capture
path takes approximately the same state time as its vector request/response
path; reuse avoids 16 external reads and the cold vector-initialization
state, but this functional RAM model does not turn the traffic reduction
into a substantial cycle reduction. The matrix remains streamed on both
commands.

The focused `make cold-warm` target and full `make verify` entrypoint
check both commands' 32 stores in order against the independent reference,
their exact PIM transaction ownership and event counts, unchanged input
memory, MMIO isolation, status responses, valid buffer contents, CPU
blocking while busy, core/PIM errors, and command timeouts. Simulations
do not measure energy, power, or silicon latency.
