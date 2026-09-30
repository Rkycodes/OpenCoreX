#!/usr/bin/env python3
"""Generate a CPU-driven cold-fill then warm-reuse PIM timing benchmark."""

from pathlib import Path

import generate_matvec_1x16_16x32 as baseline

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / "programs/hex/pim_cold_warm_1x16_16x32.hex"
REFERENCE = ROOT / "programs/hex/matvec_1x16_16x32_expected.hex"
CODE_BASE = 0xA00
LITERAL_ADDR = 0x80
RAM_WORDS = 1024


def build_program() -> list[int]:
    code = [baseline.lw(1, 0, LITERAL_ADDR)]  # x1 = 0x4000_0000

    def write(offset: int, value: int) -> None:
        code.extend((baseline.addi(2, 0, value), baseline.sw(2, 1, offset)))

    write(0x00, 0x100)                 # VECTOR_BASE
    write(0x04, 16)                    # VECTOR_LENGTH
    write(0x08, 0x140)                 # MATRIX_BASE
    write(0x0C, 64)                    # MATRIX_COLUMN_STRIDE
    code.extend((baseline.addi(2, 0, 0x540), baseline.addi(2, 2, 0x400)))
    code.append(baseline.sw(2, 1, 0x10))  # OUTPUT_BASE = 0x940
    write(0x14, 32)                    # OUTPUT_COUNT
    write(0x18, 1)                     # cold START

    # The router holds this STATUS load until the cold command finishes.
    code.append(baseline.lw(3, 1, 0x1C))  # DONE=1, ERROR=0, FULL=1
    code.append(baseline.lw(4, 1, 0x20))  # VALID_COUNT=16
    code.append(baseline.lw(5, 1, 0x2C))  # resident base=0x100
    code.append(baseline.lw(6, 1, 0x30))  # resident length=16
    write(0x28, 2)                     # W1C sticky DONE; preserve buffer
    code.append(baseline.lw(9, 1, 0x1C))  # DONE=0, ERROR=0, FULL=1
    write(0x18, 3)                     # warm START | REUSE_VECTOR
    code.append(baseline.lw(10, 1, 0x1C))  # warm DONE=1, ERROR=0, FULL=1

    code.extend((
        baseline.addi(7, 0, 0x5C0),
        baseline.addi(7, 7, 0x400),
        baseline.lw(31, 7, 0),
        baseline.sw(31, 7, 4),
        baseline.jal(0, 0),
    ))
    assert CODE_BASE > baseline.DONE_BASE_BYTE
    assert CODE_BASE // 4 + len(code) <= RAM_WORDS
    return code


def write_image(code: list[int]) -> None:
    vector = baseline.generate_vector()
    matrix = baseline.generate_logical_matrix()
    expected = baseline.calculate_reference(vector, matrix)
    baseline.validate_test_pattern(vector, matrix, expected)
    assert [int(word, 16) for word in REFERENCE.read_text().split()] == expected
    weights = baseline.serialize_matrix_column_major(matrix)
    regions = [
        (0, [baseline.jal(0, CODE_BASE)]),
        (LITERAL_ADDR // 4, [0x4000_0000]),
        (baseline.VECTOR_BASE_WORD, [baseline.to_u32(x) for x in vector]),
        (baseline.MATRIX_BASE_WORD, weights),
        (baseline.OUTPUT_BASE_WORD, [0] * baseline.OUTPUT_LENGTH),
        (baseline.SIGNATURE_BASE_WORD, [baseline.COMPLETION_SIGNATURE]),
        (baseline.DONE_BASE_WORD, [0]),
        (CODE_BASE // 4, code),
    ]
    for (start, words), (following, _) in zip(regions, regions[1:]):
        assert start + len(words) <= following, "code/data overlap"
    assert regions[-1][0] + len(regions[-1][1]) <= RAM_WORDS
    with IMAGE.open("w", encoding="utf-8", newline="\n") as image:
        for start, words in regions:
            image.write(f"@{start:08x}\n")
            for word in words:
                image.write(f"{word:08x}\n")


def main() -> None:
    code = build_program()
    write_image(code)
    print(f"Generated {IMAGE.relative_to(ROOT)}: {len(code)} kernel words, "
          f"0x{CODE_BASE:03x}..0x{CODE_BASE + 4 * (len(code) - 1):03x}")


if __name__ == "__main__":
    main()