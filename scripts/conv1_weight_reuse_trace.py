"""Independent RV32 execution and traffic predictions for the weight-buffered job."""
from array import array
from collections import Counter

import generate_conv1_weight_reuse as gen
from conv1_trace import image_words,signed


def trace(case,record):
    mem = image_words(gen.ROOT/record["image"])
    original = mem.copy()
    refs = [[int(v,16) for v in (gen.IMAGES/f"{case}_{name}.hex").read_text().split()]
            for name in ("raw","biased","final","patches")]
    regs,pc,phase = [0]*32,0,0
    addresses,counters,descriptor = array("I"),Counter(),{}
    commands = 0

    def read(address):
        assert address%4 == 0 and address in mem,hex(address)
        if 0x10000 <= address < 0x100f0:
            assert phase == 1
            key = "input_reads"
        elif 0x11000 <= address < 0x11870:
            assert phase == 2
            assert address == 0x11000+4*(counters["patch_reads"]%540)
            key = "patch_reads"
        elif 0x20000 <= address < 0x21b00:
            assert phase == 2 and address == 0x20000+4*counters["weight_reads"]
            key = "weight_reads"
        elif 0x22000 <= address < 0x22100:
            assert phase == 3 and address == 0x22000+4*(counters["bias_reads"]%64)
            key = "bias_reads"
        elif 0x32000 <= address < 0x33400:
            i = counters["post_reads"]
            assert phase == 3 and address == 0x32000+4*((i%64)*20+i//64)
            assert mem[address] == refs[0][i]
            key = "post_reads"
        else:
            assert 0x500 <= address < 0x600 or address == 0x440,hex(address)
            key = "signature_reads" if address == 0x440 else "literal_reads"
        counters[key] += 1
        return mem[address]

    def write(address,value):
        if 0x11000 <= address < 0x11870:
            i = counters["patch_writes"]
            assert phase == 1 and address == 0x11000+4*i and value == refs[3][i]
            key = "patch_writes"
        elif 0x32000 <= address < 0x33400:
            i = counters["raw_writes"]
            assert phase == 2 and address == 0x32000+4*i
            assert value == refs[0][(i%20)*64+i//20]
            key = "raw_writes"
        elif 0x30000 <= address < 0x31400:
            i = counters["final_writes"]
            assert phase == 3 and address == 0x30000+4*i and value == refs[2][i]
            key = "final_writes"
        else:
            raise AssertionError(hex(address))
        counters[key] += 1
        mem[address] = value

    for _ in range(2_000_000):
        assert pc == 0 or 0x1000 <= pc < 0x5000
        if pc == record["bias_pc"]:
            assert regs[11] == refs[1][counters["biased_checks"]]
            counters["biased_checks"] += 1
        addresses.append(pc)
        ins = mem[pc]
        op,rd,f3,rs1,rs2 = ins&127,(ins>>7)&31,(ins>>12)&7,(ins>>15)&31,(ins>>20)&31
        a,b,nxt = regs[rs1],regs[rs2],pc+4
        if op == 0x13:
            assert f3 == 0
            regs[rd] = a+signed(ins>>20,12)
        elif op == 0x33:
            if ins>>25 == 1:
                assert f3 == 0 and phase == 1
                regs[rd] = signed(a)*signed(b)
                counters["packing_muls"] += 1
            elif ins>>25 == 0 and f3 == 0: regs[rd] = a+b
            elif ins>>25 == 0 and f3 == 7: regs[rd] = a&b
            else: raise AssertionError(hex(ins))
        elif op == 3:
            assert f3 == 2
            address = (a+signed(ins>>20,12)) & 0xffffffff
            if address == 0x4000001c:
                assert counters["raw_writes"] == commands*20
                regs[rd] = 10
                counters["mmio_reads"] += 1
            else: regs[rd] = read(address)
        elif op == 0x23:
            assert f3 == 2
            immediate = (ins>>25)<<5 | ((ins>>7)&31)
            address = (a+signed(immediate,12)) & 0xffffffff
            if address == 0x448:
                assert b == phase+1 and b <= 3
                phase = b; mem[address] = b; counters["phase_writes"] += 1
            elif address == 0x444:
                assert b == 0x524b5943 and phase == 3
                for key,value in (("input_reads",390),("patch_writes",540),("patch_reads",34560),
                    ("weight_reads",1728),("raw_writes",1280),("post_reads",1280),
                    ("bias_reads",1280),("biased_checks",1280),("final_writes",1280),
                    ("mmio_writes",448),("mmio_reads",64),("pim_macs",34560),("packing_muls",1170)):
                    assert counters[key] == value,(key,counters[key])
                assert commands == 64 and [mem[0x30000+4*i] for i in range(1280)] == refs[2]
                for address,value in original.items():
                    if not (0x11000 <= address < 0x11870 or 0x30000 <= address < 0x31400 or
                            0x32000 <= address < 0x33400 or address == 0x448):
                        assert mem[address] == value
                counters.update(completion_writes=1,fetches=len(addresses),commands=commands)
                return addresses,counters
            elif 0x40000000 <= address < 0x40001000:
                assert phase == 2
                offset = address-0x40000000
                assert offset in (0,4,8,12,16,20,24)
                descriptor[offset] = b
                counters["mmio_writes"] += 1
                if offset == 24:
                    assert descriptor == {0:0x20000+108*commands,4:27,8:0x11000,12:108,
                                          16:0x32000+80*commands,20:20,24:1}
                    assert counters["mmio_reads"] == commands
                    weights = [read(descriptor[0]+4*k) for k in range(27)]
                    for p in range(20):
                        total = 0
                        for k in range(27):
                            total = (total+signed(weights[k])*signed(read(0x11000+108*p+4*k))) & 0xffffffff
                            counters["pim_macs"] += 1
                        write(descriptor[16]+4*p,total)
                    commands += 1
            else: write(address,b)
        elif op == 0x63:
            immediate = ((ins>>31)<<12) | (((ins>>7)&1)<<11) | (((ins>>25)&63)<<5) | (((ins>>8)&15)<<1)
            assert f3 in (0,1)
            if (a==b) == (f3==0): nxt = pc+signed(immediate,13)
        elif op == 0x6f:
            immediate = ((ins>>31)<<20) | (((ins>>12)&255)<<12) | (((ins>>20)&1)<<11) | (((ins>>21)&1023)<<1)
            regs[rd],nxt = pc+4,pc+signed(immediate,21)
        else: raise AssertionError(hex(ins))
        regs = [value & 0xffffffff for value in regs]
        regs[0],pc = 0,nxt
    raise AssertionError("weight-buffered program did not complete")


if __name__ == "__main__":
    manifest,_ = gen.generate()
    for case in gen.CASES:
        addresses,counters = trace(case,manifest["records"][case])
        print("PASS:",case,len(addresses),"instructions",dict(counters))
