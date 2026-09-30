# Matched memory-response timing policy

Defined before implementation on 2026-09-30.

- The cycle index is the rising edge number after reset release, starting at zero.
  A request is accepted at edge t iff valid && ready immediately before the edge.
- A read accepted at t registers physical RAM data after that edge. Its response
  is consumed at edge t+L: response-valid/data become visible in the interval
  immediately preceding t+L. L=1 reproduces the synchronous adapter.
- Writes update RAM on their acceptance edge; no write response or extra write
  latency is introduced. There is one physical read/write port.
- At most one RAM read is outstanding. RAM ready is low from after read
  acceptance through its response-consumption edge. New reads and writes wait;
  request valid, direction, address, and write data must remain stable while
  backpressured. No response-ready exists; the consumer must sample valid.
- Responses are ordered, exactly once, and routed by the unmodified interconnect
  to the owner of the accepted read. Reset discards pending state; there is no
  reset between cold and warm commands.
- Primary policy: every accepted RAM read, CPU fetch/data or PIM operands, uses
  L in {1,2,5,10,20}. MMIO status remains on the existing one-cycle interface.
- Secondary sensitivity policy: CPU instruction fetches use L=1, while all
  CPU/PIM RAM data reads use the chosen L. Fetch classification uses the CPU's
  actual instruction-address control and the selected RAM requester. This
  explicitly assumes a separate fetch-latency service class on the unified
  single port; it is not the primary unified-memory assumption.
- Both policies use the same response definition for CPU and PIM data reads.
  Neither is a calibrated DRAM model: no banks, row hits, refresh, bus bursts,
  queueing hierarchy, caches, or physical time parameters are modeled.

Whole-program timing is reset release through the accepted completion-signature
store, inclusive. PIM execution is final output edge minus accepted START edge.
Setup/status handling are outside execution. CPU blocked clocks count pending
CPU requests denied acceptance, with PIM-busy clocks reported separately.
Memory wait clocks count an outstanding RAM read with no response on edges
after acceptance and before consumption (L-1 per read), split into fetch, CPU
data, and PIM data. They are overlapping attribution counters, not extra clocks
to add to whole-program time. All 32 outputs must be independently checked on
every command, and operands must remain unchanged.

Hypothesis: with L=1, cold/warm execution differs by one clock despite 16 removed
vector reads. Increasing L may expose those avoided external waits. Observe
the results first; controller-state timing explains them only as an inference.
