# OpenCoreX PIM Module Interfaces v0.1

## Status and Scope

This document defines the planned module boundaries and cycle-level contracts
for the first functional PIM RTL. It supplements
[`pim-architecture-v0.1.md`](pim-architecture-v0.1.md). It is an interface
specification, not an RTL implementation.

All modules use:

- SystemVerilog explicit `logic` ports,
- asynchronous active-high reset (`posedge reset`),
- 32-bit byte addresses and data words,
- request transfer on `req_valid && req_ready`, and
- no response backpressure in version 1.

The existing `opencorex_memory_subsystem` remains unchanged as the verified
Phase 1 baseline. New files are integrated through a separate
`opencorex_pim_subsystem` top.

## Shared Definitions: `pim_pkg.sv`

`pim_pkg.sv` is compiled before every module or testbench that imports it. It
contains architectural definitions shared by more than one module and nothing
that depends on synthesis parameters.

### Included definitions

- `pim_descriptor_t`
- `pim_error_t`
- PIM MMIO register offsets
- `COMMAND` bit positions
- `STATUS` and `STATUS_CLEAR` bit positions
- capability feature-bit positions

The descriptor contains:

| Field | Width | Meaning |
|---|---:|---|
| `vector_base` | 32 | Byte address of vector element zero |
| `vector_length` | 32 | Number of active 32-bit vector words |
| `matrix_base` | 32 | Byte address of the first matrix column |
| `matrix_column_stride` | 32 | Byte distance between matrix-column starts |
| `output_base` | 32 | Byte address of output element zero |
| `output_count` | 32 | Number of output words |

`REUSE_VECTOR` remains part of the snapshotted raw command word rather than the
descriptor because it changes command behavior, not the memory layout.

### Excluded definitions

The package does not contain:

- controller or validator FSM states,
- parameter-derived index widths,
- counters,
- internal request destinations,
- private module control signals, or
- synthesized parameter values.

Those definitions stay local to the modules that own them.

## CPU Address Router: `cpu_address_router.sv`

### Responsibility

The router accepts the CPU's single request channel and directs each request to
exactly one destination:

1. implemented RAM,
2. the PIM MMIO page, or
3. invalid/unmapped space.

It also blocks new CPU traffic while PIM is busy and routes delayed read
responses back from the selected destination.

The router is a decoder. The existing `memory_interconnect` remains the arbiter
between the CPU RAM path and the PIM memory requester.

### Parameters

| Parameter | Default/meaning |
|---|---|
| `RAM_BASE` | `32'h0000_0000` |
| `RAM_WORDS` | Supplied by the integration top |
| `PIM_MMIO_BASE` | `32'h4000_0000` |
| `PIM_MMIO_BYTES` | 4096 |

The implemented RAM end is calculated without 32-bit wraparound. Addresses in
the larger reserved RAM window but beyond the synthesized `RAM_WORDS` capacity
are invalid in the current system.

### Ports

| Direction | Port | Width | Meaning |
|---|---|---:|---|
| input | `clk` | 1 | Clock |
| input | `reset` | 1 | Asynchronous active-high reset |
| input | `cpu_req_valid` | 1 | CPU request is present |
| output | `cpu_req_ready` | 1 | Selected destination accepts the request |
| input | `cpu_req_write` | 1 | One for write, zero for read |
| input | `cpu_req_addr` | 32 | CPU byte address |
| input | `cpu_req_wdata` | 32 | CPU write data |
| output | `cpu_rsp_valid` | 1 | Selected read response is valid |
| output | `cpu_rsp_rdata` | 32 | Selected read data |
| output | `ram_req_valid` | 1 | Request toward CPU side of memory interconnect |
| input | `ram_req_ready` | 1 | RAM path accepts request |
| output | `ram_req_write` | 1 | RAM request type |
| output | `ram_req_addr` | 32 | RAM request address |
| output | `ram_req_wdata` | 32 | RAM write data |
| input | `ram_rsp_valid` | 1 | RAM-path read response |
| input | `ram_rsp_rdata` | 32 | RAM-path read data |
| output | `mmio_req_valid` | 1 | Request toward PIM MMIO slave |
| input | `mmio_req_ready` | 1 | PIM MMIO accepts request |
| output | `mmio_req_write` | 1 | MMIO request type |
| output | `mmio_req_addr` | 32 | Full MMIO byte address |
| output | `mmio_req_wdata` | 32 | MMIO write data |
| input | `mmio_rsp_valid` | 1 | MMIO read response |
| input | `mmio_rsp_rdata` | 32 | MMIO read data |
| input | `pim_busy` | 1 | Blocks CPU requests after an accepted launch |

### Behavioral contract

- During reset, both downstream request-valid outputs and CPU ready/response
  outputs are zero.
- While `pim_busy=1`, no CPU request is forwarded and `cpu_req_ready=0`.
- When not blocked, exactly one downstream `req_valid` may be asserted.
- A selected request and its payload remain stable until its handshake.
- An accepted read records `response_source` as RAM or PIM MMIO.
- Writes do not change `response_source` because they produce no response.
- The router accepts no new CPU request while an earlier CPU read response is
  pending. The current CPU already obeys this restriction.
- A returning response is forwarded only from the recorded source.
- Reset clears pending-response state; a late pre-reset response is ignored.
- An invalid address reaches neither downstream target and causes a simulation
  failure until an architectural access-fault channel exists.

The registered `pim_busy` value changes after the accepted start edge. The
start store therefore receives MMIO ready and completes; only the following CPU
request is blocked.

## PIM MMIO Registers: `pim_mmio_regs.sv`

### Responsibility

This module owns:

- the six software-programmable configuration registers,
- MMIO offset and access decoding,
- sticky `done`, `error`, and `error_code`,
- command launch qualification,
- write-one-to-clear behavior,
- capability and parameter-reporting reads, and
- the idle-only buffer-invalidation action.

It does not execute validation, access shared memory, store vector data, or
perform arithmetic.

### Parameters

| Parameter | Default/meaning |
|---|---|
| `MMIO_BASE` | `32'h4000_0000` |
| `BUFFER_WORDS` | 16, power of two |
| `MAX_OUTPUTS` | 32 |
| `MAC_LANES` | 1 and constrained to 1 in version 1 |

### Ports

| Direction | Port | Width/type | Meaning |
|---|---|---|---|
| input | `clk` | 1 | Clock |
| input | `reset` | 1 | Asynchronous active-high reset |
| input | `req_valid` | 1 | Routed CPU MMIO request |
| output | `req_ready` | 1 | Request acceptance |
| input | `req_write` | 1 | MMIO access type |
| input | `req_addr` | 32 | Full byte address |
| input | `req_wdata` | 32 | Write data |
| output | `rsp_valid` | 1 | Registered read response, one cycle after acceptance |
| output | `rsp_rdata` | 32 | MMIO read value |
| input | `ctrl_busy` | 1 | Controller active status |
| input | `ctrl_done_set` | 1 | Pulse after final result-write handshake |
| input | `ctrl_error_set` | 1 | Pulse requesting first-fault capture |
| input | `ctrl_error_code` | `pim_error_t` | Controller or validator error |
| input | `buffer_valid_count` | 32 | Zero-extended buffer occupancy |
| input | `buffer_vector_full` | 1 | Resident vector is complete |
| input | `resident_vector_base` | 32 | Buffer reuse metadata |
| input | `resident_vector_length` | 32 | Buffer reuse metadata |
| output | `cmd_start` | 1 | Handshake-qualified one-cycle accepted-launch event |
| output | `cmd_descriptor` | `pim_descriptor_t` | Stable programmed descriptor presented for snapshot |
| output | `cmd_word` | 32 | Raw command bits presented for snapshot and validation |
| output | `buffer_invalidate` | 1 | One-cycle accepted invalidation action |
| output | `status_error` | 1 | Sticky error state used by launch qualification |

### Transaction timing

- An aligned implemented write completes on `req_valid && req_ready` and has no
  response.
- An aligned implemented read completes its request handshake, then asserts
  `rsp_valid` with registered data during the following cycle.
- Only one MMIO read may be pending.
- Unsupported or unaligned accesses cause the defined device error or the
  simulation-fatal invalid-access behavior; they never alias another register.
- A transport handshake means the device consumed the request. It does not mean
  that a command or configuration change was semantically legal.

### Command qualification

- A `START` write while idle and without an uncleared prior error produces
  `cmd_start` on that accepted transfer.
- The controller snapshots `cmd_descriptor` and `cmd_word` on the same edge.
- Reserved command bits and unsupported modes are checked by the sequential
  validator after busy asserts for an accepted `START`.
- A start while busy reports `START_WHILE_BUSY`; the active operation continues.
- A start while sticky error is set is rejected and preserves the original
  first-fault code.
- A write with `START=0` has no launch or modifier effect when reserved and
  unsupported bits are zero. With `START=0`, MMIO itself records the sticky
  `RESERVED_COMMAND_BIT` or `UNSUPPORTED_MODE` error because no validator
  request is launched. Reserved bits take priority when both are present.
- Configuration, `STATUS_CLEAR`, and `BUFFER_CONTROL` writes while busy are
  consumed but rejected with `CONFIG_WRITE_WHILE_BUSY`; active state is not
  modified.
- Version-1 writes to the reserved interrupt registers are simulation-fatal
  invalid accesses. Their reads return zero until interrupt behavior is defined.

## Command Validator: `pim_command_validator.sv`

### Responsibility

The validator checks one condition at a time, in deterministic order, without
issuing memory traffic or modifying vector-buffer state.

Launch-gate errors (`START_WHILE_BUSY` and an uncleared prior error) are handled
by MMIO command qualification. The sequential validator then checks:

1. reserved command bits,
2. unsupported mode,
3. vector length,
4. output count,
5. address alignment,
6. matrix-column stride,
7. 64-bit address arithmetic overflow,
8. physical RAM bounds,
9. output/input overlap, and
10. reuse metadata and `vector_full`.

### Parameters

| Parameter | Meaning |
|---|---|
| `RAM_BASE` | Implemented RAM base |
| `RAM_WORDS` | Implemented RAM capacity |
| `BUFFER_WORDS` | Maximum vector length |
| `MAX_OUTPUTS` | Maximum output count |

### Ports

| Direction | Port | Width/type | Meaning |
|---|---|---|---|
| input | `clk` | 1 | Clock |
| input | `reset` | 1 | Asynchronous active-high reset |
| input | `start` | 1 | Begin validation of stable snapshotted inputs |
| input | `descriptor` | `pim_descriptor_t` | Active descriptor |
| input | `command_word` | 32 | Active command bits |
| input | `buffer_vector_full` | 1 | Reuse eligibility |
| input | `resident_vector_base` | 32 | Current resident metadata |
| input | `resident_vector_length` | 32 | Current resident metadata |
| output | `busy` | 1 | Validator is checking |
| output | `result_valid` | 1 | One-cycle validation-result pulse |
| output | `result_ok` | 1 | Descriptor is valid |
| output | `result_error_code` | `pim_error_t` | First failed check |

The validator latches or relies on controller-held stable active inputs at
`start`. It ignores a second start while busy; verification treats such an
internal event as a protocol error.

## Vector Buffer: `pim_vector_buffer.sv`

### Responsibility

This module owns the private vector words, validity metadata, occupancy,
resident base/length, and explicit invalidation behavior.

### Parameters

| Parameter | Definition |
|---|---|
| `BUFFER_WORDS` | Power-of-two entry count, default 16 |
| `INDEX_W` | `(BUFFER_WORDS <= 1) ? 1 : $clog2(BUFFER_WORDS)` |
| `COUNT_W` | `$clog2(BUFFER_WORDS + 1)` |

### Ports

| Direction | Port | Width | Meaning |
|---|---|---:|---|
| input | `clk` | 1 | Clock |
| input | `reset` | 1 | Asynchronous active-high metadata reset |
| input | `begin_vector` | 1 | Commit new resident base/length and clear valid state |
| input | `new_vector_base` | 32 | New resident base |
| input | `new_vector_length` | 32 | New resident length |
| input | `invalidate` | 1 | Clear all valid and resident metadata while idle |
| input | `query_index` | `INDEX_W` | Entry whose valid state is queried |
| output | `query_valid` | 1 | Combinational per-entry validity |
| input | `read_enable` | 1 | Initiate synchronous data read |
| input | `read_index` | `INDEX_W` | Read entry |
| output | `read_data` | 32 | Registered read result one cycle later |
| input | `write_enable` | 1 | Store returned vector word |
| input | `write_index` | `INDEX_W` | Written entry |
| input | `write_data` | 32 | Written word |
| output | `valid_count` | `COUNT_W` | Valid resident entries |
| output | `vector_full` | 1 | Count equals nonzero resident length |
| output | `resident_vector_base` | 32 | Reuse/debug metadata |
| output | `resident_vector_length` | 32 | Reuse/debug metadata |

### Port and metadata rules

- `read_enable` and `write_enable` are never asserted together.
- A same-cycle read/write collision is illegal regardless of address.
- Physical data bits are not cleared on reset or invalidation.
- Invalid entries are never exposed as usable operands.
- A previously invalid entry becomes valid on its accepted write edge.
- `valid_count` increments only when writing a previously invalid entry.
- `vector_full` is computed using the post-write count on the final fill edge.
- `begin_vector` and `invalidate` are mutually exclusive with data-port use.
- The response-bypass operand is captured by the controller from memory
  response data; it is not an additional buffer port.

## MAC: `pim_mac.sv`

### Responsibility and ports

| Direction | Port | Width | Meaning |
|---|---|---:|---|
| input | `clk` | 1 | Clock |
| input | `reset` | 1 | Asynchronous active-high reset |
| input | `start` | 1 | Begin one multiply-accumulate operation |
| input | `operand_a` | 32 | Signed vector operand |
| input | `operand_b` | 32 | Signed weight operand |
| input | `accumulator_in` | 32 | Current modulo accumulator |
| output | `busy` | 1 | Operation in progress |
| output | `done` | 1 | One-cycle result-valid pulse |
| output | `result` | 32 | Low-word product added modulo `2^32` |

The first implementation completes one cycle after an accepted `start`, but the
controller waits for `done` and therefore does not encode that latency. Operands
are sampled only when `start && !busy`.

## PIM Controller: `pim_controller.sv`

### Responsibility

The controller owns active command state, the operation FSM, vector/weight
scheduling, the single outstanding-read invariant, response destination, MAC
sequencing, result writes, and completion/error events.

### Interface groups

| Group | Principal signals |
|---|---|
| Command | `cmd_start`, `cmd_descriptor`, `cmd_word` |
| Status events | `busy`, `done_set`, `error_set`, `error_code` |
| Validator | `validator_start`, stable active descriptor/command, `validator_result_valid`, `validator_result_ok`, `validator_error_code` |
| Buffer control | begin-vector metadata, valid query, synchronous read, response write, occupancy/status inputs |
| MAC control | `mac_start`, operands/accumulator, `mac_busy`, `mac_done`, `mac_result` |
| Shared memory | `mem_req_valid`, `mem_req_ready`, `mem_req_write`, `mem_req_addr`, `mem_req_wdata`, `mem_rsp_valid`, `mem_rsp_rdata` |

### Controller invariants

- `cmd_start` snapshots descriptor and command into active registers, sets
  `busy`, and begins validation.
- The controller keeps its active descriptor stable until completion or reset.
- Validation failure causes no external memory request and no vector-buffer
  mutation.
- A memory request and payload remain stable while stalled.
- At most one read is outstanding.
- No second read request is issued between a read handshake and its response.
- The controller remembers whether the pending response is a vector or weight.
- A missing vector response writes the buffer and latches the same data through
  response bypass as the active vector operand.
- A resident vector operand is obtained through the synchronous buffer-read
  state.
- `done_set` pulses only after the final output-write handshake.
- Reset clears active state and suppresses all later requests from the aborted
  command. Any late pre-reset response is ignored.

## Accelerator Wrapper: `pim_accelerator.sv`

### Responsibility

The wrapper composes MMIO, validator, controller, vector buffer, and MAC. Its
external contract has only three groups:

| Group | Signals |
|---|---|
| Clock/reset | `clk`, `reset` |
| CPU MMIO slave | request/ready plus read-response signals |
| PIM memory requester | request/ready plus read-response signals |

It additionally exports registered `pim_busy` to the CPU address router. The
wrapper performs width adaptation such as zero-extending internal
`valid_count` for the 32-bit MMIO register.

The wrapper contains wiring but no independent command policy. Architectural
state belongs to MMIO, controller, or vector-buffer modules as defined above.

## Integrated Top: `opencorex_pim_subsystem.sv`

The new top instantiates:

1. `opencorex_core`
2. `cpu_address_router`
3. `pim_accelerator`
4. existing `memory_interconnect`
5. existing `synchronous_memory_adapter`

Its external RAM and CPU-error ports remain compatible with
`opencorex_memory_subsystem` so the existing physical memory and benchmark
testbench patterns can be reused. The old subsystem is not removed or silently
changed.

## Implementation and Verification Order

1. Implement `pim_pkg.sv` definitions and compile-order support.
2. Implement and unit-test `cpu_address_router`.
3. Implement and unit-test `pim_mmio_regs`.
4. Implement and unit-test `pim_command_validator`.
5. Implement and unit-test `pim_vector_buffer`.
6. Implement and unit-test `pim_mac` against the golden arithmetic model.
7. Implement and unit-test `pim_controller` using mocked validator, buffer,
   MAC, and variable-latency memory behavior where useful.
8. Integrate and test `pim_accelerator`.
9. Integrate and test `opencorex_pim_subsystem` with the existing core,
   interconnect, adapter, RAM, and matrix-vector benchmark.

RTL implementation does not begin until the port names, widths, timing, and
ownership in this document have been reviewed for consistency.
