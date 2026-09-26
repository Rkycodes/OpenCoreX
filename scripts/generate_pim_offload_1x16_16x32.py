#!/usr/bin/env python3
"""Generate the CPU-driven 32-bit PIM offload benchmark image."""

from pathlib import Path

import generate_matvec_1x16_16x32 as baseline

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / "programs/hex/pim_offload_1x16_16x32.hex"
REFERENCE = ROOT / "programs/hex/matvec_1x16_16x32_expected.hex"

MMIO_BASE_LITERAL = 0x80
VECTOR_BASE = 0x100
MATRIX_BASE = 0x140
OUTPUT_BASE = 0x940
SIGNATURE_BASE = 0x9C0
DONE_BASE = 0x9C4


def build_program() -> list[int]:
    program = [
        baseline.lw(1, 0, MMIO_BASE_LITERAL),  # x1 = MMIO base, from RAM literal
        baseline.addi(2, 0, VECTOR_BASE),
        baseline.sw(2, 1, 0x00),               # VECTOR_BASE
        baseline.addi(2, 0, 16),
        baseline.sw(2, 1, 0x04),               # VECTOR_LENGTH
        baseline.addi(2, 0, MATRIX_BASE),
        baseline.sw(2, 1, 0x08),               # MATRIX_BASE
        baseline.addi(2, 0, 64),
        baseline.sw(2, 1, 0x0C),               # MATRIX_COLUMN_STRIDE
        baseline.addi(2, 0, 0x540),
        baseline.addi(2, 2, 0x400),            # x2 = 0x940
        baseline.sw(2, 1, 0x10),               # OUTPUT_BASE
        baseline.addi(2, 0, 32),
        baseline.sw(2, 1, 0x14),               # OUTPUT_COUNT
        baseline.addi(2, 0, 1),
        baseline.sw(2, 1, 0x18),               # COMMAND.START
        baseline.lw(3, 1, 0x1C),               # STATUS, after busy releases
        baseline.addi(4, 0, 0x6),              # DONE | ERROR mask
        baseline.encode_r_type(
            funct7=0, rs2=4, rs1=3, funct3=0b111, rd=5
        ),                                    # x5 = STATUS & 0x6
        baseline.addi(6, 0, 0x2),              # expected DONE=1, ERROR=0
        baseline.bne(5, 6, 24),                # branch to failure self-loop
        baseline.addi(7, 0, 0x5C0),
        baseline.addi(7, 7, 0x400),            # x7 = 0x9C0
        baseline.lw(31, 7, 0),                # RKYC source
        baseline.sw(31, 7, 4),                # completion at 0x9C4
        baseline.jal(0, 0),                   # success self-loop
        baseline.jal(0, 0),                   # failure self-loop
    ]
    assert len(program) == 27
    assert (len(program) * 4) <= MMIO_BASE_LITERAL
    assert MMIO_BASE_LITERAL + 4 < VECTOR_BASE
    assert program[20] == baseline.bne(5, 6, (26 - 20) * 4)
    return program


def write_image(program: list[int]) -> None:
    vector = baseline.generate_vector()
    matrix = baseline.generate_logical_matrix()
    expected = baseline.calculate_reference(vector, matrix)
    baseline.validate_test_pattern(vector, matrix, expected)
    stored_reference = [
        int(word, 16) for word in REFERENCE.read_text(encoding="utf-8").split()
    ]
    assert stored_reference == expected, "CPU reference image differs from source model"
    serialized_matrix = baseline.serialize_matrix_column_major(matrix)

    with IMAGE.open("w", encoding="utf-8", newline="\n") as image:
        image.write("@00000000\n")
        for instruction in program:
            image.write(f"{instruction:08x}\n")
        image.write(f"@{MMIO_BASE_LITERAL // 4:08x}\n40000000\n")
        image.write(f"@{VECTOR_BASE // 4:08x}\n")
        for word in vector:
            image.write(f"{baseline.to_u32(word):08x}\n")
        image.write(f"@{MATRIX_BASE // 4:08x}\n")
        for word in serialized_matrix:
            image.write(f"{word:08x}\n")
        image.write(f"@{OUTPUT_BASE // 4:08x}\n")
        for _ in range(32):
            image.write("00000000\n")
        image.write(f"@{SIGNATURE_BASE // 4:08x}\n")
        image.write(f"{baseline.COMPLETION_SIGNATURE:08x}\n")
        image.write(f"@{DONE_BASE // 4:08x}\n00000000\n")


def main() -> None:
    program = build_program()
    write_image(program)
    print(f"Generated {IMAGE.relative_to(ROOT)} with {len(program)} instructions")
    print(f"Last instruction: 0x{(len(program) - 1) * 4:03x}")
    print(f"MMIO literal:     0x{MMIO_BASE_LITERAL:03x}")
    print(f"Vector begins:    0x{VECTOR_BASE:03x}")


if __name__ == "__main__":
    main()
