"""Independent RV32 execution and accepted-fetch cache replay, without RTL."""
from collections import Counter
from pathlib import Path
from scaling_trace import image_words, signed, replay

ROOT = Path(__file__).resolve().parents[1]


def trace(mode, k):
    mem = image_words(ROOT / f"programs/gemm/hex/{mode}_{k}.hex")
    original = mem.copy()
    expected = [int(v, 16) for v in (ROOT / f"programs/gemm/hex/expected_{k}.hex").read_text().split()]
    regs, pc, addresses, descriptors = [0] * 32, 0, [], {}
    traffic = Counter()
    outputs = 0
    commands = 0

    def read(address):
        assert address % 4 == 0 and 0 <= address < 1048576
        if 0x10000 <= address < 0x10000 + 4*k*k:
            traffic["vector_reads"] += 1
        elif 0x20000 <= address < 0x20000 + 4*k*k:
            traffic["matrix_reads"] += 1
        else:
            assert 0x400 <= address < 0x41c or address == 0x440
            traffic["cpu_other_reads"] += 1
            traffic["signature_reads" if address == 0x440 else "literal_reads"] += 1
        return mem[address // 4]

    for _ in range(400000):
        assert pc == 0 or 0x1000 <= pc < 0x5000
        addresses.append(pc)
        ins = mem[pc // 4]
        op, rd, f3, rs1, rs2 = ins & 127, (ins >> 7) & 31, (ins >> 12) & 7, (ins >> 15) & 31, (ins >> 20) & 31
        a, b, nxt = regs[rs1], regs[rs2], pc + 4
        if op == 0x13:
            assert f3 == 0
            regs[rd] = a + signed(ins >> 20, 12)
        elif op == 0x33:
            if ins >> 25 == 1:
                assert f3 == 0
                regs[rd] = signed(a) * signed(b)
                traffic["cpu_muls"] += 1
            elif f3 == 0 and ins >> 25 == 0:
                regs[rd] = a + b
                assert rd in (11, 15, 16, 17) and rs1 == rd and rs2 == 14
                traffic["cpu_accumulating_adds"] += 1
            elif f3 == 7 and ins >> 25 == 0:
                regs[rd] = a & b
            else:
                raise AssertionError(hex(ins))
        elif op == 3:
            assert f3 == 2
            address = (a + signed(ins >> 20, 12)) & 0xffffffff
            if address == 0x4000001c:
                assert mode == "offload" and outputs == commands*k
                traffic["mmio_reads"] += 1
                regs[rd] = 10
            else:
                regs[rd] = read(address)
        elif op == 0x23:
            assert f3 == 2
            imm = ((ins >> 25) << 5) | ((ins >> 7) & 31)
            address = (a + signed(imm, 12)) & 0xffffffff
            if address >= 0x40000000:
                assert mode == "offload" and address < 0x40001000
                traffic["mmio_writes"] += 1
                descriptors[address - 0x40000000] = b
                if address == 0x40000018:
                    assert descriptors == {0: 0x10000+4*k*commands, 4: k, 8: 0x20000, 12: 4*k, 16: 0x30000+4*k*commands, 20: k, 24: 1}
                    vector = [read(0x10000 + 4*(commands*k+i)) for i in range(k)]
                    for j in range(k):
                        total = 0
                        for i in range(k):
                            total = (total + signed(vector[i]) * signed(read(0x20000 + 4*(k*j+i)))) & 0xffffffff
                            traffic["offload_macs"] += 1
                        assert total == expected[commands*k+j]
                        mem[0xc000+commands*k+j] = total
                    commands += 1
                    outputs += k
                    traffic["output_writes"] += k
            else:
                assert address % 4 == 0
                if address == 0x444:
                    assert b == 0x524b5943 and outputs == k*k
                    traffic["completion_writes"] += 1
                    assert mem[0x4000:0x4000+k*k] == original[0x4000:0x4000+k*k]
                    assert mem[0x8000:0x8000+k*k] == original[0x8000:0x8000+k*k]
                    assert mem[0xc000:0xc000+k*k] == expected
                    return addresses, traffic
                assert address == 0x30000 + 4*outputs and b == expected[outputs]
                mem[address // 4] = b
                outputs += 1
                traffic["output_writes"] += 1
        elif op == 0x63:
            imm = ((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 63) << 5) | (((ins >> 8) & 15) << 1)
            assert f3 == 1
            if a != b:
                nxt = pc + signed(imm, 13)
        elif op == 0x6f:
            imm = ((ins >> 31) << 20) | (((ins >> 12) & 255) << 12) | (((ins >> 20) & 1) << 11) | (((ins >> 21) & 1023) << 1)
            regs[rd], nxt = pc + 4, pc + signed(imm, 21)
        else:
            raise AssertionError(hex(ins))
        regs = [v & 0xffffffff for v in regs]
        regs[0], pc = 0, nxt
    raise AssertionError("trace did not complete")


if __name__ == "__main__":
    for k in (16, 32):
        for mode in ("streaming", "tiled", "offload"):
            addresses, traffic = trace(mode, k)
            print(mode, k, len(addresses), sum(m for _, m in replay(addresses)), dict(traffic))
