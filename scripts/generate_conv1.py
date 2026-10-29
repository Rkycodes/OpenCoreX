"""Generate the two conv1 proof cases and four CPU-executed program images."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import time

import generate_matvec_1x16_16x32 as rv
from conv1_reference import convolve

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "obj_dir/verification/conv1"
IMAGES = BUILD / "images"
H, W, CHANNELS, FILTERS, K = 4, 5, 3, 64, 27
POSITIONS, OUTPUTS = H * W, H * W * FILTERS
MASK = 0xffffffff
INPUT, PATCH, WEIGHTS, BIAS, OUTPUT = 0x10000, 0x11000, 0x20000, 0x22000, 0x30000
KERNEL, CONSTANTS, SIGNATURE, DONE, PHASE = 0x1000, 0x500, 0x440, 0x444, 0x448
MODES = ("streaming", "tiled", "mac", "offload")
CASES = ("small", "wrap")


def signed(value):
    value &= MASK
    return value - 2**32 if value & 2**31 else value


def workload(case):
    image = [[[
        ((17*c + 7*y + 3*x + 1) % 19) - 9 if case == "small" else
        signed((c+1)*0x9e3779b9 ^ (y+3)*0x85ebca6b ^ (x+7)*0xc2b2ae35)
        for x in range(W)] for y in range(H)] for c in range(CHANNELS)]
    weights = [[[[(
        ((11*f + 5*c + 3*r + s + c*s + f*r + 1) % 13) - 6 if case == "small" else
        signed((f+3)*0x45d9f3b ^ (c+5)*0x27d4eb2d ^ (r+7)*0x165667b1 ^ (s+11)*0x85ebca6b)
    ) for s in range(3)] for r in range(3)] for c in range(CHANNELS)] for f in range(FILTERS)]
    biases = [(-1 if f % 2 else 1) * (f % 11 + 1) if case == "small" else
              signed((f+1)*0x7f4a7c15) or 1 for f in range(FILTERS)]
    if case == "wrap":
        image[0][0][:4] = [-2**31, 2**31-1, -1, 0]
        # Directed bias overflow at an interior pixel: raw +1/-1 cross signed limits.
        weights[0] = [[[0]*3 for _ in range(3)] for _ in range(3)]
        weights[1] = [[[0]*3 for _ in range(3)] for _ in range(3)]
        weights[0][0][0][1] = 1  # y=1,x=1 reads X[0,0,1] = INT_MAX
        weights[1][0][0][0] = 1  # y=1,x=1 reads X[0,0,0] = INT_MIN
        biases[0], biases[1] = 1, -1
    assert case in CASES and all(biases)
    return image, weights, biases


def pack(image):
    patches = []
    for y in range(H):
        for x in range(W):
            for c in range(CHANNELS):
                for r in range(3):
                    for s in range(3):
                        iy, ix = y+r-1, x+s-1
                        patches.append(image[c][iy][ix] & MASK
                                       if 0 <= iy < H and 0 <= ix < W else 0)
    return patches


def serialize(weights):
    return [value & MASK for kernel in weights for plane in kernel
            for row in plane for value in row]


def mapped(patches, weights, biases):
    raw, biased, final = [], [], []
    for p in range(POSITIONS):
        for f in range(FILTERS):
            accumulator = 0
            for k in range(K):
                accumulator = (accumulator + signed(patches[p*K+k]) *
                               signed(weights[f*K+k])) & MASK
            word = (accumulator + biases[f]) & MASK
            raw.append(accumulator)
            biased.append(word)
            final.append(0 if word & 2**31 else word)
    return raw, biased, final


class Assembler:
    def __init__(self):
        self.code, self.labels, self.fixups, self.constants = [], {}, [], []

    def emit(self, *words):
        self.code.extend(words)

    def label(self, name):
        assert name not in self.labels
        self.labels[name] = KERNEL + 4*len(self.code)

    def load(self, register, value):
        if value not in self.constants:
            self.constants.append(value)
        address = CONSTANTS + 4*self.constants.index(value)
        assert address < CONSTANTS + 256
        self.emit(rv.lw(register, 0, address))

    def branch(self, a, b, label, equal=False):
        self.fixups.append((len(self.code), "beq" if equal else "bne", a, b, label))
        self.emit(0)

    def jump(self, label):
        self.fixups.append((len(self.code), "jal", 0, 0, label))
        self.emit(0)

    def phase(self, value):
        self.emit(rv.addi(1, 0, value), rv.sw(1, 0, PHASE))

    def finish(self):
        for index, kind, a, b, target in self.fixups:
            offset = self.labels[target] - (KERNEL + 4*index)
            if kind == "jal":
                self.code[index] = rv.jal(0, offset)
            else:
                self.code[index] = rv.encode_b_type(
                    immediate=offset, rs1=a, rs2=b, funct3=0 if kind == "beq" else 1)
        assert KERNEL + 4*((len(self.code)+3)//4*4) <= 0x5000
        return self.code


def program(mode):
    a = Assembler()
    a.phase(1)
    # Runtime patch packing: oy=x3, ox=x4, c=x5, kr=x6, kc=x7.
    a.load(1, INPUT); a.load(2, PATCH)
    a.emit(rv.addi(13, 0, -1), rv.addi(14, 0, H), rv.addi(15, 0, W),
           rv.addi(16, 0, CHANNELS), rv.addi(18, 0, H*W), rv.addi(3, 0, 0))
    a.label("pack_y"); a.emit(rv.addi(4, 0, 0))
    a.label("pack_x"); a.emit(rv.addi(5, 0, 0))
    a.label("pack_c"); a.emit(rv.addi(6, 0, 0))
    a.label("pack_r"); a.emit(rv.addi(7, 0, 0))
    a.label("pack_s")
    a.emit(rv.add(8, 3, 6), rv.addi(8, 8, -1),
           rv.add(9, 4, 7), rv.addi(9, 9, -1))
    for register, bound in ((8,13), (8,14), (9,13), (9,15)):
        a.branch(register, bound, "padding", equal=True)
    a.emit(rv.mul(10, 5, 18), rv.mul(11, 8, 15), rv.add(10, 10, 11),
           rv.add(10, 10, 9), rv.mul(10, 10, 14), rv.add(10, 10, 1),
           rv.lw(12, 10))
    a.jump("pack_store")
    a.label("padding"); a.emit(rv.addi(12, 0, 0))
    a.label("pack_store"); a.emit(rv.sw(12, 2), rv.addi(2, 2, 4))
    for register, limit, label in ((7,16,"pack_s"), (6,16,"pack_r"),
                                   (5,16,"pack_c"), (4,15,"pack_x"), (3,14,"pack_y")):
        a.emit(rv.addi(register, register, 1)); a.branch(register, limit, label)
    a.phase(2)
    a.load(5, PATCH); a.load(19, WEIGHTS); a.load(7, OUTPUT)
    a.emit(rv.addi(21, 0, FILTERS), rv.addi(9, 0, K), rv.addi(20, 0, POSITIONS))
    if mode == "offload":
        a.load(1, 0x40000000)
        a.label("compute_position")
        a.emit(rv.sw(5,1,0), rv.sw(9,1,4), rv.sw(19,1,8),
               rv.addi(2,0,4*K), rv.sw(2,1,12), rv.sw(7,1,16),
               rv.sw(21,1,20), rv.addi(2,0,1), rv.sw(2,1,24),
               rv.lw(3,1,28), rv.addi(4,0,6),
               rv.encode_r_type(funct7=0,rs2=4,rs1=3,funct3=7,rd=6), rv.addi(4,0,2))
        a.branch(6,4,"failure")
    else:
        a.label("compute_position"); a.emit(rv.addi(6,19,0),rv.addi(8,21,0))
        a.label("compute_tile")
        accumulators = (11,) if mode == "streaming" else (11,15,16,17)
        a.emit(rv.addi(10,5,0),rv.addi(13,9,0),
               *[rv.addi(r,0,0) for r in accumulators])
        a.label("reduction")
        a.emit(rv.lw(12,10))
        for j, register in enumerate(accumulators):
            a.emit(rv.lw(18,6,4*K*j))
            if mode == "mac":
                a.emit(rv.mac(register,12,18))
            else:
                a.emit(rv.mul(14,12,18),rv.add(register,register,14))
        a.emit(rv.addi(10,10,4),rv.addi(6,6,4),rv.addi(13,13,-1))
        a.branch(13,0,"reduction")
        a.emit(*[rv.sw(register,7,4*j) for j,register in enumerate(accumulators)])
        if len(accumulators) == 4:
            a.emit(rv.addi(6,6,12*K))
        a.emit(rv.addi(7,7,4*len(accumulators)),rv.addi(8,8,-len(accumulators)))
        a.branch(8,0,"compute_tile")
    a.emit(rv.addi(5,5,4*K))
    if mode == "offload":
        a.emit(rv.addi(7,7,4*FILTERS))
    a.emit(rv.addi(20,20,-1)); a.branch(20,0,"compute_position")
    a.phase(3)
    a.load(5,OUTPUT); a.load(19,BIAS); a.load(23,2**31)
    a.emit(rv.addi(20,0,POSITIONS),rv.addi(21,0,FILTERS))
    a.label("post_position"); a.emit(rv.addi(6,19,0),rv.addi(8,21,0))
    a.label("post_filter")
    a.emit(rv.lw(11,5),rv.lw(12,6),rv.add(11,11,12))
    a.label("bias_check")
    a.emit(rv.encode_r_type(funct7=0,rs2=23,rs1=11,funct3=7,rd=13))
    a.branch(13,0,"post_store",equal=True)
    a.emit(rv.addi(11,0,0))
    a.label("post_store"); a.emit(rv.sw(11,5),rv.addi(5,5,4),rv.addi(6,6,4),rv.addi(8,8,-1))
    a.branch(8,0,"post_filter")
    a.emit(rv.addi(20,20,-1)); a.branch(20,0,"post_position")
    a.emit(rv.lw(31,0,SIGNATURE),rv.sw(31,0,DONE))
    a.label("failure"); a.jump("failure")
    a.finish()
    return a


def hex_text(regions):
    previous_end = 0
    lines = []
    for address, values in sorted(regions):
        assert address % 4 == 0 and previous_end <= address
        previous_end = address + 4*len(values)
        assert previous_end <= 1048576
        lines.append(f"@{address//4:08x}")
        lines.extend(f"{value & MASK:08x}" for value in values)
    return "\n".join(lines)+"\n"


def generate(check=False):
    start = time.perf_counter()
    IMAGES.mkdir(parents=True, exist_ok=True)
    records = {}
    for case in CASES:
        image, weights, biases = workload(case)
        expected = convolve(image,weights,biases)
        patches, serialized = pack(image), serialize(weights)
        assert mapped(patches,serialized,biases) == expected
        assert len(patches) == 540 and len(serialized) == 1728
        assert any(v >= 2**31 for v in expected[1]) and any(expected[2])
        # Sensitivity: independently catch layout changes, omitted bias and omitted ReLU.
        assert mapped(patches,serialized[27:]+serialized[:27],biases)[0] != expected[0]
        assert mapped(patches,serialized,[0]*FILTERS)[1] != expected[1]
        assert expected[1] != expected[2]
        flipped = [[[[row[2-s] for s in range(3)] for row in plane[::-1]]
                    for plane in kernel] for kernel in weights]
        assert convolve(image,flipped,biases)[0] != expected[0]
        if case == "wrap":
            center = (1*W+1)*FILTERS
            assert expected[0][center: center+2] == [0x7fffffff,0x80000000]
            assert expected[1][center: center+2] == [0x80000000,0x7fffffff]
            assert expected[2][center: center+2] == [0,0x7fffffff]
        for name, values in zip(("raw","biased","final","patches"), (*expected,patches)):
            path = IMAGES/f"{case}_{name}.hex"
            text = "".join(f"{v:08x}\n" for v in values)
            if check: assert path.read_text() == text, path
            else: path.write_text(text)
        for mode in MODES:
            assembly = program(mode)
            code = assembly.code + [0]*(-len(assembly.code)%4)
            regions = [(0,[rv.jal(0,KERNEL),0,0,0]),
                       (SIGNATURE,[rv.COMPLETION_SIGNATURE,0,0]),
                       (CONSTANTS,assembly.constants), (KERNEL,code),
                       (INPUT,[v & MASK for plane in image for row in plane for v in row]),
                       (PATCH,[0xa5a5a5a5]*len(patches)), (WEIGHTS,serialized),
                       (BIAS,[v & MASK for v in biases]), (OUTPUT,[0xdeadbeef]*OUTPUTS)]
            path = IMAGES/f"{case}_{mode}.hex"
            text = hex_text(regions)
            if check: assert path.read_text() == text, path
            else: path.write_text(text)
            records[f"{case}_{mode}"] = dict(image=str(path.relative_to(ROOT)),
                bias_pc=assembly.labels["bias_check"], code_words=len(code),
                image_text_bytes=len(text.encode()), placed_words=sum(len(v) for _,v in regions),
                sha256=hashlib.sha256(text.encode()).hexdigest())
    receipt = dict(outputs_per_case=OUTPUTS, cases=list(CASES),
                   stages=["raw","biased","final"], checked_words=OUTPUTS*len(CASES)*3,
                   packed_words_per_case=540, padding_entries_per_case=150,
                   records=records)
    metadata = IMAGES/"manifest.json"
    text = json.dumps(receipt,indent=2)+"\n"
    if check: assert metadata.read_text() == text
    else: metadata.write_text(text)
    print(f"PASS: direct reference vs mapped proof; {receipt['checked_words']} stage words; "
          "padding, ordering, bias, ReLU and directed wrapping",flush=True)
    return receipt, time.perf_counter()-start


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    generate(parser.parse_args().check)
