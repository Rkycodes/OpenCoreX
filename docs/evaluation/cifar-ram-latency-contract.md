# CIFAR convolution backing-memory latency experiment

Measure how shared backing-memory read delay changes the whole-job cycle
difference between activation retention and weight retention. Include weight
reload as a control at each delay. Use the same workload, initial data and
cache state, architecture, arithmetic and timing rules for all three policies.

| Workload | Logical input → output (H×W×C) | Measured rows × columns, filters (inclusive) | Reduction chunks | Weight tile |
|---|---|---|---|---:|
| Conv1_1, complete convolution | 32×32×3 → 32×32×64 | 0–31 × 0–31, 0–63 | 27 | 128 |
| Conv1_2, slice | 32×32×64 → 32×32×64 | 0–3 × 0–31, 0–31 | 128/128/128/128/64 | 64 |
| Conv2_1, slice | 16×16×64 → 16×16×128 | 0–15 × 0–15, 0–31 | 128/128/128/128/64 | 128 |
| Conv2_2, slice | 16×16×128 → 16×16×128 | 0–6 × 0–15, 0–31 | 9 × 128 | 56 |

These are isolated synthetic convolutions from the CIFAR VGG-16 layer shapes.
Every case uses an unflipped 3×3 kernel, stride 1, one zero-padding cell,
zero bias and no ReLU. Packing uses the full input bounds even for measured
row slices. Python `random.Random(0xc1fa)` generates signed full-width INT32
operands with directed wraparound cases. Multiply and accumulate modulo 2³².
Input is channel/row/column, weights are filter/channel/kernel-row/kernel-column,
and CPU-packed patches are position/channel/kernel-row/kernel-column. Canonical
output is row/column/filter.

- **Activation-retaining** loads a cold patch vector per spatial position and
  reduction chunk. A command reuses its vector across the filter tile (64
  filters for Conv1_1, 32 for the slices). Outputs already use canonical order.
- **Weight-reload** loads the same filter vector cold for each position tile.
  **Weight-retaining** loads it cold for the first tile and launches warm for
  subsequent tiles of the same filter and chunk. Both weight policies gather
  filter-major outputs back into canonical order. Each chunked case uses two
  position tiles. Matrix stride is the full reduction length in bytes.
- Chunked cases store one partial plane per chunk in command order. The CPU
  reads and combines all partial planes with RV32 addition before gathering.
  Conv1_1 has neither a partial-plane pass nor a separate reduction phase.

Freeze 1 MiB RAM, one RAM port, one outstanding read, 128 vector words and
128 outputs maximum per command, one MAC lane, and enabled I-cache, cold at
reset and live throughout each job. This is a **system-wide backing-memory
latency** sweep. Both testbench delay inputs receive `+DELAY=L`; the shared
responder applies the same delay to every physical read, including I-cache
refill words. A read sampled at edge `e` responds at `e+L`. Writes and
cache-hit behavior use existing timing. Count the first rising edge after
reset release through the accepted completion store inclusive. Count executed
phase markers, CPU packing, launch/status, PIM, CPU combination and gather.
Exclude host assembly, image generation/preload, build, and oracle/trace checks.

**PASS** requires the RTL completion signature, exact descriptor and resident
vector identity, bounded and correctly timed memory accesses, and every packed
word, partial store/read and final canonical word to match the oracle. The
independent direct convolution indexes the original tensors. Host chunk dots
are computed separately and checked to fold to that direct reference, including
a directed overflow across chunks. The runner also requires reconciled phase,
traffic, command, buffer and MAC counts, and exact committed endpoint counters
and program/oracle hashes. A fatal check, missing completion, timeout or
historical mismatch fails the configuration.

From the WSL checkout with Python, Verilator, Make and C++ available:

```sh
python3 scripts/run_cifar_conv1.py --output obj_dir/verification/conv1_1-replay
python3 scripts/run_cifar_chunked.py conv1_2 conv2_1 conv2_2 --delay 1 2 3 4 5 --plan
python3 scripts/run_cifar_chunked.py conv2_1 conv2_2 --delay 3 --run-id nov20-pilot
```

See [counter schema and verification](cifar-ram-latency-verification.md) and
[historical chunked results](cifar-chunked-results/README.md).
