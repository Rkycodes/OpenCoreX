# 16×32 CPU vector-reuse diagnostics

The [looped, memory-based CPU program](matvec_1x16_16x32.md) remains the
general CPU reference for future, larger workloads. These two additional
programs isolate the cost of inner-loop instructions and reuse of this
particular 16-element vector. Both use the same signed operands, independent
reference outputs, output-column-major matrix, single-port 1,024-word RAM,
and scalar `MUL` followed by accumulating `ADD`. All 512 matrix weights are
loaded from RAM in each execution.

## Images and layout

Run `python3 scripts/generate_matvec_diagnostics.py` to produce
`programs/hex/matvec_1x16_16x32_resident.hex` and
`programs/hex/matvec_1x16_16x32_streaming.hex`. The generator imports operand,
encoding, and independent-reference functions from the original generator.
It checks the stored reference image, asserts that every code and data region
is disjoint, and ensures that the kernel ends within the RAM at `0xFFF`.
The original benchmark image is not regenerated or changed.

| Region | Byte addresses | Contents |
|---|---:|---|
| Trampoline | `0x000` | `JAL x0, 0xA00` |
| Vector | `0x100`–`0x13F` | 16 signed words |
| Matrix | `0x140`–`0x93F` | 512 signed words, output-column-major |
| Outputs | `0x940`–`0x9BF` | 32 result words |
| RKYC source | `0x9C0` | `0x524B5943` |
| Completion destination | `0x9C4` | RKYC store |
| Diagnostic kernel | `0xA00`–`0xB34` | 78 instruction words, including safety loop |

The sparse `$readmemh` images use word-address markers. Neither program can
fall through from the trampoline into data. The testbench permits instruction
fetches only at `0x000` and within `0xA00`–`0xB34`.

## Program structure and registers

Both programs set `x5` to the vector base, `x6` to the current matrix column,
`x7` to the output pointer, and `x8` to the remaining output count. `x11` is
the accumulator, `x12` the weight, and `x14` the product. The resident
program loads vector words once into `x15`–`x30`. The streaming program uses
`x13` for each freshly loaded vector word. Neither program modifies its
vector operands. `x31` receives RKYC only after all 32 outputs are stored.

Each outer-loop iteration clears `x11`, executes 16 explicit weight-load,
`MUL`, and accumulating-`ADD` sequences, stores one output, advances the
matrix and output pointers, decrements `x8`, and branches back if needed.
Streaming inserts one `LW` of `x[i]` immediately before each weight load;
the rest of the arithmetic and outer-loop structure is the same. Weight
loads use offsets `0` through `60` from the current matrix-column base.

The resident kernel has 21 setup words (including 16 vector loads), a
54-word outer loop, and two completion instructions before the safety loop.
The streaming kernel has five setup words, a 70-word outer loop, and the
same completion tail. Including the trampoline, dynamic instruction fetches
through the completion store are therefore `1 + 21 + 32×54 + 2 = 1,752`
and `1 + 5 + 32×70 + 2 = 2,248`, respectively. Both images occupy 78 kernel
words; the different setup and loop lengths happen to balance.

## Checks and measurement boundary

`make diagnostics` runs each image through the direct core plus synchronous
RAM adapter and through the shared memory subsystem with PIM idle. The four
simulations check every output store in order against the independent
32-word reference, the completion store after output 31, unchanged vector
and matrix, and the final RKYC word. The resident runs also check all 16
registers `x15`–`x30`. Accepted physical transactions are classified by
instruction-fetch state and address. Fetches outside the trampoline and
kernel, unexpected data accesses or writes, misalignment, simultaneous
physical read and write, core errors, and timeout fail the test. Fetched
instruction encodings identify the 512 `MUL`s and 512 accumulating `ADD`s.

Active cycles start with reset release and end with acceptance of the RKYC
store at `0x9C4`, including that cycle. This matches the original CPU test.
Counts exclude testbench inspection of memory after completion.

## Measured results

| Metric | Looped CPU reference | Unrolled streaming CPU | Register-resident CPU | PIM whole program |
|---|---:|---:|---:|---:|
| Active cycles, direct core | 23,685 | 13,290 | 9,818 | — |
| Active cycles, shared subsystem | 23,685 | 13,290 | 9,818 | 4,272 |
| Cycles per output | 740.156 | 415.313 | 306.813 | 133.500 |
| Instruction fetches through completion | 4,327 | 2,248 | 1,752 | 25 |
| Vector RAM reads | 512 | 512 | 16 | 16 |
| Matrix RAM reads | 512 | 512 | 512 | 512 |
| Output RAM writes | 32 | 32 | 32 | 32 |
| Instruction plus data RAM traffic | 21,540 B | 13,224 B | 9,256 B | 2,352 B |

All three CPU runs also make one RKYC-source read and one completion write;
these are included in the traffic row. The PIM program additionally reads
one MMIO-base literal from RAM. Its traffic row includes CPU instruction
fetches, the literal and RKYC reads, PIM operand reads and output writes,
and the completion write. Its seven MMIO writes and one MMIO read are
separate control transactions, not RAM traffic. Every CPU run executes 512
`MUL`s and 512 accumulating `ADD`s. The PIM result is the existing
[CPU-driven offload benchmark](pim_offload_1x16_16x32.md), which uses one
MAC lane and the same physical RAM.

The looped CPU takes 1.782× as many cycles as unrolled streaming. For this
16×32 program, that comparison measures unrolling and removal of inner-loop
instructions while vector loads remain at 512. Unrolled streaming takes
1.354× as many cycles as register-resident, isolating reuse of the 16-element
vector in registers; it removes 496 vector reads and 496 corresponding `LW`
instruction fetches. The looped reference takes 2.412× as many cycles as
register-resident. Relative to the PIM whole program, the looped, streaming,
and resident CPUs take 5.544×, 3.111×, and 2.298× as many cycles,
respectively. The CPU-versus-PIM ratios are whole-system comparisons that
also include different control flow, offload setup, and accelerator execution.

Keeping an entire vector in registers is limited by register count and code
size; the matrix remains memory-resident. A larger workload will need a
larger memory system and a scalable looped CPU program, potentially with a
modeled cache or tiling. The existing looped baseline is the starting point
for that work. These diagnostics should not be extrapolated to large
matrices, and current RAM traffic is not the unavoidable behavior of a CPU
with a cache. The simulations do not measure energy, power, or silicon
latency.

## Reproduce

```bash
python3 scripts/generate_matvec_diagnostics.py
make diagnostics
make verify
git diff --check
```
