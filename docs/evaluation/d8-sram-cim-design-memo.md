# Next architecture decision: D8 digital → SRAM CIM → RRAM

Recommendation: implement packed signed-8-bit D8 digital first, validate a
precision-matched CPU reference, then model a matrix-resident SRAM CIM variant,
and finally change the declared array technology to RRAM. This latency branch
adds no CIM datapath RTL. The present signed-32-bit baseline remains D0-32.

| Decision | Packed D8 digital | Matrix-resident SRAM CIM |
|---|---|---|
| Arithmetic | Four signed int8 operands packed little-endian per 32-bit word; explicit extraction/sign extension; int32 accumulation/output | Same signed int8 inputs/weights and int32 ideal functional result; separately declare bit-serial/parallel mapping, partial sums and sensing precision |
| First scheduling choice | Keep one digital MAC lane initially, with a packed-word unpack buffer; isolates packing from added parallelism | Explicit array invocation plus latency/event model; functional dot products first, circuit-derived timing separately |
| Vector traffic for 16 values | Four RAM words on cold fill; zero on verified reuse | Same SRAM vector buffer and policy for a matched comparison |
| Matrix behavior | First D8 streams 128 packed matrix words per command; no silent matrix residency | Blocking LOAD_MATRIX fetches/programs once; COMPUTE reuses until reset, invalidation or replacement |
| Main verification burden | Byte lane/endian order, −128 sign extension, ±127 products, int32 accumulation, packed strides/alignment/tails, reuse and unchanged status protocol | Load/compute state transitions, programming completion, metadata matching, invalidation/reset, atomic rejection, cold programming and warm reuse, mapped arithmetic and partial sums |
| Physical estimates | Standard-cell synthesis/place-and-route with a declared library, SRAM macro characterization, and activity-based power for CPU + digital datapath | Declared SRAM compute macro/array, periphery and interconnect model (NeuroSim or characterized macro); synthesize shared RTL control separately |

The strongest existing 16×32 resident CPU remains the D0-32 comparator.
For D8, use the same quantized signed-byte values, column-major layout, packed
RAM words, initial RAM placement, wrap/overflow policy and int32 outputs for
CPU, digital and CIM. This CPU currently lacks byte loads, shifts and signed
byte-extraction instructions. Loading pre-expanded int32 values would change
placement/traffic assumptions. The next task should define a minimal byte
extraction ISA route (e.g. SRLI/SRAI plus masks) or a clearly labeled alternative,
then implement the CPU unpack reference and one-lane D8 accelerator together.
Keep looped scalable and resident diagnostic CPU versions separately named;
neither an int32-only CPU nor a wider digital lane is a precision/parallelism
matched comparator without explicit qualifications.

For SRAM CIM, introduce versioned LOAD_MATRIX, COMPUTE and INVALIDATE_MATRIX
commands. Residency metadata includes validity, source base, rows, columns,
stride, precision and mapping. Replacement invalidates immediately; validity
returns only after both external fetch and programming complete. Reset clears
validity. COMPUTE with absent/mismatched metadata must reject before data traffic.
Report four vector/matrix residency combinations and include initial matrix
programming in finite-N averages. D8 streaming versus CIM matrix-resident
execution intentionally changes residency; add a matrix-resident digital
control before attributing that difference specifically to in-array computing.

Keep functional OpenCoreX cycles/events separate from physical costs.
The [official NeuroSim version index](https://github.com/neurosim/NeuroSim)
lists SRAM/RRAM and distinct digital-CIM evaluation configurations. Pin the
chosen version, technology, subarray mapping and precision rather than importing
a default network result. Use NeuroSim/characterized circuits for compute-array
and peripheral estimates; use a synthesis/library/SRAM-macro flow for the actual
CPU and digital MAC, buffers and RTL controllers. An SRAM buffer feeding a
digital MAC is not an SRAM CIM compute array. Assign every buffer, interconnect,
accumulator and memory operation exactly one energy/latency owner to avoid
double counting. External-memory response timing/energy needs a separate
declared memory model; this synthetic delay sweep supplies neither.

RRAM follows only after SRAM mapping and accounting are stable: hold precision,
logical capacity, workload and initial mapping/parallelism constant, then
declare changed programming/read latency, sensing, variability, endurance and
nonidealities. Report technology-specific optimized mappings separately.
No physical superiority claim follows from RTL cycle counts.
