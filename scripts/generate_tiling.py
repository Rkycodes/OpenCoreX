"""Generate compact larger-vector kernels and independent logical references."""
import argparse
from pathlib import Path
import generate_matvec_1x16_16x32 as rv

ROOT = Path(__file__).resolve().parents[1]
HEX = ROOT / "programs/tiling/hex"
SIZES = (16, 32, 64, 128)
MODES = ("streaming", "tiled", "offload")
RAM_WORDS = 262144
VECTOR, CONSTANTS, SIGNATURE, DONE = 0x100, 0x400, 0x440, 0x444
KERNEL, KERNEL_END, MATRIX, OUTPUT = 0x1000, 0x5000, 0x20000, 0x30000
MASK = 0xffffffff


def s32(value):
    value &= MASK
    return value - (1 << 32) if value & (1 << 31) else value


def operands(k):
    # A full-width, mixed-sign deterministic maximum workload. Include signed
    # boundaries and zero; multiplication and accumulation wrap even at K=16.
    maximum_vector = [s32((i + 1) * 0x9e3779b9 ^ (i * i * 0x85ebca6b)) for i in range(128)]
    maximum_vector[:4] = [-2147483648, 2147483647, -1, 0]
    maximum_matrix = [[s32((i + 3) * 0x45d9f3b + (j + 7) * 0x27d4eb2d
                          ^ (i * j + 11) * 0x165667b1) for j in range(32)] for i in range(128)]
    vector, logical = maximum_vector[:k], maximum_matrix[:k]
    expected = []
    for j in range(32):
        total = 0
        for i in range(k):
            total = (total + ((vector[i] * logical[i][j]) & MASK)) & MASK
        expected.append(total)
    assert len(set(expected)) == 32
    assert any(x < 0 for x in vector) and any(x > 0 for x in vector)
    assert any(abs(vector[i] * logical[i][j]) > MASK for i in range(k) for j in range(32))
    serialized = [logical[i][j] & MASK for j in range(32) for i in range(k)]
    return vector, logical, serialized, expected


def program(mode, k):
    if mode in ("streaming", "tiled"):
        code = [rv.lw(r, 0, CONSTANTS + 4 * i) for i, r in enumerate((5, 6, 7, 8, 9))]
        outer = KERNEL + 4 * len(code)
        accumulators = (11,) if mode == "streaming" else (11, 15, 16, 17)
        code += [rv.addi(10, 5, 0), rv.addi(13, 9, 0)]
        code += [rv.addi(r, 0, 0) for r in accumulators]
        inner = KERNEL + 4 * len(code)
        code += [rv.lw(12, 10)]
        for column, accumulator in enumerate(accumulators):
            code += [rv.lw(18, 6, 4 * k * column), rv.mul(14, 12, 18), rv.add(accumulator, accumulator, 14)]
        code += [rv.addi(10, 10, 4), rv.addi(6, 6, 4), rv.addi(13, 13, -1)]
        code += [rv.bne(13, 0, inner - (KERNEL + 4 * len(code)))]
        code += [rv.sw(r, 7, 4 * i) for i, r in enumerate(accumulators)]
        if mode == "tiled":
            code += [rv.addi(6, 6, 12 * k)]
        code += [rv.addi(7, 7, 4 * len(accumulators)), rv.addi(8, 8, -len(accumulators))]
        code += [rv.bne(8, 0, outer - (KERNEL + 4 * len(code)))]
        code += [rv.lw(31, 0, SIGNATURE), rv.sw(31, 0, DONE), rv.jal(0, 0)]
        assert len(code) == (23 if mode == "streaming" else 39)
    elif mode == "offload":
        code = [rv.lw(1, 0, CONSTANTS + 24)]
        for offset, literal in ((0, 0), (4, 16), (8, 4), (12, 20), (16, 8), (20, 12)):
            code += [rv.lw(2, 0, CONSTANTS + literal), rv.sw(2, 1, offset)]
        code += [rv.addi(2, 0, 1), rv.sw(2, 1, 24), rv.lw(3, 1, 28), rv.addi(4, 0, 6),
                 rv.encode_r_type(funct7=0, rs2=4, rs1=3, funct3=7, rd=5), rv.addi(6, 0, 2),
                 rv.bne(5, 6, 16), rv.lw(31, 0, SIGNATURE), rv.sw(31, 0, DONE),
                 rv.jal(0, 0), rv.jal(0, 0)]
        assert len(code) == 24
    else:
        raise ValueError(mode)
    assert KERNEL + ((len(code) + 3) // 4) * 16 <= KERNEL_END
    return code


def word_address(address):
    assert address % 4 == 0 and 0 <= address // 4 < RAM_WORDS
    return address // 4


def image_text(mode, k):
    vector, _, weights, expected = operands(k)
    constants = [VECTOR, MATRIX, OUTPUT, 32, k, 4*k, 0x40000000] + [0] * 57
    constants[(SIGNATURE - CONSTANTS) // 4] = rv.COMPLETION_SIGNATURE
    code = program(mode, k)
    regions = [(0, [rv.jal(0, KERNEL), 0, 0, 0]),
               (VECTOR, [v & MASK for v in vector]), (CONSTANTS, constants),
               (KERNEL, code + [0] * (-len(code) % 4)), (MATRIX, weights), (OUTPUT, [0] * 32)]
    limits = (0x10, 0x300, 0x500, KERNEL_END, 0x30000, 0x40000)
    lines = []
    for (start, words), limit in zip(regions, limits):
        assert start + 4 * len(words) <= limit <= RAM_WORDS * 4
        lines += [f"@{word_address(start):08x}"] + [f"{v:08x}" for v in words]
    for (start, words), (next_start, _) in zip(regions, regions[1:]):
        assert start + 4 * len(words) <= next_start
    return "\n".join(lines) + "\n", "".join(f"{v:08x}\n" for v in expected)


def generate(check=False):
    HEX.mkdir(parents=True, exist_ok=True)
    for k in SIZES:
        for mode in MODES:
            image, expected = image_text(mode, k)
            for name, text in ((f"{mode}_{k}.hex", image), (f"expected_{k}.hex", expected)):
                path = HEX / name
                if check:
                    assert path.read_text() == text, path
                else:
                    path.write_text(text)
        assert operands(k)[0] == operands(128)[0][:k]
        assert operands(k)[1] == operands(128)[1][:k]
    print("PASS: tiling images, signed prefixes, references, encoding reach and allocations")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    generate(parser.parse_args().check)
