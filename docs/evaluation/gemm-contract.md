# Square GEMM contract — October 17, 2026

Implement C=A×B for square order S=16 and 32. Verify 16 first, then 32.
Reuse scalar streaming, four-output tiling and the existing single-lane digital
matvec accelerator. No production RTL, ISA, cache or historical-image changes.
All methods use signed 32-bit operands, low-32-bit products and modulo-2^32 sums.

A and C are row-major. B is column-major, B[k,j] at B_base+4*(j*S+k).
All methods receive identical preplaced operands in these layouts. Host placement
and any conversion from another input layout are excluded for every method.
There is no timed transpose or claim about row-major-input end-to-end cost.
Reference C[i,j] is calculated from logical A[i,k] and B[k,j] before serialization.
Order 16 is the top-left logical submatrix of the deterministic order-32 inputs,
with each workload packed at its own stride. Mixed signs and full-width values
exercise multiply and accumulation overflow.

| Region | Byte addresses |
|---|---|
| Boot / full refill line | 0x00000–0x0000F |
| Constants/control | 0x00400–0x004FF |
| Signature / accepted completion | 0x440 / 0x444 |
| Kernel | 0x01000–0x04FFF |
| A | 0x10000–0x1FFFF |
| B | 0x20000–0x2FFFF |
| C | 0x30000–0x3FFFF |
| MMIO | 0x40000000–0x40000FFF |

RAM_WORDS=262144, BUFFER_WORDS=128, MAX_OUTPUTS=128, MAC_LANES=1 for every run.
The offload has a provisioned 512-byte private vector buffer, versus 31 writable
CPU registers shared by arithmetic, pointers and control. No CPU data cache.
Keep the existing 512-byte direct-mapped instruction cache, two-cycle hits,
four serial refill reads, single backing port, one outstanding read, arbitration,
blocking and write timing. Cache bypass/enabled and uniform L={1,2,5,10,20}
give 60 complete-job configurations. Reset cache and vector metadata per job.

CPU allocation: x5 current A row; x19 B base; x6 walking B address; x7 walking
C address; x21 S; x20 rows remaining; x8 columns remaining; x9 K=S;
x10 walking A element; x13 reduction counter; x12 A element; x18 B element;
x14 product; x11 streaming sum, or x11/x15/x16/x17 tiled sums; x31 signature.
Each row resets x6 to B base and x8 to S, executes the existing compact dot-product
loops, then advances A by 4S and decrements rows. C advances naturally through
the complete row-major output. Streaming loads A for every product. Tiling keeps
four completed-output sums in registers, loads A once per four products, and
uses B load offsets 0/4S/8S/12S. No partial-sum spills or tail handling (S%4=0).
Pointer literals load through supported x0-relative LW. Branch/JAL and immediate
reach, alignment, disjointness, RAM and full refill-line bounds are asserted.

Offload allocation: x1 MMIO, x5 A-row pointer, x7 C-row pointer, x19 B base,
x9 K, x21 output count, x20 rows remaining, x2 descriptor/command scratch,
x3/x4/x6 status scratch, x31 signature. Configure all six
descriptor fields per row and launch START=1, with no REUSE bit. Read/check
status after each blocking command. Advance A and C by 4S, decrement rows, repeat.
Every cold command invalidates/repopulates the vector metadata internally.
The CPU/cache remain live between row commands. Failure parks without signature.

Whole-job time is reset release through accepted RKYC completion store inclusive.
Include all row-loop control, launches, validation, blocking and status handling.
Record each command's START-to-final-output interval separately and sum its busy
cycles; do not substitute one-row execution time for complete-job time.

Expected complete-job counts: A reads S³ / S³÷4 / S² for streaming/tiled/offload;
B reads S³ and C writes S² for all. CPU MUL and accumulating ADD counts S³ each,
or S³ offload MACs. Offload executes S cold commands, 7S MMIO writes and S status
reads. Literal, signature, completion and MMIO traffic are separate. Check every
C element, unchanged A/B, exact operand addresses and counts, no other writes,
request/response ownership and stability, busy gating and completion ordering.
Independent RV32 execution and cache replay must match accepted fetches/misses.
Disjoint CPU-state counts sum to job cycles. Wait and busy counters overlap.
Reconcile cache delta with hits*(2−L)+misses*(6+3L).
