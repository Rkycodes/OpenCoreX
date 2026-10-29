"""Independent RV32 execution of conv1 images; predicts fetches and RAM traffic."""
from array import array
from collections import Counter
from pathlib import Path

import generate_conv1 as workload


def signed(value, bits=32):
    value &= (1 << bits)-1
    return value - (1 << bits) if value & (1 << (bits-1)) else value


def image_words(path):
    memory, address = {}, 0
    for word in path.read_text().split():
        if word.startswith("@"):
            address = int(word[1:],16)*4
        else:
            memory[address] = int(word,16)
            address += 4
    return memory


def trace(case, mode, record):
    mem = image_words(workload.ROOT/record["image"])
    original = mem.copy()
    refs = [[int(v,16) for v in (workload.IMAGES/f"{case}_{stage}.hex").read_text().split()]
            for stage in ("raw","biased","final","patches")]
    registers, pc, phase = [0]*32, 0, 0
    fetches, counters, descriptor = array("I"), Counter(), {}
    commands = 0

    def read(address):
        assert address % 4 == 0 and address in mem, hex(address)
        if 0x10000 <= address < 0x100f0:
            assert phase == 1
            key = "input_reads"
        elif 0x11000 <= address < 0x11870:
            assert phase == 2
            key = "patch_reads"
        elif 0x20000 <= address < 0x21b00:
            assert phase == 2
            key = "weight_reads"
        elif 0x22000 <= address < 0x22100:
            assert phase == 3 and address == 0x22000 + 4*(counters["bias_reads"]%64)
            key = "bias_reads"
        elif 0x30000 <= address < 0x31400:
            assert phase == 3 and address == 0x30000 + 4*counters["post_reads"]
            assert mem[address] == refs[0][counters["post_reads"]]
            key = "post_reads"
        else:
            assert 0x500 <= address < 0x600 or address == 0x440, hex(address)
            key = "signature_reads" if address == 0x440 else "literal_reads"
        counters[key] += 1
        return mem[address]

    def write(address, value):
        assert address % 4 == 0
        if 0x11000 <= address < 0x11870:
            i = counters["patch_writes"]
            assert phase == 1 and address == 0x11000+4*i and value == refs[3][i]
            counters["patch_writes"] += 1
        elif 0x30000 <= address < 0x31400:
            key, reference = ("raw_writes",refs[0]) if phase == 2 else ("final_writes",refs[2])
            i = counters[key]
            assert phase in (2,3) and address == 0x30000+4*i and value == reference[i], (key,i)
            counters[key] += 1
        else:
            raise AssertionError(hex(address))
        mem[address] = value

    for _ in range(2_000_000):
        assert pc == 0 or 0x1000 <= pc < 0x5000, hex(pc)
        if pc == record["bias_pc"]:
            i = counters["biased_checks"]
            assert registers[11] == refs[1][i], (case,mode,"biased",i)
            counters["biased_checks"] += 1
        fetches.append(pc)
        instruction = mem[pc]
        op = instruction & 127
        rd, f3, rs1, rs2 = (instruction>>7)&31, (instruction>>12)&7, (instruction>>15)&31, (instruction>>20)&31
        a,b,nxt = registers[rs1],registers[rs2],pc+4
        if op == 0x13:
            assert f3 == 0
            registers[rd] = a + signed(instruction>>20,12)
        elif op == 0x33:
            if instruction>>25 == 1:
                assert f3 == 0
                registers[rd] = signed(a)*signed(b)
                counters["cpu_dot_muls" if phase == 2 else "packing_muls"] += 1
            elif instruction>>25 == 0 and f3 == 0:
                registers[rd] = a+b
            elif instruction>>25 == 0 and f3 == 7:
                registers[rd] = a&b
            else:
                raise AssertionError(hex(instruction))
        elif op == 0x0b:
            assert instruction>>25 == 1 and f3 == 0 and phase == 2
            registers[rd] += signed(a)*signed(b)
            counters["cpu_dot_macs"] += 1
        elif op == 3:
            assert f3 == 2
            address = (a+signed(instruction>>20,12)) & 0xffffffff
            if address == 0x4000001c:
                assert mode == "offload" and counters["raw_writes"] == commands*64
                registers[rd] = 10
                counters["mmio_reads"] += 1
            else:
                registers[rd] = read(address)
        elif op == 0x23:
            immediate = (instruction>>25)<<5 | ((instruction>>7)&31)
            address = (a+signed(immediate,12)) & 0xffffffff
            assert f3 == 2
            if address == 0x448:
                assert b == phase+1 and b <= 3
                phase = b
                counters["phase_writes"] += 1
                mem[address] = b
            elif address == 0x444:
                assert b == 0x524b5943 and phase == 3
                for key,n in (("patch_writes",540),("raw_writes",1280),("final_writes",1280),
                              ("biased_checks",1280),("post_reads",1280),("bias_reads",1280),
                              ("input_reads",390),("phase_writes",3)):
                    assert counters[key] == n, (key,counters[key],n)
                assert [mem[0x30000+4*i] for i in range(1280)] == refs[2]
                for address,value in original.items():
                    if not (0x11000 <= address < 0x11870 or 0x30000 <= address < 0x31400 or address == 0x448):
                        assert mem[address] == value, hex(address)
                counters["completion_writes"] += 1
                counters["fetches"] = len(fetches)
                counters["commands"] = commands
                return fetches,counters
            elif 0x40000000 <= address < 0x40001000:
                assert mode == "offload" and phase == 2
                offset = address-0x40000000
                assert offset in (0,4,8,12,16,20,24)
                counters["mmio_writes"] += 1
                descriptor[offset] = b
                if offset == 24:
                    assert descriptor == {0:0x11000+108*commands,4:27,8:0x20000,12:108,
                                          16:0x30000+256*commands,20:64,24:1}
                    assert counters["mmio_reads"] == commands
                    vector = [read(descriptor[0]+4*k) for k in range(27)]
                    for f in range(64):
                        total = 0
                        for k in range(27):
                            total = (total + signed(vector[k])*signed(read(0x20000+108*f+4*k))) & 0xffffffff
                            counters["pim_macs"] += 1
                        write(descriptor[16]+4*f,total)
                    commands += 1
            else:
                write(address,b)
        elif op == 0x63:
            immediate = ((instruction>>31)<<12) | (((instruction>>7)&1)<<11) | (((instruction>>25)&63)<<5) | (((instruction>>8)&15)<<1)
            assert f3 in (0,1)
            if (a == b) == (f3 == 0):
                nxt = pc+signed(immediate,13)
        elif op == 0x6f:
            immediate = ((instruction>>31)<<20) | (((instruction>>12)&255)<<12) | (((instruction>>20)&1)<<11) | (((instruction>>21)&1023)<<1)
            registers[rd],nxt = pc+4,pc+signed(immediate,21)
        else:
            raise AssertionError(hex(instruction))
        registers = [v & 0xffffffff for v in registers]
        registers[0],pc = 0,nxt
    raise AssertionError("CPU image failed to complete")


if __name__ == "__main__":
    manifest,_ = workload.generate(True)
    for case in workload.CASES:
        for mode in workload.MODES:
            addresses,counters = trace(case,mode,manifest["records"][f"{case}_{mode}"])
            assert counters["weight_reads"] == 34560
            assert counters["patch_reads"] == dict(streaming=34560,tiled=8640,mac=8640,offload=540)[mode]
            print("PASS:",case,mode,len(addresses),"CPU instructions",dict(counters),flush=True)
