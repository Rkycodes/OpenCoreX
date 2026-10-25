"""Generate 64/128 square jobs without rewriting the recorded 16/32 study."""
import argparse
from pathlib import Path
from generate_gemm import (ROOT, MODES, CONSTANTS, SIGNATURE, KERNEL, A, B, C,
                           RAM_WORDS, MASK, signed, program)
import generate_matvec_1x16_16x32 as rv

HEX = ROOT / "programs/gemm-large/hex"
SIZES = (64, 128)


def operands(s):
    a = [[signed((i+1)*0x9e3779b9 ^ (k+3)*0x85ebca6b ^ (i*k+7)*0xc2b2ae35)
          for k in range(s)] for i in range(s)]
    b = [[signed((k+3)*0x45d9f3b + (j+7)*0x27d4eb2d ^ (k*j+11)*0x165667b1)
          for j in range(s)] for k in range(s)]
    a[0][:4] = [-2147483648, 2147483647, -1, 0]
    expected = [sum(a[i][k]*b[k][j] for k in range(s)) & MASK
                for i in range(s) for j in range(s)]
    assert len({tuple(row) for row in a}) == s
    assert len({tuple(b[k][j] for k in range(s)) for j in range(s)}) == s
    # Equal output words are legitimate under modulo-2^32 arithmetic.
    assert len(set(expected)) > s*s//2
    return a, b, expected


def generate(check=False, modes=MODES):
    HEX.mkdir(parents=True, exist_ok=True)
    for s in SIZES:
        a, b, expected = operands(s)
        for mode in modes:
            code = program(mode, s)
            constants = [A, B, C, s, s, 4*s, 0x40000000] + [0]*57
            constants[(SIGNATURE-CONSTANTS)//4] = rv.COMPLETION_SIGNATURE
            regions = [(0, [rv.jal(0, KERNEL), 0, 0, 0]), (CONSTANTS, constants),
                       (KERNEL, code+[0]*(-len(code)%4)),
                       (A, [v & MASK for row in a for v in row]),
                       (B, [b[k][j] & MASK for j in range(s) for k in range(s)]),
                       (C, [0]*(s*s))]
            lines = []
            for (start, words), end in zip(regions, (0x10,0x500,0x5000,0x20000,0x30000,0x40000)):
                assert start%4 == 0 and start+4*len(words) <= end <= 4*RAM_WORDS
                lines += [f"@{start//4:08x}"] + [f"{v:08x}" for v in words]
            path, text = HEX/f"{mode}_{s}.hex", "\n".join(lines)+"\n"
            if check: assert path.read_text() == text, path
            else: path.write_text(text)
        path, text = HEX/f"expected_{s}.hex", "".join(f"{v:08x}\n" for v in expected)
        if check: assert path.read_text() == text, path
        else: path.write_text(text)
    small_a, small_b, _ = operands(64)
    large_a, large_b, _ = operands(128)
    assert small_a == [row[:64] for row in large_a[:64]]
    assert small_b == [row[:64] for row in large_b[:64]]
    print("PASS: large GEMM images, references, prefixes and full region bounds", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    generate(parser.parse_args().check)
