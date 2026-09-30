#!/usr/bin/env python3
"""Generate two 16x32 CPU diagnostics without changing the looped reference."""

from pathlib import Path

import generate_matvec_1x16_16x32 as reference

ROOT = Path(__file__).resolve().parents[1]
HEX = ROOT / "programs" / "hex"
KERNEL_BASE = 0xA00
RAM_WORDS = 1024
MODES = ("resident", "streaming")


def build_kernel(mode: str) -> tuple[list[int], dict[str, int]]:
    if mode not in MODES:
        raise ValueError(mode)
    kernel = [
        reference.addi(5, 0, reference.VECTOR_BASE_BYTE),
        reference.addi(6, 0, reference.MATRIX_BASE_BYTE),
        reference.addi(7, 0, 0x540),
        reference.addi(7, 7, 0x400),
        reference.addi(8, 0, reference.OUTPUT_LENGTH),
    ]
    init_words = len(kernel)
    if mode == "resident":
        for i in range(reference.INPUT_LENGTH):
            kernel.append(reference.lw(15 + i, 5, 4 * i))
    init_words = len(kernel)

    outer_pc = KERNEL_BASE + len(kernel) * 4
    outer = [reference.addi(11, 0, 0)]
    mul_offsets = []
    add_offsets = []
    for i in range(reference.INPUT_LENGTH):
        if mode == "streaming":
            outer.append(reference.lw(13, 5, 4 * i))
        outer.append(reference.lw(12, 6, 4 * i))
        mul_offsets.append(len(outer))
        outer.append(reference.mul(14, 15 + i if mode == "resident" else 13, 12))
        add_offsets.append(len(outer))
        outer.append(reference.add(11, 11, 14))
    outer.extend([
        reference.sw(11, 7),
        reference.addi(6, 6, 64),
        reference.addi(7, 7, 4),
        reference.addi(8, 8, -1),
    ])
    branch_pc = KERNEL_BASE + (len(kernel) + len(outer)) * 4
    outer.append(reference.bne(8, 0, outer_pc - branch_pc))
    outer_words = len(outer)
    kernel.extend(outer)
    kernel.extend([
        reference.lw(31, 7, 0),
        reference.sw(31, 7, 4),
        reference.jal(0, 0),
    ])

    # The completion store is included; the trailing safety JAL is not.
    fetches = 1 + init_words + reference.OUTPUT_LENGTH * outer_words + 2
    assert fetches == (1752 if mode == "resident" else 2248)
    assert len(mul_offsets) == len(add_offsets) == reference.INPUT_LENGTH
    assert KERNEL_BASE > reference.DONE_BASE_BYTE
    assert KERNEL_BASE % 4 == 0
    assert KERNEL_BASE // 4 + len(kernel) <= RAM_WORDS
    assert len(kernel) == 78
    return kernel, {
        "fetches": fetches,
        "outer_pc": outer_pc,
        "last_pc": KERNEL_BASE + (len(kernel) - 1) * 4,
        "outer_words": outer_words,
    }


def write_image(mode: str, kernel: list[int]) -> Path:
    vector = reference.generate_vector()
    matrix = reference.generate_logical_matrix()
    expected = reference.calculate_reference(vector, matrix)
    reference.validate_test_pattern(vector, matrix, expected)
    stored = [int(word, 16) for word in
              (HEX / "matvec_1x16_16x32_expected.hex").read_text().split()]
    assert stored == expected
    weights = reference.serialize_matrix_column_major(matrix)
    assert len(weights) == 512

    regions = [
        (0, [reference.jal(0, KERNEL_BASE)]),
        (reference.VECTOR_BASE_WORD, [reference.to_u32(x) for x in vector]),
        (reference.MATRIX_BASE_WORD, weights),
        (reference.OUTPUT_BASE_WORD, [0] * reference.OUTPUT_LENGTH),
        (reference.SIGNATURE_BASE_WORD, [reference.COMPLETION_SIGNATURE]),
        (reference.DONE_BASE_WORD, [0]),
        (KERNEL_BASE // 4, kernel),
    ]
    for (start, words), (next_start, _) in zip(regions, regions[1:]):
        assert start + len(words) <= next_start, "code/data region overlap"
    assert regions[-1][0] + len(regions[-1][1]) <= RAM_WORDS

    path = HEX / f"matvec_1x16_16x32_{mode}.hex"
    with path.open("w", encoding="utf-8", newline="\n") as image:
        for start, words in regions:
            image.write(f"@{start:08x}\n")
            for word in words:
                image.write(f"{word:08x}\n")
    return path


def main() -> None:
    for mode in MODES:
        kernel, stats = build_kernel(mode)
        path = write_image(mode, kernel)
        print(f"{path.relative_to(ROOT)}: kernel 0x{KERNEL_BASE:03x}.."
              f"0x{stats['last_pc']:03x}, {len(kernel)} words, "
              f"{stats['fetches']} fetches through completion")


if __name__ == "__main__":
    main()
