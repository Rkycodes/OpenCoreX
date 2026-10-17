# OpenCoreX

Simulation-focused multicycle RV32 subset CPU with scalar MUL and a blocking,
single-lane digital matvec accelerator. Arithmetic is signed 32-bit with
wraparound. One shared RAM port, one outstanding read, no CPU data cache.
The accelerator's private vector buffer defaults to 16 words; benchmark
configurations provision 128. This is a functional digital model, without
physical energy/area characterization.

## Run

Linux/WSL requires Verilator 5.x, GNU Make, Bash, Python 3 and a C++ compiler.

```bash
make verify            # Historical RTL, protocol, reset and benchmark regression
make gemm-study        # Square matrix multiplication: 16 and 32
make gemm-large-study  # Square matrix multiplication: 64 and 128
```

Both GEMM studies have a matching `-check` target to replay recorded evidence.
GEMM uses streaming CPU, four-output CPU tiling and one cold offload per A row.
Complete-job timing includes setup, launches, waits, status and completion.
Operands start in RAM: A/C row-major, B column-major. Host placement and
layout conversion are excluded consistently.

## Results

- [16×16 / 32×32 GEMM](docs/evaluation/gemm-results/README.md)
- [64×64 / 128×128 GEMM](docs/evaluation/gemm-large-results/README.md)
- [Larger-vector tiling](docs/evaluation/tiling-results/README.md)
- [Output-count scaling](docs/evaluation/scaling-results/README.md)
- [Instruction-cache study](docs/evaluation/cache-results/README.md)

## Code and documentation

`rtl/` contains CPU, memory, accelerator and system modules. `tb/` contains
self-checking tests. `programs/` stores generated images; `scripts/` generates,
runs and checks them. Production defaults and historical images remain separate
from benchmark overrides.

See the [documentation index](docs/README.md), [architecture](docs/architecture/architecture-v0.1.md),
[accelerator contract](docs/architecture/pim-architecture-v0.1.md) and [roadmap](docs/roadmap.md).
