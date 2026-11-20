# CIFAR VGG-16 chunked convolution retention

The experiment compares activation retention, weight retention, and weight reload
on three matched convolution slices. The [full Conv1_1 baseline](../cifar-conv1-results/programs.csv)
provides the unchunked comparison.

## Workloads

The [HERO CIFAR VGG-16 configuration D](https://github.com/Xiaoxuan-Yang/HERO/blob/0f669feb47e6e0e7d347dfafdf331a5828ae826b/models/cifar/vgg.py)
defines the channel sequence and pooling. Each experiment is an isolated 3×3
stride-1 convolution with one cell of zero padding, deterministic synthetic
INT32 operands (seed `0xc1fa`), accumulation modulo 2³², zero bias, and no ReLU.

| Layer | Logical input → output (H×W×C) | Reduction chunks | Measured rows × columns | Measured filters |
|---|---|---|---|---|
| Conv1_2 | 32×32×64 → 32×32×64 | 4 × 128 + 64 | 0–3 × 0–31 | 0–31 |
| Conv2_1 | 16×16×64 → 16×16×128 | 4 × 128 + 64 | 0–15 × 0–15 | 0–31 |
| Conv2_2 | 16×16×128 → 16×16×128 | 9 × 128 | 0–6 × 0–15 | 0–31 |

The 1 MiB RAM, single RAM port, single outstanding read, single MAC lane,
enabled instruction cache, 128-word vector buffer, and limit of 128 outputs
per command match the baseline. The explicit partial-plane layout for full
Conv2_1 would require 1,892,352 bytes. The measured slice uses 983,040 bytes,
including code space and both output layouts.

## Results

| Layer | RAM delay | Activation-retaining cycles | Weight-reload cycles | Weight-retaining cycles |
|---|---:|---:|---:|---:|
| Conv1_2 | 1 | **28,939,324** | 29,078,772 | 29,078,612 |
| Conv1_2 | 5 | 39,018,812 | 39,027,380 | **38,953,492** |
| Conv2_1 | 1 | **58,133,012** | 58,380,108 | 58,379,948 |
| Conv2_1 | 5 | 78,303,508 | 78,141,196 | **78,067,308** |
| Conv2_2 | 1 | **50,503,026** | 50,618,122 | 50,617,834 |
| Conv2_2 | 5 | 68,135,346 | 68,043,882 | **67,896,138** |

Cycles run through the completion store with the output in canonical
position-first order. Activation retention had the lowest whole-job count
at `L=1` on every slice. Weight retention had the lowest count at `L=5`.
At `L=5`, the weight-reload control also beat activation retention on the
Conv2_1 and Conv2_2 slices. The full Conv1_1 baseline favored activation
retention at both delays.

[Comparison figure](retention-comparison.svg) · [All counters](programs.csv) ·
[Verification record](verification.json)

## Mapping and checks

- The CPU packs the input into position-major patches. PIM matrix stride is
  the full reduction size in bytes. Each command reduces at most 128 terms.
- Activation retention produces 32 filters per command. Each weight policy
  uses two position tiles per filter and chunk, with 64, 128, and 56 positions
  per tile for Conv1_2, Conv2_1, and Conv2_2. The weight policies use identical
  layouts and instructions, with the warm-reuse immediate changed. The second
  tile is warm only for weight retention.
- The RTL clears the accumulator on each launch. The CPU reads all partials
  from RAM and sums them with RV32 addition. Weight policies gather their
  merged filter-major results into canonical position-first order.
- The monitor checks cold and warm descriptors, resident vector identity,
  exclusive RAM bounds, request ownership, latency, operand and output
  order, every partial result, and every final output against the direct
  reference. A directed corner case wraps across chunks. The runner reconciles
  RAM, buffer and command counters. The CPU blocks during PIM command execution.

The CSV reports setup, packing, compute, CPU combination, and output-phase
cycles. The output phase includes the gather where applicable and completion.
In the chunked runs, `output_writes` counts native merged stores and
`final_output_writes` counts canonical stores. On the Conv1_1 baseline,
`output_writes` counts native outputs and `gather_writes` counts canonical
copies for the weight policies.

## Reproduce

Run from the repository root with Python, Verilator, Make and a C++ compiler.

```sh
make cifar-conv1-study
python3 scripts/run_cifar_chunked.py conv2_1 --delay 1 5
python3 scripts/run_cifar_chunked.py conv1_2 --delay 1 5
python3 scripts/run_cifar_chunked.py conv2_2 --delay 1 5
```

New runs write a consolidated CSV, per-case receipts, RTL logs and memory images
under `obj_dir/verification/cifar_chunked/runs/<run-id>/`. See the
[latency experiment contract](../cifar-ram-latency-contract.md) and
[counter schema](../cifar-ram-latency-verification.md). The committed manifests
record the original endpoint runs, including the code revision, modeled
parameters, RAM bounds, exact commands, and SHA-256 digests.
