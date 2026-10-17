"""Generate separate square GEMM programs, preplaced operands and logical references."""
import argparse
from pathlib import Path
import generate_matvec_1x16_16x32 as rv

ROOT = Path(__file__).resolve().parents[1]
HEX = ROOT / "programs/gemm/hex"
SIZES, MODES = (16, 32), ("streaming", "tiled", "offload")
CONSTANTS, SIGNATURE, DONE, KERNEL = 0x400, 0x440, 0x444, 0x1000
A, B, C, RAM_WORDS = 0x10000, 0x20000, 0x30000, 262144
MASK = 0xffffffff


def signed(value):
    value &= MASK
    return value - (1 << 32) if value & (1 << 31) else value


def operands(s):
    a = [[signed((i+1)*0x9e3779b9 ^ (k+3)*0x85ebca6b ^ (i*k+7)*0xc2b2ae35)
          for k in range(s)] for i in range(s)]
    b = [[signed((k+3)*0x45d9f3b + (j+7)*0x27d4eb2d ^ (k*j+11)*0x165667b1)
          for j in range(s)] for k in range(s)]
    a[0][:4] = [-2147483648, 2147483647, -1, 0]
    expected = [sum(a[i][k]*b[k][j] for k in range(s)) & MASK
                for i in range(s) for j in range(s)]
    assert len(set(expected)) == s*s
    assert len({tuple(row) for row in a}) == s
    return a, b, expected


def program(mode, s):
    code, labels, branches = [], {}, []
    def label(name): labels[name] = KERNEL + 4*len(code)
    def emit(*words): code.extend(words)
    def bne(a, b, name):
        branches.append((len(code), a, b, name))
        emit(0)
    if mode in ("streaming", "tiled"):
        emit(*[rv.lw(r, 0, CONSTANTS+4*i) for i, r in enumerate((5, 19, 7, 21, 9))], rv.addi(20, 21, 0))
        label("row")
        emit(rv.addi(6, 19, 0), rv.addi(8, 21, 0))
        label("column")
        accum = (11,) if mode == "streaming" else (11, 15, 16, 17)
        emit(rv.addi(10, 5, 0), rv.addi(13, 9, 0), *[rv.addi(r, 0, 0) for r in accum])
        label("reduction")
        emit(rv.lw(12, 10))
        for j, r in enumerate(accum):
            emit(rv.lw(18, 6, 4*s*j), rv.mul(14, 12, 18), rv.add(r, r, 14))
        emit(rv.addi(10, 10, 4), rv.addi(6, 6, 4), rv.addi(13, 13, -1))
        bne(13, 0, "reduction")
        emit(*[rv.sw(r, 7, 4*j) for j, r in enumerate(accum)])
        if mode == "tiled": emit(rv.addi(6, 6, 12*s))
        emit(rv.addi(7, 7, 4*len(accum)), rv.addi(8, 8, -len(accum)))
        bne(8, 0, "column")
        emit(rv.addi(5, 5, 4*s), rv.addi(20, 20, -1))
        bne(20, 0, "row")
    elif mode == "offload":
        emit(rv.lw(1, 0, CONSTANTS+24), rv.lw(5, 0, CONSTANTS), rv.lw(7, 0, CONSTANTS+8),
             rv.lw(19, 0, CONSTANTS+4), rv.lw(9, 0, CONSTANTS+16),
             rv.lw(21, 0, CONSTANTS+12), rv.addi(20, 21, 0))
        label("row")
        emit(rv.sw(5, 1, 0), rv.sw(9, 1, 4), rv.sw(19, 1, 8),
             rv.lw(2, 0, CONSTANTS+20), rv.sw(2, 1, 12), rv.sw(7, 1, 16), rv.sw(21, 1, 20),
             rv.addi(2, 0, 1), rv.sw(2, 1, 24), rv.lw(3, 1, 28), rv.addi(4, 0, 6),
             rv.encode_r_type(funct7=0, rs2=4, rs1=3, funct3=7, rd=6), rv.addi(4, 0, 2))
        bne(6, 4, "failure")
        emit(rv.addi(5, 5, 4*s), rv.addi(7, 7, 4*s), rv.addi(20, 20, -1))
        bne(20, 0, "row")
    else:
        raise ValueError(mode)
    emit(rv.lw(31, 0, SIGNATURE), rv.sw(31, 0, DONE), rv.jal(0, 0))
    label("failure")
    if mode == "offload": emit(rv.jal(0, 0))
    for index, a, b, target in branches:
        code[index] = rv.bne(a, b, labels[target]-(KERNEL+4*index))
    assert len(code) == {"streaming":29, "tiled":45, "offload":29}[mode]
    return code


def generate(check=False):
    HEX.mkdir(parents=True, exist_ok=True)
    for s in SIZES:
        a, b, expected = operands(s)
        for mode in MODES:
            code = program(mode, s)
            constants = [A, B, C, s, s, 4*s, 0x40000000] + [0]*57
            constants[(SIGNATURE-CONSTANTS)//4] = rv.COMPLETION_SIGNATURE
            regions = [(0, [rv.jal(0, KERNEL), 0, 0, 0]), (CONSTANTS, constants),
                       (KERNEL, code+[0]*(-len(code)%4)),
                       (A, [v & MASK for row in a for v in row]),
                       (B, [b[k][j] & MASK for j in range(s) for k in range(s)]), (C, [0]*(s*s))]
            lines = []
            for (start, words), end in zip(regions, (0x10,0x500,0x5000,0x20000,0x30000,0x40000)):
                assert start%4 == 0 and start+4*len(words) <= end <= 4*RAM_WORDS
                lines += [f"@{start//4:08x}"] + [f"{v:08x}" for v in words]
            text = "\n".join(lines)+"\n"
            p = HEX/f"{mode}_{s}.hex"
            if check: assert p.read_text() == text, p
            else: p.write_text(text)
        p, text = HEX/f"expected_{s}.hex", "".join(f"{v:08x}\n" for v in expected)
        if check: assert p.read_text() == text, p
        else: p.write_text(text)
    small_a, small_b, _ = operands(16)
    large_a, large_b, _ = operands(32)
    assert small_a == [row[:16] for row in large_a[:16]]
    assert small_b == [row[:16] for row in large_b[:16]]
    print("PASS: GEMM images, logical references, nested inputs, address/encoding bounds")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    generate(parser.parse_args().check)
