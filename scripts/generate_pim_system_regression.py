#!/usr/bin/env python3
"""Generate a CPU-driven PIM system-regression program and memory image."""

from pathlib import Path

import generate_matvec_1x16_16x32 as baseline

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / "programs/hex/pim_system_regression.hex"
REFERENCE = ROOT / "programs/hex/matvec_1x16_16x32_expected.hex"
CODE_BASE = 0xA00
LITERAL_ADDR = 0x80


def build_program() -> list[int]:
    code: list[int] = [baseline.lw(1, 0, LITERAL_ADDR)]

    def write(offset: int, value: int) -> None:
        code.append(baseline.addi(2, 0, value))
        code.append(baseline.sw(2, 1, offset))

    def status() -> None:
        code.append(baseline.lw(3, 1, 0x1C))

    def error_code() -> None:
        code.append(baseline.lw(4, 1, 0x24))

    def launch(command: int) -> None:
        write(0x18, command)

    write(0x00, 0x100)
    write(0x04, 16)
    write(0x08, 0x140)
    write(0x0C, 64)
    code.append(baseline.addi(2, 0, 0x540))
    code.append(baseline.addi(2, 2, 0x400))
    code.append(baseline.sw(2, 1, 0x10))
    write(0x14, 32)

    launch(1)                 # cold fill
    status()
    status()                  # DONE stays set
    error_code()
    launch(3)                 # warm REUSE_VECTOR
    status()
    write(0x28, 2)            # clear DONE
    status()
    write(0x4C, 1)            # invalidate buffer
    status()
    launch(1)                 # refill
    status()

    write(0x04, 15)           # valid descriptor, resident length mismatch
    launch(3)
    status()
    error_code()
    status()                  # sticky ERROR
    error_code()
    launch(1)                 # rejected by sticky error launch gate
    status()
    error_code()
    write(0x28, 4)            # clear ERROR
    status()

    write(0x04, 0)            # invalid descriptor
    launch(1)
    status()
    error_code()
    status()                  # sticky ERROR
    error_code()
    write(0x28, 4)
    status()

    write(0x04, 16)
    launch(1)                 # valid command after clearing ERROR
    status()
    code.append(baseline.addi(7, 0, 0x5C0))
    code.append(baseline.addi(7, 7, 0x400))
    code.append(baseline.lw(31, 7, 0))
    code.append(baseline.sw(31, 7, 4))
    code.append(baseline.jal(0, 0))

    assert CODE_BASE + len(code) * 4 <= 0x1000
    assert len(code) < 384
    return code


def main() -> None:
    vector = baseline.generate_vector()
    matrix = baseline.generate_logical_matrix()
    expected = baseline.calculate_reference(vector, matrix)
    baseline.validate_test_pattern(vector, matrix, expected)
    assert [int(word, 16) for word in REFERENCE.read_text().split()] == expected
    code = build_program()
    with IMAGE.open("w", encoding="utf-8", newline="\n") as image:
        image.write("@00000000\n")
        image.write(f"{baseline.jal(0, CODE_BASE):08x}\n")
        image.write(f"@{LITERAL_ADDR // 4:08x}\n40000000\n")
        image.write("@00000040\n")
        for value in vector:
            image.write(f"{baseline.to_u32(value):08x}\n")
        image.write("@00000050\n")
        for value in baseline.serialize_matrix_column_major(matrix):
            image.write(f"{value:08x}\n")
        image.write("@00000250\n")
        for _ in range(32):
            image.write("00000000\n")
        image.write("@00000270\n")
        image.write(f"{baseline.COMPLETION_SIGNATURE:08x}\n")
        image.write("@00000271\n00000000\n")
        image.write(f"@{CODE_BASE // 4:08x}\n")
        for instruction in code:
            image.write(f"{instruction:08x}\n")
    print(f"Generated {IMAGE.relative_to(ROOT)}: {len(code)} high-address instructions")
    print(f"Code range: 0x{CODE_BASE:03x}..0x{CODE_BASE + len(code) * 4 - 1:03x}")


if __name__ == "__main__":
    main()
