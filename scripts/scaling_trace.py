"""Independent instruction trace for scaling images; validates scalar outputs too."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def image_words(path):
    words = [0] * 262144
    index = 0
    for token in path.read_text().split():
        if token.startswith("@"):
            index = int(token[1:], 16)
        else:
            words[index] = int(token, 16)
            index += 1
    return words

def signed(value, bits=32):
    return value - (1 << bits) if value & (1 << (bits-1)) else value

def trace(mode, n):
    mem = image_words(ROOT / f"programs/scaling/hex/{mode}_{n}.hex")
    expected=[int(v,16) for v in (ROOT/f"programs/scaling/hex/expected_{n}.hex").read_text().split()]
    outputs=0
    descriptors={}
    regs = [0] * 32
    pc = 0
    addresses = []
    for _ in range(10000):
        assert pc == 0 or 0xa00 <= pc < 0xe00
        addresses.append(pc)
        ins = mem[pc // 4]
        op, rd, f3, rs1, rs2 = ins & 127, (ins >> 7) & 31, (ins >> 12) & 7, (ins >> 15) & 31, (ins >> 20) & 31
        a, b = regs[rs1], regs[rs2]
        nxt = pc + 4
        if op == 0x13:
            assert f3 == 0
            regs[rd] = a + signed(ins >> 20, 12)
        elif op == 0x33:
            if ins >> 25 == 1:
                assert f3 == 0
                regs[rd] = a * b
            elif f3 == 0:
                regs[rd] = a + b
            elif f3 == 7:
                regs[rd] = a & b
            else:
                raise AssertionError(hex(ins))
        elif op == 3:
            addr = (a + signed(ins >> 20, 12)) & 0xffffffff
            regs[rd] = 10 if addr == 0x4000001c else mem[addr // 4]
        elif op == 0x23:
            imm = ((ins >> 25) << 5) | ((ins >> 7) & 31)
            addr = (a + signed(imm, 12)) & 0xffffffff
            if addr < 1048576:
                mem[addr // 4] = b
            else:
                assert mode == "offload" and 0x40000000 <= addr < 0x40001000
                descriptors[addr-0x40000000]=b
                if addr == 0x40000018:
                    assert b==1 and descriptors[4]==16 and descriptors[20]==n
                    for j in range(n):
                        result=sum(signed(mem[(descriptors[0]//4)+i]) *
                                   signed(mem[(descriptors[8]//4)+16*j+i]) for i in range(16)) & 0xffffffff
                        assert result==expected[j]
                        mem[descriptors[16]//4+j]=result
                    outputs=n
            if 0x10000 <= addr < 0x10000+4*n:
                assert addr==0x10000+4*outputs and b==expected[outputs]
                outputs+=1
            if addr == 0x224:
                assert b == 0x524b5943 and outputs==n
                return addresses
        elif op == 0x63:
            imm = ((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 63) << 5) | (((ins >> 8) & 15) << 1)
            assert f3 == 1
            if a != b:
                nxt = pc + signed(imm, 13)
        elif op == 0x6f:
            imm = ((ins >> 31) << 20) | (((ins >> 12) & 255) << 12) | (((ins >> 20) & 1) << 11) | (((ins >> 21) & 1023) << 1)
            regs[rd] = pc + 4
            nxt = pc + signed(imm, 21)
        else:
            raise AssertionError(hex(ins))
        regs = [v & 0xffffffff for v in regs]
        regs[0] = 0
        pc = nxt
    raise AssertionError("trace failed to complete")

def replay(addresses):
    tags = [None] * 32
    events = []
    for addr in addresses:
        index, tag = (addr >> 4) & 31, addr >> 9
        miss = tags[index] != tag
        events.append((addr, miss))
        tags[index] = tag
    return events
