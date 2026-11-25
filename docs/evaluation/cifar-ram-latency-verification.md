# CIFAR backing-memory latency verification

The [experiment contract](cifar-ram-latency-contract.md) defines the workload,
layout, oracle and cycle boundary. The chunked runner preserves the committed
[L=1/L=5 measurements](cifar-chunked-results/programs.csv) and checks every
historical CSV field on replay. The original slices also check the generated
policy images and the packed, partial and final oracles against the committed
SHA-256 digests. See the [follow-up audit and capacity study](cifar-ram-latency-results/README.md)
for the full 1 MiB sweep, reproducibility instructions, and the 16 MiB extension.

## CSV and run records

Each invocation writes `obj_dir/verification/cifar_chunked/runs/<run-id>/`.
Use a fresh `--run-id` for each replay, or omit it to allocate one automatically.
`programs.csv` has one row per selected workload, delay and policy, in layer
name, ascending delay, then activation-retaining, weight-reload, weight-retaining
order. The original CSV columns stay in order. The extension adds
`applied_delay`, `warm_commands`, `mac_starts_per_pim_busy_cycle`,
`historical_match`, and `failure`. Use rows with `correctness=PASS` for plots.
A failed case records its diagnostic and exits the sweep nonzero. An interrupted
sweep retains its CSV prefix as `programs.partial.csv`. Unavailable
measurements are empty. `historical_match` is PASS or FAIL on the actual
endpoint comparison, PENDING if an endpoint failed before comparison, and N/A
at intermediate delays.

| Field group | Units and reconciliation |
|---|---|
| `cycles` | Setup + packing + compute + combine + output phase, in cycles. The phase marker store belongs to the phase it ends. Output phase includes the gather when present and the completion store. |
| `cpu_wait_cycles`, `cpu_blocked_cycles`, `cpu_non_wait_cycles` | Wait covers unaccepted CPU requests or an outstanding fetch/data response during capture. Blocked is the PIM-busy subset of wait on unaccepted requests. Non-wait is whole-job minus wait. CPU wait and PIM busy can overlap. |
| `pim_cycles`, `pim_macs` | PIM busy cycles match the sum of disjoint command durations, from launch to last partial store by edge difference. MAC starts equal measured outputs × full reduction terms. MAC starts divided by PIM busy cycles is a simulated event rate for the one-lane command execution window. |
| `input_reads`, `activation_reads`, `weight_reads`, `fetch_reads`, `control_reads`, `psum_reads`, `gather_reads` | These sum to physical `ram_reads`. Input reads feed packing. Activation reads are PIM patch reads. Fetch reads are physical instruction refill words. Control reads are constants and the completion signature. Each transaction transfers one 32-bit word. |
| `patch_writes`, `psum_writes`, `output_writes`, `gather_writes` | These plus four phase writes and one completion write sum to physical `ram_writes`. `output_writes` is the native merge, and `final_output_writes` describes the canonical stores already counted in the merge or the gather. `ram_bytes` is four times total physical reads and writes. |
| `commands`, `cold_commands`, `warm_commands`, `buffer_loads`, `buffer_reuses` | Cold + warm equals commands. Cold commands load each chunk word once. Loads + buffer reads at reuse equal MAC starts. Weight retention launches one cold and one warm per filter and chunk. Other policies launch cold only. |
| `psum_reads`, `psum_writes`, `outputs_checked`, `mmio_reads`, `mmio_writes` | Each partial count equals outputs × chunks. `outputs_checked` equals the measured tensor size. One status read per command. MMIO writes are two shared fields, one per chunk and four per command. MMIO has its own interface and counters. |

Each layer has a `manifest.json` with the Git revision and tracked changes,
tool versions, exact build arguments, parameters, RAM ranges and hashes.
Each `<policy>-L<delay>.json` has the exact simulator arguments, timeout, result,
log hash and a hash of that layer's manifest. `applied_delay` comes from the RTL
after it completes its timed response and output checks. The RTL limits the
original slices to 200 million measured cycles, and the runner defaults to
300 wall-clock seconds per simulation. The full Conv2_1 extension permits
400 million measured cycles.

## November 19 replay and pilot staging

Verilator 5.032 reproduced all eight full Conv1_1 configurations and all 18
chunked endpoint configurations. Conv1_1's program CSV, timing trace and hex
images matched the committed evidence. The chunked replay matched all
committed counters and program/oracle hashes. The endpoint cycle counts are
in the [historical table](cifar-chunked-results/README.md#results).

| New Conv1_2 delay | Activation-retaining | Weight-reload | Weight-retaining |
|---:|---:|---:|---:|
| 2 | 31,459,196 | 31,565,924 | 31,547,332 |
| 3 | 33,979,068 | 34,053,076 | 34,016,052 |
| 4 | 36,498,940 | 36,540,228 | 36,484,772 |

All nine new configurations passed. The L=3 smoke and replay check produced
byte-identical three-row CSVs. Their rows also match the intermediate sweep. `make lint`,
`make cold-warm`, and `make verify` completed successfully. Directed checks
rejected a changed partial oracle, wrong warm-command policy, invalid RTL delay
and a wall-clock timeout. The 45-case plan passed mode and delay argument checks.

```sh
make lint
make cold-warm
make verify
python3 scripts/run_cifar_conv1.py --output obj_dir/verification/ram-latency-p0/conv1_1
python3 scripts/run_cifar_chunked.py conv1_2 conv2_1 conv2_2 --delay 1 2 3 4 5 --run-id nov20-matrix --plan
python3 scripts/run_cifar_chunked.py conv1_2 --delay 3 --run-id nov19-smoke
python3 scripts/run_cifar_chunked.py conv1_2 conv2_1 conv2_2 --delay 1 5 --run-id nov19-endpoints
python3 scripts/run_cifar_chunked.py conv1_2 --delay 2 3 4 --run-id nov19-intermediate
python3 scripts/run_cifar_chunked.py conv1_2 --delay 3 --run-id nov19-replay-check
```

Console logs, the plan and the 27-row `verified-programs.csv` are under
`obj_dir/verification/ram-latency-p0/`. Per-case logs and manifests are in
the named run directories. The measured files predate the commit that
packages the changes, so use the recorded source hashes with the Git revision.

The November 20 pilot runs six pending L=3 cases across Conv2_1 and Conv2_2.
Expect six case PASS lines and a final `PASS sweep` line naming
`obj_dir/verification/cifar_chunked/runs/nov20-pilot/programs.csv`. The six rows
must have `applied_delay=3` and `correctness=PASS`.

```sh
python3 scripts/run_cifar_chunked.py conv2_1 conv2_2 --delay 3 --run-id nov20-pilot
```

After the pilot clears, stage the remaining 12 cases for November 20–21:

```sh
python3 scripts/run_cifar_chunked.py conv2_1 conv2_2 --delay 2 4 --run-id nov21-remaining
```

## Historical GEMM provenance

The stored GEMM source digests predate `77c25c0`. The original
`make gemm-check` and `make gemm-large-check` recorded source-hash mismatches.
The historical data comparisons reproduced the saved RTL counters, states
and command intervals and independently checked outputs and fetch replay.
The [original verification receipt](cifar-conv1-results/verification.json)
lists the changed paths for both suites. The historical hash checks remain
recorded as provenance mismatches. Neither GEMM target was rerun for this
handoff.
