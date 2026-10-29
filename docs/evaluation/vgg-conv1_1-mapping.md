# VGG conv1_1: mapping and comparison contract

This study proves a small convolution mapping and measures a complete
CPU-driven job. It makes no full-VGG or analog in-memory performance claim.

## Operation

Input: 4 rows x 5 columns x 3 channels. Filters: 64 unflipped 3x3x3 kernels.
Spatial stride: 1 in both directions. Padding: one zero pixel on every edge.
Output: 4x5x64 (20 positions, 1,280 values).

For each output, sum 27 products, add its filter's nonzero bias, then apply
ReLU. Products, sums and bias addition wrap modulo 2^32. ReLU uses the signed
two's-complement interpretation after bias addition. This is integer
cross-correlation. Bias and ReLU execute on the CPU; accelerator RTL is unchanged.

## Layout and commands

Each word is four bytes; indices start at zero. Original input is channel-first:
X[c,y,x] at INPUT+4*(20*c+5*y+x). Weights are filter-first:
W[f,c,r,s] at WEIGHTS+4*(27*f+9*c+3*r+s). Output is position-first:
Y[y,x,f] at OUTPUT+4*((5*y+x)*64+f).

Pack each patch in channel, kernel-row, kernel-column order: k=9*c+3*r+s.
Read X[c,y+r-1,x+s-1] only when both coordinates are valid; otherwise write zero.
The CPU packs all 20 patches into shared RAM before computing outputs. A general
nested-loop packer performs runtime bounds checks; the timed program receives
neither host-packed patches nor a precomputed pointer table.

For each patch, configure all six descriptor fields: VECTOR_LENGTH=27,
OUTPUT_COUNT=64, MATRIX_COLUMN_STRIDE=108 bytes, plus vector/weight/output bases.
Advance the vector base 108 bytes and output base 256 bytes per position.
Launch START=1 without REUSE; after the blocking command check DONE=1, ERROR=0.
Each patch is a cold command; the instruction cache remains live between commands.

| Region | Byte base | Bytes |
|---|---:|---:|
| Boot | 0x00000 | 16 |
| Signature / completion / phase marker | 0x00440 / 0x00444 / 0x00448 | 12 |
| Constants | 0x00500 | Up to 256 |
| Code, including refill padding | 0x01000 | Up to 16 KiB |
| Input | 0x10000 | 240 |
| Packed patches | 0x11000 | 2,160 |
| Weights | 0x20000 | 6,912 |
| Bias | 0x22000 | 256 |
| Output, processed in place | 0x30000 | 5,120 |

Data storage totals 14,688 bytes, excluding code/control and the private vector
buffer. Weights/biases are stored once and reused across positions; GEMV still
rereads all weights for every patch. Storage reuse is not weight-read reuse.

Use existing benchmark provisioning: 1 MiB shared RAM, BUFFER_WORDS=128,
MAX_OUTPUTS=128, MAC_LANES=1. Production defaults stay at 16 vector words and
32 outputs; both are too small for this direct 27-input/64-output command.
The benchmark private vector buffer is 512 bytes; CPU has 31 writable registers
and no data cache. Fitting a patch is separate from full-layer residency/reuse.

## Comparisons and timing

| Variant | Dot-product implementation |
|---|---|
| A | CPU streaming: one filter at a time, MUL+ADD |
| B | CPU four-output tiling: four register sums, MUL+ADD |
| C | CPU four-output tiling with the existing scalar MAC |
| D | CPU orchestration and existing blocking digital GEMV |

All use identical tensors/layouts, CPU packing and CPU bias/ReLU processing.
B/A isolates tiling; C/B isolates fusion. D/C also includes private-buffer reuse,
traffic and control differences. No hardware redesign is included.

Measure reset release through accepted completion store, inclusive. Report
setup, CPU packing, computation (including MMIO launch/status) and CPU
bias/ReLU phases; disjoint phase and CPU-state totals must equal job cycles.
Phase-marker instructions/stores count. Report command busy cycles, instruction
cache activity and RAM traffic. Use the unchanged 512-byte instruction cache,
cold per job and live across phases, one RAM port, one outstanding read and
uniform read latency L=1,5,20. Primary comparisons enable the instruction cache.

Host preloads code, original input, native filter layout and biases. Host
generation, placement and reference checking are excluded from simulated cycles.
Report image size and host generation wall time separately; neither measures
physical host-to-device transfer. No weight conversion is needed from the
declared native layout. Upstream conversion, physical transfer and downstream
consumption remain unmeasured. This is not complete application latency.
Direct CPU convolution without explicit patch packing is a later comparison;
A-C deliberately measure the same packed-patch pipeline.

## Proof and reproduction

Use deterministic small mixed-sign and full-width wraparound cases, with
nonzero per-filter biases. The independent Python reference indexes original
tensors directly without the patch packer or serialized-weight addresses.
Compare all raw sums, wrapped biased words and final outputs. Also check packed
entries, input/weight/bias immutability, output order, memory ownership,
descriptors, vector freshness and completion ordering.

Save measured CSVs, source/image hashes, versions and exact commands. Graphs
must use actual RTL measurements. Generator/proof, focused study and plotting
commands accompany the implementation. Run make verify if shared RTL or
verification infrastructure changes.
