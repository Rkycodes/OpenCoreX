# Evaluation

Each result page links its measured data and explains its workload and timing boundary. See the [methodology](evaluation-methodology.md) and [event accounting](pim-event-accounting.md) for counter definitions.

| Study | What it measures | Run |
|---|---|---|
| [CIFAR backing-memory sweep](cifar-ram-latency-results/README.md) | Retention crossovers, capacity, and full-layer endpoints | `python3 scripts/run_cifar_chunked.py conv1_2 conv2_1 conv2_2 --delay 1 2 3 4 5 --run-id matched-1mib` |
| [Full CIFAR Conv1_1](cifar-conv1-results/programs.csv) | Full-layer CPU and offload endpoints | `make cifar-conv1-study` |
| [CIFAR forward pass](cifar-inference-results/inference.json) | Deterministic tiled forward-pass validation | `python3 scripts/run_cifar_inference.py --run-id v1-replay` |
| [Small Conv1_1](conv1-results/README.md) and [weight reuse](conv1-weight-reuse-results/README.md) | Mapping and output-layout costs | `make conv1-study conv1-weight-reuse-study` |
| [CPU MAC](mac-results/README.md) | Instruction fusion on tiled GEMM | `make mac-study` |
| [GEMM 16/32](gemm-results/README.md) and [GEMM 64/128](gemm-large-results/README.md) | End-to-end matrix multiplication | `make gemm-study gemm-large-study` |
| [Tiling](tiling-results/README.md) and [scaling](scaling-results/README.md) | Reduction-length and output-count sensitivity | `make tiling-study scaling-study` |
| [Instruction cache](cache-results/README.md) and [matched RAM latency](latency-results/README.md) | Instruction-refill and shared-memory timing effects | `make cache-study latency-sweep` |

Use a fresh checkout or worktree when regenerating tracked results. See `make help` for saved-evidence checks and offline audits.
