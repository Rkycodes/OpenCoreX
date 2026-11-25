# OpenCoreX

OpenCoreX is a SystemVerilog research platform for comparing software execution with digital near-memory offload. A multicycle RV32-subset CPU runs the baseline and launches a single-lane INT32 matrix–vector accelerator through MMIO. Both share a single-port RAM with one outstanding read.

[System architecture and CPU datapath](docs/architecture/README.md) · [MMIO and memory interface](docs/architecture/mmio-memory.md) · [Experiments and reproduction](docs/evaluation/README.md)

## Selected results

| RTL experiment | Measured result |
|---|---|
| 128×128 GEMM at 20-cycle read delay | CPU MAC fusion cuts tiled CPU cycles by 9.63%. Offload is 1.73× as fast as the fused CPU baseline. [Results](docs/evaluation/mac-results/README.md) |
| Synthetic CIFAR-shaped convolution slices | Weight retention wins at a five-cycle read delay on all three measured slices. Its crossover against activation retention occurs between two and four cycles, depending on the slice. [Sweep](docs/evaluation/cifar-ram-latency-results/README.md) |
| Full Conv2_1 on the 16 MiB RAM model | Activation retention leads at both measured endpoints. At five cycles it finishes 1,111,736 cycles ahead of weight retention. [Capacity study](docs/evaluation/cifar-ram-latency-results/README.md#storage-ledger-and-capacity) |

The results are from RTL simulation. Cycle comparisons include software packing and output handling where the workload requires them. The energy sensitivity study uses assumed coefficients.

## Run

Use Linux or WSL with Verilator 5.x, GNU Make, Bash, Python 3, and a C++ compiler. Individual study pages list additional Python dependencies.

```sh
make verify
make cold-warm
make help
```

RTL lives in [rtl](rtl/), self-checking benches in [tb](tb/), program images in [programs](programs/), and experiment tooling in [scripts](scripts/). See the [documentation index](docs/) for verification and development history.
