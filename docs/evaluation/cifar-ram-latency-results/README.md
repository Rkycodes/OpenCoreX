# CIFAR backing-memory latency audit

The paired comparison uses synthetic signed INT32 convolution with wraparound,
a shared backing-read delay, one outstanding read, a single MAC lane, and a
cold-at-reset I-cache. The workload, seed, arithmetic, measured region, and
canonical output layout are held fixed within each policy comparison. The
[experiment contract](../cifar-ram-latency-contract.md) defines the workload
slices and the whole-job boundary. The
[full Conv1_1 replay](../cifar-conv1-results/programs.csv) is a separate
endpoint reference.

## Matched sweep results

All 45 cases passed. A clean checkout of `8865fbb` supplied the 18 new
Conv2 cases and reproduced the three Conv1_2 L=3 cases and six Conv2_1
endpoint cases. The [combined CSV](programs.csv) and
[54 case receipts](provenance.json) cover the original rows and the clean replays.
Lint, cold/warm, and full regression passed on the same clean checkout.
[Regression log hashes](regression.json)

| Slice | Weight retention minus activation at L=1 | At L=5 | Observed crossover | Physical reads avoided per run |
| --- | ---: | ---: | --- | ---: |
| Conv1_2 | +139,288 cycles | −65,320 cycles | L=3 to L=4 | 51,152 |
| Conv2_1 | +246,936 cycles | −236,200 cycles | L=3 to L=4 | 120,784 |
| Conv2_2 | +114,808 cycles | −239,208 cycles | L=2 to L=3 | 88,504 |

[Whole-job cycles and policy gaps](cycles-vs-delay.svg) show the sweep and
the weight-reload control. [Crossover phases](crossover-phases.svg) show
that weight retention spends more cycles gathering the canonical output
and fewer in compute. Additional read delay extends the compute advantage
enough to cover the gather at the upper end of each crossover interval.
For example, at Conv2_1 L=4, weight retention saves 459,087 compute cycles
and adds 343,651 output-phase cycles, for a net saving of 115,416 cycles.
Packing costs are identical between the two policies. Each extra cycle of
read delay shifts the gap by exactly the difference in physical reads.

Weight reload also beats activation retention at L=5 on both Conv2 slices.
The reload versus retain comparison isolates warm buffer reuse within the
same weight schedule. Full Conv1_1 favors activation retention at both
recorded endpoints.

## Reproduce the 1 MiB study

Use Ubuntu with Python, Verilator, Make, a C++ compiler, and Matplotlib 3.10.8.
The original measurements and clean subset replays use the source recorded in
[provenance.json](provenance.json). To generate a fresh 45-case matrix:

```sh
python3 scripts/run_cifar_chunked.py conv1_2 conv2_1 conv2_2 \
  --delay 1 2 3 4 5 --run-id matched-1mib
python3 scripts/audit_cifar_ram_latency.py \
  --output docs/evaluation/cifar-ram-latency-results \
  obj_dir/verification/cifar_chunked/runs/matched-1mib
make lint
make cold-warm
make verify
```

The baseline audit accepts multiple run directories and requires all 45 cases.
It checks the recorded manifests and log hashes, exact replay agreement,
applied delays, endpoint references, output counts, phase accounting, and RAM
traffic. It also checks that cycle growth at each measured delay equals one
additional cycle per backing-memory read for each unit increase in delay.
The observed phase differences include CPU packing, accelerator command
execution, CPU partial-sum combination, and canonical output gathering. CPU
wait and PIM busy counters overlap, so adding them would double-count cycles.

## Energy sensitivity

[Energy sensitivity table](energy-sensitivity.csv) compares the three schedules
within each workload and delay. One 32-bit RAM read defines the arbitrary
energy unit. The reference coefficients are 1.5 per RAM write, 0.25 per MAC
start, 0.05 per CPU non-wait cycle, and 0.002 in static energy per whole-job
cycle at an assumed fixed clock. One-at-a-time scenarios vary writes from
0.25 to 4, MACs from 0.025 to 2.5, the CPU proxy from 0 to 1, and static energy
from 0 to 0.1. Each row gives dynamic and static estimates and total energy
relative to activation retention under the same assumptions. Equal MAC counts
within each matched comparison mean that changing the MAC coefficient alone
can change the relative gap while preserving the ranking.

Weight retention has the lowest estimate at all 15 matched points under
the reference assumptions. With the CPU proxy raised from 0.05 to 1 unit
per non-wait cycle, activation retention has the lowest estimate at all 15.

CPU non-wait cycles approximate activity and include control work. The model
assigns zero incremental dynamic energy to CPU wait cycles and omits separate
I-cache, on-chip interconnect, and local buffer energy terms. Coefficients are
illustrative engineering assumptions. Energy rankings indicate sensitivity to
those assumptions.

## Storage ledger and capacity

[Model ledger](storage-ledger.csv) shows all 13 convolutions and the single
512-to-10 classifier of the [HERO CIFAR configuration D](https://github.com/Xiaoxuan-Yang/HERO/blob/0f669feb47e6e0e7d347dfafdf331a5828ae826b/models/cifar/vgg.py),
alongside the original [VGG-16 configuration D](https://arxiv.org/abs/1409.1556)
with 224×224 input and three fully connected layers. The logical working sets
use four bytes per weight, bias, input, and output. The resident case holds
one layer's weights and full input and output. The streamed case holds the
same tensors and one output channel's weights and bias. Pools are reflected
in each block's dimensions. The logical estimate assumes no patch or partial
buffers, so the [benchmark workspace ledger](benchmark-workspace.csv) totals
the actual allocations separately.

The CIFAR parameters total 58,879,272 bytes. The largest single-layer logical
resident working set is 9,504,768 bytes. Each of those logical working sets
fits independently in 16 MiB. Holding the full model parameters requires
streaming across layers. The full Conv2_1 benchmark uses 1,892,352 bytes including
packed patches, five partial planes, both output layouts, and the code
prefix. It checks 32,768 output words per run.

```sh
python3 scripts/cifar_storage_ledger.py
python3 scripts/cifar_storage_ledger.py --benchmark
python3 scripts/run_cifar_chunked.py conv2_1 --delay 1 5 --workers 1 --run-id capacity-1mib
python3 scripts/run_cifar_chunked.py conv2_1 --delay 1 5 --ram-mib 16 --workers 1 --run-id capacity-16mib
python3 scripts/run_cifar_chunked.py conv2_1_full --delay 1 5 --ram-mib 16 --timeout 1200 --run-id full-16mib
```

The RAM override applies to the benchmark model. The slice retains the original
images, oracle digests, timing, and endpoint references at both capacities.
The full-layer extension uses the same three policies, arithmetic, and timing
boundary. Activation-retaining commands each emit 128 filters, and the
weight-based schedules each use 128 positions per command. The full-layer
oracle covers the whole output tensor. The cycle limit is 400 million.
The 1 MiB configuration rejects that workload before building.

The Conv2_1 slice produced byte-identical result CSVs at 1 MiB and 16 MiB.
Across the three concurrent policy processes, sampled peak RSS rose from
about 6.6 MiB to 21.6 MiB per simulator. Whole-suite wall time, including
image generation and build, was 240–281 seconds per delay group across
both capacities. These are host observations under concurrent load.

All six full Conv2_1 cases passed at 16 MiB. Each full oracle's first
32 filters also reproduce all 8,192 slice oracle words.

| Read delay | Activation-retaining | Weight reload | Weight-retaining |
| --- | ---: | ---: | ---: |
| L=1 | **176,613,908** | 177,889,932 | 177,889,292 |
| L=5 | **253,899,028** | 255,306,316 | 255,010,764 |

Activation retention leads at both measured full-layer delays. At L=5
its lead over weight retention is 1,111,736 cycles, while the 32-filter
slice favors weight retention by 236,200 cycles. The full layer uses 128
filters per activation-retaining command, and its output gather covers
four times the slice's output words. The two endpoint measurements support
the ranking at those delays. [Capacity and full-layer CSV](capacity-programs.csv) ·
[Capacity run receipts and host measurements](capacity-provenance.json)
