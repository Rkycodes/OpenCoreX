# OpenCoreX

OpenCoreX is a simulation-focused SystemVerilog project with a multicycle RISC-V CPU, a 32-bit MMIO-controlled processing-in-memory (PIM) accelerator, and a verified shared-memory subsystem. The current matrix-vector workload is a `1 x 16` vector multiplied by a `16 x 32` matrix, producing 32 checked output words.

## Implemented hardware

The non-pipelined CPU executes `ADD`, `SUB`, `AND`, `OR`, `XOR`, `ADDI`, `LW`, `SW`, `BEQ`, `BNE`, `JAL`, and scalar `MUL`. It uses a multicycle controller, register file, and a synchronous unified memory interface. Illegal instructions enter a sticky error state that reset clears. This is a defined subset, not a complete RV32I or RV32IM implementation.

The PIM accelerator uses an MMIO page at `0x4000_0000` for descriptors, command, status, and vector-buffer control. Its validator rejects invalid descriptors before memory traffic. A single MAC lane computes 32-bit wraparound results, and a 16-word private vector buffer supports cold fill and warm reuse. The CPU's accepted `START` store completes before later CPU requests stall; the CPU resumes after PIM completion or rejection. The [integrated subsystem](rtl/system/opencorex_pim_subsystem.sv) routes CPU MMIO separately from RAM and connects the CPU and PIM requesters through the existing memory interconnect and synchronous adapter. The [CPU-only subsystem](rtl/system/opencorex_memory_subsystem.sv) remains available as the Phase 1 baseline.

## Verified benchmarks

The deterministic matrix-vector benchmark checks all 32 outputs against an independent software reference and checks preservation of the inputs. The CPU-only program completes in **23,685 active cycles**. The CPU-driven PIM offload program completes in **4,272 total CPU-program cycles**, including **4,141 cycles from accepted `START` to the final output write**. Cold PIM traffic is 16 vector reads, 512 matrix reads, and 32 output writes. These are simulation cycle and transaction counts for this specific 32-bit functional prototype, not energy, area, technology, or packed 8-bit D8 results.

See the [benchmark specification](programs/matvec_1x16_16x32.md), [PIM offload program](programs/pim_offload_1x16_16x32.md), [evaluation methodology](docs/evaluation/evaluation-methodology.md), and [system regression record](docs/verification/pim-system-regression.md) for measurement boundaries and coverage.

## Run verification

Use Linux or WSL with Verilator 5.x, GNU Make, Bash, and a C++ compiler. From the repository root:

```bash
make verify
```

The full target runs RTL lint, positive self-checking testbenches, and expected-failure memory tests. Individual targets are `make lint`, `make test`, and `make test-errors`. Tests cover CPU execution and reset, memory protocol and faults, PIM modules and variable-latency request behavior, shared-memory integration, CPU-driven system regression, and both benchmark programs. Program images are generated under `programs/hex/` by the generators in `scripts/`.

## Repository layout

| Path | Contents |
|---|---|
| `rtl/cpu/` | CPU datapath, control, ALU, and register file |
| `rtl/memory/` | RAM, memory interconnect, and synchronous adapter |
| `rtl/pim/` | PIM package, MMIO, validation, buffer, MAC, controller, and wrapper |
| `rtl/system/` | CPU address router and CPU-only/PIM subsystem tops |
| `tb/cpu/`, `tb/memory/`, `tb/pim/`, `tb/system/` | Unit and subsystem testbenches |
| `tb/benchmarks/` | CPU and PIM workload testbenches |
| `programs/` | Program generators, workload notes, and generated images in `programs/hex/` |
| `docs/architecture/` | Architecture and historical interface decisions; diagrams in `diagrams/` |
| `docs/verification/`, `docs/evaluation/` | Coverage records and measurement methodology |
| `docs/roadmap.md`, `docs/devlog.md` | Current plan and chronological development record |

Start with the [documentation index](docs/README.md) or the [roadmap](docs/roadmap.md). Some architecture documents are dated design records; their status notes distinguish the original proposal from the implemented RTL. Benchmark tests are grouped under `tb/benchmarks/` because they exercise complete programs and multiple hardware layers.

## Research boundary

The present PIM design is a blocking, single-lane, 32-bit functional model with one outstanding PIM read. The integrated RAM adapter returns reads after a fixed cycle; a separate accelerator test covers ordered variable-latency responses. Packed 8-bit D8, SRAM/RRAM CIM variants, physical area and energy modeling, caches, nonblocking CPU/PIM execution, and full ISA compliance remain future work. See the [roadmap](docs/roadmap.md) for planned studies.

