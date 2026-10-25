# CPU MAC extension

Contract selected before RTL implementation on `feat/cpu-mac-benchmark`.

`mac rd, rs1, rs2` computes `rd = (old(rd) + rs1 * rs2) mod 2^32`.
R-format encoding:

| Bits | Value |
|---|---|
| 31:25 | funct7 = 0000001 |
| 24:20 | rs2 |
| 19:15 | rs1 |
| 14:12 | funct3 = 000 |
| 11:7 | rd (also accumulator source) |
| 6:0 | custom-0 = 0001011 (0x0b) |

Other custom-0 function combinations are illegal. This is an
OpenCoreX extension, not a standard RISC-V scalar MAC.

Signed two's-complement and unsigned multiplication give identical low 32
bits. No widening, saturation, carry flag, or overflow exception. x0 reads
zero and ignores writes. Software initializes the accumulator; the existing
register file has no reset. Aliasing uses pre-instruction values.
Exactly one writeback commits the result.

Keep the two-port register file. DECODE captures rs1/rs2 into A/B. R_EXEC
uses the existing multiplier and saves the low product in ALUOut. New state
MAC_ACCUM multiplexes read port 1 to rd and adds its asynchronous value to
ALUOut with the existing ALU adder. ALU_WRITEBACK commits the sum. Two unused
ALU source selections route ALUOut and read port 1; no temporary register or
arithmetic unit is added. Append the new state to preserve existing state IDs.

Minimum latency is six cycles: FETCH, FETCH_CAPTURE, DECODE, R_EXEC,
MAC_ACCUM, ALU_WRITEBACK, plus unchanged fetch stalls. MUL/ADD each take
five, so MAC saves four cycles against a pair at minimum fetch latency.
Cache fetch timing is measured separately. Reset before writeback cancels
the MAC through the existing controller/datapath reset convention.

Alternative: a third asynchronous register-file port could capture rd during
DECODE, costing a 32:1 read mux, wiring, and an accumulator latch. A new
multiply-plus-add datapath could then eliminate MAC_ACCUM, at the cost of
an additional adder and a longer critical path. Sharing the existing adder
still requires two arithmetic states, so a third port provides no cycle gain
for that implementation. The selected serialized read/add is the smallest
change and preserves arithmetic resources. Equal-clock comparisons remain
conditional on timing closure; no area or timing result is claimed.

Reserved custom encodings enter the existing sticky ERROR state without
writeback. Reset and x0 behavior follow the existing core. Instruction cache,
memory interfaces, RAM response policy, and PIM are unchanged.

The ALU decoder needs no change: this function pair already selects MUL
during R_EXEC. Only the controller's exact custom-opcode check makes the
instruction legal, and MAC_ACCUM uses the existing default ADD ALU operation.
Encoding example: `mac x11, x12, x18` is `0x0326058b`.
