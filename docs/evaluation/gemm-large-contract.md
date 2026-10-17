# Larger square GEMM contract

Extend the [16/32 contract](gemm-contract.md) to S=64 and 128. Keep the same
three kernels, arithmetic, layouts, 1 MiB RAM, 128-word buffer, cache policy,
latencies L={1,2,5,10,20}, and complete-job boundary. Host placement/layout
conversion remain excluded. No production RTL, CPU MAC or accelerator changes.
Use separate images, builds and recorded results. Verify 64 before 128.

At 128, each matrix occupies exactly its 64 KiB allocation; the final C word
is 0x3FFFC. A row fills all buffer indices 0–127. Four-output weight offsets
and the tile skip reach 1536 bytes and still fit the existing signed immediates.
The offload performs 128 cold row commands; verify last-index writes/reads,
final metadata and all 16384 outputs. The harness rejects unsupported S=0/129
before initializing a workload; these are argument checks, not new RTL limit tests.
CPU loop/register allocation is unchanged from the smaller study.

References retain the same logical input formulas and prefix relation. Repeated
32-bit output values are allowed; check every position against its own reference.
Count/sequence checks still reject missing, duplicated or misplaced writes.

For scalable exact replay, record accepted fetches as little-endian uint32 words:
bits 0–30 hold the byte PC, bit 31 the predicted/observed cache-miss flag (zero
under bypass). Compare RTL and independent interpreter streams byte for byte.
Keep compressed predictions plus their SHA-256 identities. Calibrate this binary
trace format against the existing exact 16/32 CSV traces before larger runs.
All operand/state/protocol checks remain active. A 1-billion-cycle watchdog
accommodates the largest streaming run without changing timing.
