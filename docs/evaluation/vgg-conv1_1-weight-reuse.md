# VGG conv1_1: compare activation and weight reuse

Extend the [A-D study](vgg-conv1_1-mapping.md) with variant E on unchanged RTL.
Keep its original measurements, scripts, images and reference contract intact.
The input, filters, padding, arithmetic, bias and ReLU policies are identical.

## Mapping

D buffers one 27-value patch and streams 64 filters, launching 20 commands.
E buffers one filter's 27 weights and streams all 20 patches, launching
64 commands. Multiplication order changes; the dot products do not.

For filter f, E programs:
- VECTOR_BASE = WEIGHTS + 108*f; VECTOR_LENGTH = 27.
- MATRIX_BASE = PATCH; MATRIX_COLUMN_STRIDE = 108 bytes.
- OUTPUT_BASE = FILTER_OUTPUT + 80*f; OUTPUT_COUNT = 20.
- COMMAND = START only. Read/check status after each blocking command.

Each command loads a fresh filter into the existing 128-word benchmark vector
buffer. The 128-output benchmark limit is unchanged. No production parameter,
command format, weight cache or accelerator RTL is added.

## Outputs and costs

E naturally stores raw outputs filter-first: raw[f,p] at
FILTER_OUTPUT + 4*(20*f+p), where p=5*y+x. FILTER_OUTPUT is 0x32000 and
occupies 5,120 bytes, disjoint from the canonical output at 0x30000.

The CPU gathers raw[f,p] in position-first order, adds bias[f], wraps to
32 bits, applies signed ReLU and writes canonical output[p,f]. Reordering
is fused into output processing: there is no separate RAM copy pass.
Bias is still loaded once per output, matching D. Source/destination pointer
work and cache effects are included in this combined phase, not claimed as
an isolated conversion benchmark. E needs 19,808 bytes of data storage versus
D's 14,688 bytes, excluding code/control and the private vector buffer.

The following are predictions to check in simulation:

| Per complete job | D: buffer activations | E: buffer weights |
|---|---:|---:|
| Patch reads during GEMV | 540 | 34,560 |
| Weight reads during GEMV | 34,560 | 1,728 |
| GEMV operand reads | 35,100 | 36,288 |
| Commands / status reads | 20 | 64 |
| Descriptor/command writes | 140 | 448 |
| Private-buffer fills, words | 540 | 1,728 |
| Private-buffer resident reads | 34,020 | 32,832 |
| Raw output reads for processing | 1,280 | 1,280 |
| Final output writes | 1,280 | 1,280 |

For 64 filters and only 20 positions, retaining activations saves more operand
reads. Weight reuse is therefore a useful comparison, not an assumed speedup.

## Validation and measurements

Use both existing datasets and L=1,5,20 with instruction cache enabled.
Validate E against the independent direct tensor reference and independent
RV32 execution. Check every raw filter-first store, gathered raw read, biased
word and final canonical output; also verify exact fetch/cache replay, traffic,
descriptors, CPU blocking, buffer freshness and immutable operands.

Save E receipts and D/E comparison graphs separately from historical A-D results.
Verify baseline source/image identities before comparing the saved D rows.
Include CPU packing, launches/status, fused reordering/bias/ReLU and completion.
Host placement remains excluded. Run focused simulation and make verify.
